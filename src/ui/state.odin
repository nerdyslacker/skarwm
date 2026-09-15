package ui

import c "../core"
import x11 "../x11"
import "core:time"

Tab_Decoration :: struct {
    Xid: u32,
    Client: ^c.Client,
    Bg: u32,
    Width: i32,
}

State :: struct {
    Conn: ^x11.Connection,
    Root: u32,
    WhitePixel: u32,
    Atoms: ^map[string]u32,

    Tabs: [dynamic]Tab_Decoration,
    TabGC, TabFont: u32,
    HelpWindow: u32,
    NoticeWindow: u32,
    NoticeText: string,
    NoticeUntil: time.Tick,
    NoticePersistent: bool,

    ReminderWindow: u32,
    ReminderMinutesWindow: u32,
    ReminderMessageWindow: u32,
    ReminderMinutes: string,
    ReminderMessage: string,
    ReminderError: string,
    ReminderField: int,
    ReminderListMode: bool,
    ReminderListLines: [dynamic]string,

    DropWindows: [5]u32,
    DropVisible: bool,
    DropHasCompositor: bool,
    DropTarget: c.Drop_Target,
}

Init :: proc(state: ^State, conn: ^x11.Connection, root, white_pixel: u32, atoms: ^map[string]u32) {
    state.Conn = conn
    state.Root = root
    state.WhitePixel = white_pixel
    state.Atoms = atoms
    state.Tabs = make([dynamic]Tab_Decoration, 0, 8)
    state.ReminderListLines = make([dynamic]string, 0, 8)
}

atom :: proc(state: ^State, name: string) -> u32 {
    return x11.intern_atom(state.Conn, state.Atoms, name)
}
