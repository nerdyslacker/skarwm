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
    AudioEnabled: bool,
    AudioShowPercentage: bool,
    AudioSliderWidth: i32,
    AudioVolumeStep: i32,
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
        AudioEnabled = false,
        AudioShowPercentage = true,
        AudioSliderWidth = 90,
        AudioVolumeStep = 5,
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
    Audio_Mute, Audio_Slider, Audio_Compact,
}

Decoration_Audio_Mode :: enum u8 {
    Hidden,
    Inline,
    Inline_No_Percentage,
    Compact,
}

Decoration_Audio_Layout :: struct {
    Mode: Decoration_Audio_Mode,
    Bounds, Speaker, Slider, Percentage: Rect,
}

rect_contains :: proc(rect: Rect, x, y: i32) -> bool {
    return rect.W > 0 && rect.H > 0 && x >= rect.X && y >= rect.Y && x < rect.X+rect.W && y < rect.Y+rect.H
}

// Audio controls occupy the title row immediately before the three standard
// buttons. The title keeps a small drag target before controls collapse.
Decoration_Audio_Layout_For :: proc(frame_w, frame_h: i32, cfg: Decoration_Config, visible: bool) -> Decoration_Audio_Layout {
    if !visible || frame_w <= 0 || frame_h <= 0 { return {} }
    b := max(i32(0), cfg.BorderWidth)
    title_h := min(max(i32(0), cfg.TitlebarHeight), max(i32(0), frame_h-2*b))
    if title_h <= 0 { return {} }
    button_w := max(i32(1), cfg.TitlebarHeight)
    right := frame_w - b - 3*button_w
    available := right - (b + 48)
    speaker_w := title_h
    slider_w := max(i32(1), cfg.AudioSliderWidth*title_h/20)
    percent_w := 30*title_h/20
    gap := max(i32(2), title_h/5)
    full_w := speaker_w + gap + slider_w
    if cfg.AudioShowPercentage { full_w += gap + percent_w }

    result: Decoration_Audio_Layout
    width := full_w
    if available >= full_w {
        result.Mode = .Inline
    } else if available >= speaker_w+gap+slider_w {
        result.Mode = .Inline_No_Percentage
        width = speaker_w+gap+slider_w
    } else if available >= speaker_w {
        result.Mode = .Compact
        width = speaker_w
    } else {
        return {}
    }
    result.Bounds = {X = right-width, Y = b, W = width, H = title_h}
    result.Speaker = {X = result.Bounds.X, Y = b, W = speaker_w, H = title_h}
    if result.Mode == .Inline || result.Mode == .Inline_No_Percentage {
        result.Slider = {X = result.Speaker.X+speaker_w+gap, Y = b, W = slider_w, H = title_h}
    }
    if result.Mode == .Inline && cfg.AudioShowPercentage {
        result.Percentage = {X = result.Slider.X+slider_w+gap, Y = b, W = percent_w, H = title_h}
    }
    return result
}

Decoration_Audio_Volume_At :: proc(slider: Rect, x: i32) -> u32 {
    if slider.W <= 0 { return 0 }
    position := clamp(x-slider.X, i32(0), slider.W)
    return u32(u64(position)*65_536/u64(slider.W))
}

// Hit testing uses frame-local coordinates.  Resize zones win at corners and
// may be wider than the painted border. Buttons are square titlebar-height
// targets ordered minimize/maximize/close from left to right.
Decoration_Hit_Test :: proc(frame_w, frame_h, x, y: i32, cfg: Decoration_Config, audio_visible := false) -> Decoration_Hit {
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
    audio := Decoration_Audio_Layout_For(frame_w, frame_h, cfg, audio_visible)
    if rect_contains(audio.Speaker, x, y) {
        return .Audio_Compact if audio.Mode == .Compact else .Audio_Mute
    }
    if rect_contains(audio.Slider, x, y) { return .Audio_Slider }
    return .Title
}
