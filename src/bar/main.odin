package main

import x11 "../x11"
import ipc "../core"

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:sys/posix"

Bar_Position :: enum u8 { Top, Bottom }
Bar_Font_Weight :: enum u8 { Normal, Medium, Bold }

Bar_Config :: struct {
    Position: Bar_Position,
    Height: i32,
    Font: [128]u8,
    FontLen, FontSize: i32,
    FontWeight: Bar_Font_Weight,
    Managed: bool,
    Foreground: u32,
    Background: u32,
    WorkspaceCount: i32,
    WorkspaceForeground, WorkspaceBackground: u32,
    BlockForeground, BlockBackground: u32,
}

Bar_Window :: struct {
    Xid: u32,
    Output: string,
    Geom: Monitor,
    Hits: [dynamic]Hitbox,
    HoverWorkspace: int,
    Canvas: X_Pixmap,
    TextDraw: ^Xft_Draw,
}

Monitor :: struct {
    X, Y, W, H: i32,
    Name: string,
}

Workspace_State :: struct {
    Id: int,
    Name: string,
    Output: string,
    Active: bool,
    Occupied: bool,
    Urgent: bool,
}

State :: struct {
    Conn: ^x11.Connection,
    Root: u32,
    ScreenNumber: i32,
    RootW, RootH: i32,
    BlackPixel: u32,
    RootVisual: u32,
    Atoms: map[string]u32,
    Windows: [dynamic]Bar_Window,
    Config: Bar_Config,
    RandrAvailable: bool,
    RandrEventBase: u8,
    GC: ^X_GC,
    Display: ^X_Display,
    Visual: ^X_Visual,
    Colormap: X_Colormap,
    NormalFont, BoldFont: ^Xft_Font,
    Blocks: [dynamic]Block,
    Workspaces: [dynamic]Workspace_State,
    IpcFd: posix.FD,
    IpcReader: ipc.Ipc_Reader,
    Tray: Tray_State,
}

BAR_CONFIG_ATOM :: "_SKARWM_BAR_CONFIG"
BAR_BLOCKS_ATOM :: "_SKARWM_BAR_BLOCKS"
BAR_FONT_ATOM :: "_SKARWM_BAR_FONT"
BAR_CONFIG_VERSION :: u32(3)

main :: proc() {
    cfg, ok := parse_args()
    if !ok { os.exit(2) }

    state: State
    state.Config = cfg
    if !connect(&state) {
        fmt.eprintln("skarwm-bar: cannot connect to X11")
        os.exit(1)
    }
    defer shutdown(&state)

    if cfg.Managed {
        enabled, found := read_managed_config(&state)
        if !found || !enabled { return }
    }
    init_randr(&state)
    renderer_init(&state)
    blocks_init(&state)
    rebuild_windows(&state)
    run_event_loop(&state)
}

parse_args :: proc() -> (Bar_Config, bool) {
    cfg := Bar_Config{
        Position = .Top, Height = 26,
        FontSize = 11, FontWeight = .Normal,
        Foreground = 0xE6E6E6, Background = 0x1E1E2E,
        WorkspaceCount = 8,
        WorkspaceForeground = 0x262626, WorkspaceBackground = 0x5F87AF,
        BlockForeground = 0x262626, BlockBackground = 0xAF5F5F,
    }
    config_set_font(&cfg, "monospace")
    args := os.args
    i := 1
    for i < len(args) {
        switch args[i] {
        case "--managed":
            cfg.Managed = true
        case "--position":
            if i + 1 >= len(args) { usage(); return {}, false }
            i += 1
            switch args[i] {
            case "top": cfg.Position = .Top
            case "bottom": cfg.Position = .Bottom
            case: usage(); return {}, false
            }
        case "--height":
            if i + 1 >= len(args) { usage(); return {}, false }
            i += 1
            value, parsed := strconv.parse_i64(args[i], 10)
            if !parsed || value < 1 || value > 512 { usage(); return {}, false }
            cfg.Height = i32(value)
        case "--font":
            if i + 1 >= len(args) || len(args[i + 1]) >= len(cfg.Font) { usage(); return {}, false }
            i += 1
            config_set_font(&cfg, args[i])
        case "--font-size":
            if i + 1 >= len(args) { usage(); return {}, false }
            i += 1
            value, parsed := strconv.parse_i64(args[i], 10)
            if !parsed || value < 6 || value > 72 { usage(); return {}, false }
            cfg.FontSize = i32(value)
        case "--font-weight":
            if i + 1 >= len(args) { usage(); return {}, false }
            i += 1
            switch args[i] {
            case "normal", "regular": cfg.FontWeight = .Normal
            case "medium": cfg.FontWeight = .Medium
            case "bold": cfg.FontWeight = .Bold
            case: usage(); return {}, false
            }
        case "--foreground":
            if i + 1 >= len(args) { usage(); return {}, false }
            i += 1
            value, parsed := parse_colour(args[i])
            if !parsed { usage(); return {}, false }
            cfg.Foreground = value
        case "--background":
            if i + 1 >= len(args) { usage(); return {}, false }
            i += 1
            value, parsed := parse_colour(args[i])
            if !parsed { usage(); return {}, false }
            cfg.Background = value
        case "--workspaces", "--tags":
            if i + 1 >= len(args) { usage(); return {}, false }
            i += 1
            value, parsed := strconv.parse_i64(args[i], 10)
            if !parsed || value < 1 || value > 64 { usage(); return {}, false }
            cfg.WorkspaceCount = i32(value)
        case "-h", "--help":
            usage()
            os.exit(0)
        case:
            usage()
            return {}, false
        }
        i += 1
    }
    return cfg, true
}

usage :: proc() {
    fmt.eprintln("usage: skarwm-bar [--position top|bottom] [--height 1..512]")
    fmt.eprintln("                  [--font FAMILY] [--font-size 6..72]")
    fmt.eprintln("                  [--font-weight normal|medium|bold]")
    fmt.eprintln("                  [--foreground '#RRGGBB'] [--background '#RRGGBB']")
    fmt.eprintln("                  [--workspaces 1..64]")
}

config_set_font :: proc(config: ^Bar_Config, font: string) {
    config.Font = {}
    count := min(len(font), len(config.Font) - 1)
    copy(config.Font[:count], transmute([]u8)font[:count])
    config.FontLen = i32(count)
}

config_font :: proc(config: ^Bar_Config) -> string {
    return string(config.Font[:config.FontLen])
}

parse_colour :: proc(value: string) -> (u32, bool) {
    text := value
    if len(text) > 0 && text[0] == '#' { text = text[1:] }
    if len(text) != 6 { return 0, false }
    parsed, ok := strconv.parse_u64(text, 16)
    return u32(parsed), ok && parsed <= 0xFFFFFF
}

connect :: proc(state: ^State) -> bool {
    state.Conn = x11.xcb_connect(nil, &state.ScreenNumber)
    if state.Conn == nil || x11.xcb_connection_has_error(state.Conn) != 0 { return false }
    iter := x11.xcb_setup_roots_iterator(x11.xcb_get_setup(state.Conn))
    for screen in 0 ..< state.ScreenNumber {
        if iter.rem <= 0 { return false }
        x11.xcb_screen_next(&iter)
    }
    if iter.rem <= 0 || iter.data == nil { return false }
    screen := iter.data
    state.Root = screen.root
    state.RootW = i32(screen.width_in_pixels)
    state.RootH = i32(screen.height_in_pixels)
    state.BlackPixel = screen.black_pixel
    state.RootVisual = screen.root_visual
    state.Atoms = make(map[string]u32)
    state.Windows = make([dynamic]Bar_Window, 0, 4)
    state.Workspaces = make([dynamic]Workspace_State, 0, 16)
    state.IpcFd = -1

    // Managed instances watch the WM-published config. Event selection is
    // per client, so this does not disturb the WM's own root mask.
    if state.Config.Managed {
        mask := u32(x11.EVENT_MASK_PROPERTY_CHANGE)
        x11.xcb_change_window_attributes(state.Conn, state.Root, x11.CW_EVENT_MASK, &mask)
    }
    return true
}

shutdown :: proc(state: ^State) {
    ipc_disconnect(state)
    blocks_destroy(state)
    tray_shutdown(state)
    destroy_windows(state)
    renderer_shutdown(state)
    clear_workspaces(state)
    if state.Atoms != nil { delete(state.Atoms) }
    if state.Conn != nil { x11.xcb_disconnect(state.Conn) }
    state^ = {}
}

atom :: proc(state: ^State, name: string) -> u32 {
    return x11.intern_atom(state.Conn, &state.Atoms, name)
}

read_managed_config :: proc(state: ^State) -> (enabled, found: bool) {
    data, ok := x11.get_prop(state.Conn, state.Root, atom(state, BAR_CONFIG_ATOM), atom(state, "CARDINAL"))
    if !ok || len(data) < 4 * 4 {
        if ok { delete(data) }
        return false, false
    }
    defer delete(data)
    values := ([^]u32)(raw_data(data))[:len(data) / 4]
    if values[0] != BAR_CONFIG_VERSION { return false, false }
    if values[1] == 0 { return false, true }
    if values[2] == u32(Bar_Position.Bottom) {
        state.Config.Position = .Bottom
    } else {
        state.Config.Position = .Top
    }
    state.Config.Height = clamp(i32(values[3]), i32(1), i32(512))
    if len(values) >= 6 {
        state.Config.Foreground = values[4]
        state.Config.Background = values[5]
    }
    if len(values) >= 11 {
        state.Config.WorkspaceCount = clamp(i32(values[6]), i32(1), i32(64))
        state.Config.WorkspaceForeground = values[7]
        state.Config.WorkspaceBackground = values[8]
        state.Config.BlockForeground = values[9]
        state.Config.BlockBackground = values[10]
    }
    if len(values) >= 13 {
        state.Config.FontSize = clamp(i32(values[11]), i32(6), i32(72))
        if values[12] <= u32(Bar_Font_Weight.Bold) {
            state.Config.FontWeight = Bar_Font_Weight(values[12])
        }
    }
    if font, font_ok := x11.get_text(state.Conn, state.Root, atom(state, BAR_FONT_ATOM)); font_ok {
        config_set_font(&state.Config, font)
        delete(font)
    }
    return true, true
}
