package core

// Config holds every tunable that drives layout/behavior and is settable from
// the rc configuration layer (src/config.odin). It lives in `core` so layout
// math can be tested without X or the config parser.
//
// `Gap` / `OuterGap` / `InnerGap` / `BorderWidth` are in pixels; the two
// `*Border` fields are X pixel values (0xRRGGBB). Column widths are *not*
// configurable: they are derived per workspace from its column count (see
// Resolve_Page_Width in layout.odin).
Config :: struct {
    Gap: i32, // convenience alias; when > 0 at load time it seeds both gaps
    OuterGap: i32,
    InnerGap: i32,
    BorderWidth: i32,
    FocusFollowsMouse: bool,
    FocusedBorder: u32,   // border colour of the focused window
    UnfocusedBorder: u32, // border colour of every other window
}

Default_Config :: proc() -> Config {
    return Config {
        Gap               = 0, // 0 == unset, caller applies it to both gaps
        OuterGap          = 8,
        InnerGap          = 8,
        BorderWidth       = 2,
        FocusFollowsMouse = true,
        FocusedBorder     = 0xE0AF68,
        UnfocusedBorder   = 0x3A3A3A,
    }
}

// Apply_Gap_Alias seeds both OuterGap and InnerGap from Gap when the caller only
// supplied Gap. Call after filling a Config from the rc settings.
Apply_Gap_Alias :: proc(cfg: ^Config) {
    if cfg.Gap > 0 {
        cfg.OuterGap = cfg.Gap
        cfg.InnerGap = cfg.Gap
    }
}
