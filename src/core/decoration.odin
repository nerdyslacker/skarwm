package core

// Pure decoration policy and geometry.  X11 frame lifecycle/rendering belongs
// to the wm package; keeping these transforms here gives layout, input and
// tests one definition of the client/frame coordinate contract.

Decoration_Color_Source :: enum u8 {
    Active_Border,
    Accent,
    Explicit,
}

Decoration_Config :: struct {
    Enabled: bool,
    TitlebarHeight: i32,
    BorderWidth: i32,
    ResizeHitWidth: i32,
    ShowTitle: bool,
    ColorSource: Decoration_Color_Source,
    Accent: u32,
    ActiveBackground: u32,
    InactiveBackground: u32,
    ActiveForeground: u32,
    InactiveForeground: u32,
    ActiveBorder: u32,
    InactiveBorder: u32,
}

Default_Decoration_Config :: proc() -> Decoration_Config {
    return Decoration_Config {
        Enabled = false,
        TitlebarHeight = 20,
        BorderWidth = 1,
        ResizeHitWidth = 4,
        ShowTitle = true,
        ColorSource = .Active_Border,
        Accent = 0x89B4FA,
        ActiveBackground = 0x313244,
        InactiveBackground = 0x1E1E2E,
        ActiveForeground = 0xFFFFFF,
        InactiveForeground = 0xA6ADC8,
        ActiveBorder = 0x89B4FA,
        InactiveBorder = 0x45475A,
    }
}

// Pick a legible monochrome foreground for semantic color sources. Integer
// Rec. 601 luma is sufficient for opaque #RRGGBB UI colors and deterministic
// in the pure core tests.
Decoration_Contrast_Foreground :: proc(background: u32) -> u32 {
    r := (background >> 16) & 0xff
    g := (background >> 8) & 0xff
    b := background & 0xff
    luma := 299*r + 587*g + 114*b
    return 0x181818 if luma >= 150000 else 0xF2F2F2
}

Decoration_Colors :: struct {
    Background, Foreground, Border: u32,
}

Resolve_Decoration_Colors :: proc(cfg: Decoration_Config, focused_border, unfocused_border: u32, active: bool) -> Decoration_Colors {
    switch cfg.ColorSource {
    case .Accent:
        bg := cfg.InactiveBackground
        fg := cfg.InactiveForeground
        if active { bg, fg = cfg.Accent, Decoration_Contrast_Foreground(cfg.Accent) }
        return {Background = bg, Foreground = fg, Border = cfg.Accent}
    case .Explicit:
        if active {
            return {Background = cfg.ActiveBackground, Foreground = cfg.ActiveForeground, Border = cfg.ActiveBorder}
        }
        return {Background = cfg.InactiveBackground, Foreground = cfg.InactiveForeground, Border = cfg.InactiveBorder}
    case .Active_Border:
        border := unfocused_border
        bg := cfg.InactiveBackground
        fg := cfg.InactiveForeground
        if active {
            border, bg = focused_border, focused_border
            fg = Decoration_Contrast_Foreground(bg)
        }
        return {Background = bg, Foreground = fg, Border = border}
    }
    return {}
}

// A client's root rectangle excludes skarwm's decoration.  The frame extends
// above it by titlebar+border and around the other three sides by border.
Decoration_Frame_Rect :: proc(client: Rect, cfg: Decoration_Config) -> Rect {
    b := max(i32(0), cfg.BorderWidth)
    inset := max(b, max(i32(1), cfg.ResizeHitWidth))
    title := max(i32(0), cfg.TitlebarHeight)
    return Rect{X = client.X - inset, Y = client.Y - title - b,
                W = max(i32(1), client.W + 2*inset), H = max(i32(1), client.H + title + b + inset)}
}

Decoration_Client_Rect :: proc(frame: Rect, cfg: Decoration_Config) -> Rect {
    b := max(i32(0), cfg.BorderWidth)
    inset := max(b, max(i32(1), cfg.ResizeHitWidth))
    title := max(i32(0), cfg.TitlebarHeight)
    return Rect{X = frame.X + inset, Y = frame.Y + title + b,
                W = max(i32(1), frame.W - 2*inset), H = max(i32(1), frame.H - title - b - inset)}
}

// Layout Geom is inset by the normal reserved X-border width. Decorations
// replace that border and occupy the complete original tile/floating rect.
Decoration_Layout_Frame_Rect :: proc(layout_geom: Rect, reserved_border: i32) -> Rect {
    b := max(i32(0), reserved_border)
    return Rect{X = layout_geom.X-b, Y = layout_geom.Y-b,
                W = max(i32(1), layout_geom.W+2*b), H = max(i32(1), layout_geom.H+2*b)}
}

Decoration_Hit :: enum u8 {
    None, Title,
    Resize_Top, Resize_Bottom, Resize_Left, Resize_Right,
    Resize_Top_Left, Resize_Top_Right, Resize_Bottom_Left, Resize_Bottom_Right,
    Minimize, Maximize, Close,
}

// Hit testing uses frame-local coordinates.  Resize zones win at corners and
// may be wider than the painted border. Buttons are square titlebar-height
// targets ordered minimize/maximize/close from left to right.
Decoration_Hit_Test :: proc(frame_w, frame_h, x, y: i32, cfg: Decoration_Config) -> Decoration_Hit {
    if x < 0 || y < 0 || x >= frame_w || y >= frame_h { return .None }
    hit := max(i32(1), cfg.ResizeHitWidth)
    left, right := x < hit, x >= frame_w-hit
    top, bottom := y < hit, y >= frame_h-hit
    if top && left { return .Resize_Top_Left }
    if top && right { return .Resize_Top_Right }
    if bottom && left { return .Resize_Bottom_Left }
    if bottom && right { return .Resize_Bottom_Right }
    if top { return .Resize_Top }
    if bottom { return .Resize_Bottom }
    if left { return .Resize_Left }
    if right { return .Resize_Right }

    title_bottom := max(i32(0), cfg.TitlebarHeight) + max(i32(0), cfg.BorderWidth)
    if y >= title_bottom { return .None }
    button_w := max(i32(1), cfg.TitlebarHeight)
    from_right := frame_w - x
    if from_right <= button_w { return .Close }
    if from_right <= 2*button_w { return .Maximize }
    if from_right <= 3*button_w { return .Minimize }
    return .Title
}
