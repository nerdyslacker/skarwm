package input

// Resolved input actions are shared by the rc loader, dispatcher, and help UI.

Action_Kind :: enum u8 {
    None,
    Spawn,
    Focus_Left, Focus_Right, Focus_Up, Focus_Down,
    Move_Left, Move_Right, Move_Up, Move_Down,
    Resize_Left, Resize_Right, Resize_Up, Resize_Down,
    Toggle_Floating,
    Toggle_Fullscreen,
    Layout_Floating, Layout_Tabbed, Layout_Stacked, Layout_Toggle,
    Overview_Next, Overview_Prev,
    Scratchpad_Toggle, Scratchpad_Toggle_Float, Scratchpad_Remove,
    Show_Bindings,
    Show_Date_Time, Show_Battery,
    Close,
    Reload,
    Quit,
    WS_Next, WS_Prev,
    WS_Goto,
    Move_To_WS,
    Move_To_WS_Next, Move_To_WS_Prev,
    Focus_Output_Next, Focus_Output_Prev,
    Move_To_Output_Next, Move_To_Output_Prev,
}

Binding :: struct {
    mods:    u16,
    effective_mods: u16,
    keysym:  u32,
    keycode: u8,
    action:  Action_Kind,
    arg:     int,
    cmd:     string,
    combo:   string,
}
