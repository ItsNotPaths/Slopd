package ui

import "vendor:glfw"

// A key that qualifies the next keystroke rather than being one. Super and CapsLock count.
key_is_modifier :: proc(key: i32) -> bool {
    switch key {
    case glfw.KEY_LEFT_ALT, glfw.KEY_RIGHT_ALT,
         glfw.KEY_LEFT_CONTROL, glfw.KEY_RIGHT_CONTROL,
         glfw.KEY_LEFT_SHIFT, glfw.KEY_RIGHT_SHIFT,
         glfw.KEY_LEFT_SUPER, glfw.KEY_RIGHT_SUPER,
         glfw.KEY_CAPS_LOCK:
        return true
    }
    return false
}
