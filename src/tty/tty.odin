package tty

import "base:runtime"
import "core:c"
import "core:encoding/base64"
import "core:sys/posix"

// The HOST terminal: the one Slopd is running inside when it draws itself as a grid. src/pty is
// this backwards — that one spawns a child on a pty it owns, this one borrows the terminal it was
// launched from and has to give it back exactly as it found it.
//
// Giving it back is the whole risk here. A process that dies in raw mode with the alternate
// screen up and the cursor hidden leaves a shell that echoes nothing and shows no prompt, and the
// user has to type `reset` blind to recover. So the restore runs from a signal handler as well as
// from close: SIGINT and SIGTERM because those are ordinary quits, SIGSEGV and SIGABRT because a
// crash must not take the terminal with it.

TIOCGWINSZ :: 0x5413 // Linux ioctl: get terminal window size

@(private)
Winsize :: struct {
    ws_row, ws_col, ws_xpixel, ws_ypixel: u16,
}

foreign import libc "system:c"

@(default_calling_convention = "c")
foreign libc {
    @(private)
    ioctl :: proc(fd: posix.FD, request: c.ulong, argp: rawptr) -> c.int ---
}

Tty :: struct {
    fd:      posix.FD,
    saved:   posix.termios,
    entered: bool,
}

// The one Tty a process can have, so the signal handlers can reach it. They take a signal number
// and nothing else, and there is exactly one host terminal to restore.
@(private)
g_tty: ^Tty

@(private)
g_resized: bool

// Sizes the terminal reports when it will not say, which is every terminal that is not one.
FALLBACK_COLS :: 80
FALLBACK_ROWS :: 24

// Raw mode, the alternate screen, no cursor. False when stdout is not a terminal, which is the
// answer for a pipe or a CI runner rather than something to work around.
enter :: proc(t: ^Tty) -> bool {
    t.fd = posix.STDOUT_FILENO
    if !posix.isatty(t.fd) {
        return false
    }
    if posix.tcgetattr(t.fd, &t.saved) != .OK {
        return false
    }

    raw := t.saved
    // No line editing, no echo, no signal keys: every byte reaches us as typed, and ^C becomes
    // a keystroke the bind table can own rather than a kill.
    raw.c_iflag -= {.BRKINT, .ICRNL, .INPCK, .ISTRIP, .IXON}
    raw.c_oflag -= {.OPOST} // we place every cell ourselves; no NL -> CRNL behind our back
    raw.c_lflag -= {.ECHO, .ICANON, .IEXTEN, .ISIG}
    raw.c_cflag += {.CS8}
    // A read returns whatever has arrived, at once, so the frame loop is never held by the
    // keyboard. The wait belongs to the loop, not to the terminal.
    raw.c_cc[.VMIN] = 0
    raw.c_cc[.VTIME] = 0
    if posix.tcsetattr(t.fd, .TCSAFLUSH, &raw) != .OK {
        return false
    }

    t.entered = true
    g_tty = t
    install_handlers()
    // Alternate screen first, so the restore can put the user's scrollback back untouched.
    write(t, "\e[?1049h\e[?25l\e[2J")
    return true
}

// Exactly the reverse of enter, and safe to call twice: the second time is the signal handler's,
// or the other way round.
leave :: proc(t: ^Tty) {
    if !t.entered {
        return
    }
    t.entered = false
    write(t, "\e[?25h\e[0m\e[?1049l")
    posix.tcsetattr(t.fd, .TCSAFLUSH, &t.saved)
    if g_tty == t {
        g_tty = nil
    }
}

// Columns and rows. The fallback is a guess rather than a failure: a terminal that will not
// answer still deserves a screen.
size :: proc(t: ^Tty) -> (cols, rows: i32) {
    ws: Winsize
    if ioctl(t.fd, TIOCGWINSZ, &ws) == 0 && ws.ws_col > 0 && ws.ws_row > 0 {
        return i32(ws.ws_col), i32(ws.ws_row)
    }
    return FALLBACK_COLS, FALLBACK_ROWS
}

// Take-and-clear: a SIGWINCH since the last ask. The handler cannot resize anything itself, so
// all it does is leave this behind for the frame loop to find.
resized :: proc() -> bool {
    was := g_resized
    g_resized = false
    return was
}

write :: proc(t: ^Tty, bytes: string) {
    write_bytes(t, transmute([]u8)bytes)
}

// Loops, because a big frame can exceed the pipe buffer and a short write is not an error.
write_bytes :: proc(t: ^Tty, bytes: []u8) {
    sent := 0
    for sent < len(bytes) {
        left := len(bytes) - sent
        n := posix.write(t.fd, raw_data(bytes[sent:]), uint(left))
        if n <= 0 {
            return // the terminal went away; the loop will notice on its next read
        }
        sent += int(n)
    }
}

// Block until a keystroke arrives or `seconds` elapses; negative waits indefinitely. This is the
// terminal's answer to glfw.WaitEventsTimeout, and it is what keeps the loop off the CPU: a
// SIGWINCH interrupts it, and so does a mark from a pty reader thread by way of the frame's own
// gate. True when something is readable.
wait :: proc(t: ^Tty, seconds: f64) -> bool {
    fds := [1]posix.pollfd{{fd = posix.STDIN_FILENO, events = {.IN}}}
    ms := c.int(-1)
    if seconds >= 0 {
        ms = c.int(seconds * 1000)
    }
    return posix.poll(&fds[0], 1, ms) > 0 && .IN in fds[0].revents
}

// Whatever has arrived, which VMIN=0 makes a non-blocking answer. 0 means nothing was waiting.
read :: proc(t: ^Tty, buf: []u8) -> int {
    n := posix.read(posix.STDIN_FILENO, raw_data(buf), uint(len(buf)))
    return n > 0 ? int(n) : 0
}

// OSC 52: hands `s` to the terminal, which puts it on the system clipboard for us. Best effort
// and unacknowledged — a terminal that does not implement it, or has it switched off, silently
// ignores the sequence, and there is no reply to wait for either way.
//
// There is deliberately no read. The OSC 52 query lets any program on the terminal read your
// clipboard, so terminals disable it by default and the ones that do not should. Pasting FROM the
// system belongs to bracketed paste, which arrives through input like typing does.
clipboard_set :: proc(t: ^Tty, s: string) {
    b64, err := base64.encode(transmute([]u8)s, allocator = context.temp_allocator)
    if err != nil {
        return
    }
    write(t, "\e]52;c;")
    write(t, b64)
    write(t, "\a")
}

@(private)
install_handlers :: proc() {
    posix.signal(posix.Signal(SIGWINCH), on_winch)
    for sig in ([]posix.Signal{.SIGINT, .SIGTERM, .SIGSEGV, .SIGABRT}) {
        posix.signal(sig, on_fatal)
    }
}

@(private)
SIGWINCH :: 28

@(private)
on_winch :: proc "c" (sig: posix.Signal) {
    g_resized = true
}

// The default disposition, as a handler value. posix.SIG_DFL is libc's rawptr sentinel.
@(private)
SIG_DFL_HANDLER := cast(proc "c" (posix.Signal))posix.SIG_DFL

// Put the terminal back, then die the way we were asked to. Re-raising against the default
// disposition rather than exiting keeps the exit status honest: a shell that sees a crash should
// still see a crash.
@(private)
on_fatal :: proc "c" (sig: posix.Signal) {
    context = runtime.default_context()
    if g_tty != nil {
        leave(g_tty)
    }
    posix.signal(sig, SIG_DFL_HANDLER)
    posix.raise(sig)
}
