package core

// Config holds every tunable that drives layout/behavior and is settable from
// the rc configuration layer (src/wm/config.odin). It lives in `core` so layout
// math can be tested without X or the config parser.
//
// `Gap` / `OuterGap` / `InnerGap` / `BorderWidth` / `CornerRadius` are in pixels; the two
// `*Border` fields are X pixel values (0xRRGGBB). Column widths are *not*
// configurable: they are derived per workspace from its column count (see
// Resolve_Page_Width in layout.odin).
Config :: struct {
    Gap: i32, // convenience alias; when > 0 at load time it seeds both gaps
    OuterGap: i32,
    InnerGap: i32,
    BorderWidth: i32,
    CornerRadius: i32, // 0 disables X Shape rounded corners
    FocusFollowsMouse: bool,
    Animations: bool,
    AnimationDurationMs: i32,
    AnimationFps: i32,
    AnimationEasing: Animation_Easing,
    FocusedBorder: u32,   // border colour of the focused window
    UnfocusedBorder: u32, // border colour of every other window
    BarEnabled: bool,
    BarPosition: Bar_Position,
    BarHeight: i32,
    BarForeground: u32,
    BarBackground: u32,
}

Bar_Position :: enum u8 { Top, Bottom }

Default_Config :: proc() -> Config {
    return Config {
        Gap               = 0, // 0 == unset, caller applies it to both gaps
        OuterGap          = 8,
        InnerGap          = 8,
        BorderWidth       = 2,
        CornerRadius      = 0,
        FocusFollowsMouse = true,
        Animations        = true,
        AnimationDurationMs = 180,
        AnimationFps      = 60,
        AnimationEasing   = .Ease_Out_Cubic,
        FocusedBorder     = 0xE0AF68,
        UnfocusedBorder   = 0x3A3A3A,
        BarEnabled        = false,
        BarPosition       = .Top,
        BarHeight         = 26,
        BarForeground     = 0xE6E6E6,
        BarBackground     = 0x1E1E2E,
    }
}

Animation_Easing :: enum u8 {
    Linear,
    Ease_Out_Cubic,
}

// Apply_Gap_Alias seeds both OuterGap and InnerGap from Gap when the caller only
// supplied Gap. Call after filling a Config from the rc settings.
Apply_Gap_Alias :: proc(cfg: ^Config) {
    if cfg.Gap > 0 {
        cfg.OuterGap = cfg.Gap
        cfg.InnerGap = cfg.Gap
    }
}
