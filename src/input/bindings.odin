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
    Layout_Scroller, Layout_Vertical_Scroller, Layout_Dwindle, Layout_Monocle, Layout_Next,
    Overview_Next, Overview_Prev,
    Scratchpad_Toggle, Scratchpad_Toggle_Float, Scratchpad_Remove,
    Show_Bindings,
    Show_Date_Time, Show_Battery,
    Reminder_New, Reminder_Show_All, Reminder_Clear_All,
    Close,
    Reload,
    Quit,
    WS_Next, WS_Prev,
    WS_Goto,
    Move_To_WS,
    Move_To_WS_Next, Move_To_WS_Prev,
    Focus_Output_Next, Focus_Output_Prev,
    Move_To_Output_Next, Move_To_Output_Prev,
    Screen_Split_Toggle, Screen_Split_Enable, Screen_Split_Disable,
    Screen_Split_Grow, Screen_Split_Shrink, Screen_Split_Ratio,
    Focus_Matching_Window,
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
    match_class, match_instance, match_title: string,
}
