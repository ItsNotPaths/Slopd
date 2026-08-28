package main
import "../ui"


// Building the frame's context is the one thing only the App can do.

ctx_of :: proc(a: ^App) -> ui.UI_Ctx {
    return {
        theme         = &a.theme,
        mouse         = &a.mouse,
        drag          = &a.drag,
        focus         = a.focus,
        scroll_mode   = a.scroll_mode,
        scale         = a.scale,
        mouse_on      = a.mouse_on,
        hover_on      = a.hover_on,
        blink_base    = &a.blink_base,
        last_input_at = a.last_input_at,
    }
}
