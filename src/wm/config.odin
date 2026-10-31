package wm

import process "../process"
import ui "../ui"
import logger "../log"
import input "../input"
import c "../core"
import x11 "../x11"

// rc configuration pipeline (no embedded scripting language).
//
// Two sources of truth, one result:
//
//   - no configuration file found  -> cfg_apply_default() builds a Config_Result
//                                     from the built-in defaults.
//   - an rc file is found           -> cfg_file_result() parses its flat
//                                     `key : value` / `directive : …` grammar,
//                                     see below), collects the directives into a
//                                     Load_Scratch, then resolves everything into
//                                     a Config_Result.
//
// The rc file completely replaces the built-in key bindings (a config file is
// the whole config). A Config_Result is applied atomically: if any
// step fails — syntax error, malformed combo, unknown keysym/action — cfg_apply()
// is never reached and the WM keeps its previous settings, logs the error, and
// continues running.
//
// rc grammar
// ----------
//   - `#` starts a whole-line comment; lines are `key : value` (settings) or a
//     directive with extra `:` fields. Settings are collected during a single
//     scan and directives resolved afterwards, so `mod_key` may appear anywhere.
//   - settings: mod_key (alias modkey), inner_gap, outer_gap, gap (seeds both),
//     border_width, corner_radius, norm_outer_border (unfocused colour), sel_outer_border
//     (focused colour), focus_follows_mouse, animations,
//     animation_duration_ms, animation_fps, animation_easing,
//     decoration_audio_enabled, bar_enabled,
//     bar_position, bar_height, bar_foreground, bar_background,
//     bar_tag_count, bar_tag_foreground, bar_tag_background,
//     bar_block_foreground, bar_block_background. Legacy decorative/titlebar keys
//     are accepted and ignored; an unknown setting logs one warning.
//   - directives:
//       import     : <path>                  (relative to the containing file)
//       bind       : <combo> : "<command>"
//       call       : <combo> : <action> [arguments]
//       workspace  : <combo> : view <N>      (switch to N)
//       workspace  : <combo> : tag <N>       (move focused window to N)
//       rule       : <class|instance|title> : <pattern> : <effects…>
//       autostart  : "<command>"
//       bar_block  : workspaces : <left|center|right>
//       bar_block  : layout : <left|center|right>
//       bar_block  : title : <left|center|right>
//       bar_block  : systray : <left|center|right>
//       bar_block  : button : <left|center|right> : <label> : "<command>"
//       bar_block  : clock : <left|center|right> [: <label>] [: "<click command>"]
//       bar_block  : battery : <left|center|right> [: <label>] [: "<click command>"]
//       bar_block  : script : <left|center|right> : <name> : <interval seconds> :
//                    <timeout seconds> : "<command>"
//       bar_block  : audio : <left|center|right> [: <label>] [: "<click command>"]
//       bar_block  : network|bluetooth : <left|center|right> [: <label>] [: "<click command>"]
//     Any block may append foreground/background colours (`_` inherits). For
//     script/button blocks the pair appears immediately before the command.
//       virtual_screen : <output> : split : <percent> [: <pixel offset>]
//       mousebind  : …                       (warned + skipped: no mouse system yet)
//
// A combo is modifier tokens (`mod`, Shift, Control, Mod1..Mod5, Super, Alt)
// joined by `+` with one keysym (Return, space, h, j, …). `mod` means the
// configured primary modifier (mod_key). Recognised legacy call actions that have
// no skarwm equivalent yet (zoom, togglemaximize, inc/dec/zero/set gaps,
// restartwm, movemouse/resizemouse, bare view) are warned about and skipped so a
// older compatible configuration files still load.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:time"

// ----------------------------------------------------------------------------
// Types
// ----------------------------------------------------------------------------

Raw_Bind_Arg :: enum u8 { None, Num, Str }

Raw_Bind :: struct {
    combo:  string, // owned, e.g. "mod + Shift + h"
    action: string, // owned, e.g. "focusleft", "spawn", "ws_goto"
    argk:   Raw_Bind_Arg,
    argi:   int, // integer arg (workspace ids)
    args:   string, // string arg (spawn command)
    match_class, match_instance, match_title: string,
}

// Raw_Rule is a `rule :` line. Empty match field == wildcard. Only fields whose
// *_set flag is true impose anything.
Raw_Rule :: struct {
    class, instance, title: string,
    ws:                 int,
    floating:           bool,
    decorate:           bool,
    ws_set:             bool,
    floating_set:       bool,
    decorate_set:       bool,
}

Bar_Block_Kind :: enum u8 { Workspaces, Workspace_Meta, Layout, Title, Clock, Battery, Script, Systray, Button, Audio, Bluetooth, Network }
Bar_Block_Alignment :: enum u8 { Left, Center, Right }

// Raw_Bar_Block is owned configuration data. The WM publishes it for the
// standalone bar, but never executes script or button commands itself.
Raw_Bar_Block :: struct {
    kind: Bar_Block_Kind,
    alignment: Bar_Block_Alignment,
    name, command, click_command: string,
    interval_ms, timeout_ms: i32,
    foreground, background: u32,
    foreground_set, background_set: bool,
}

// Virtual_Screen_Profile is a declarative two-way horizontal split. The ratio
// is stored as a percentage to keep the rc syntax exact and easy to validate;
// geometry is always derived from the current physical output at activation.
Virtual_Screen_Profile :: struct {
    output: string,
    ratio_percent: i32,
    offset: i32,
}

Workspace_Layout_Rule :: struct {
    workspace: int,
    layout: c.Workspace_Layout,
}

// Config_Result is the fully-resolved product of a config load, ready to apply.
Config_Result :: struct {
    cfg:       c.Config,
    primary_mod: u16,
    bindings:  [dynamic]input.Binding,
    rules:     [dynamic]Raw_Rule,
    startups:  [dynamic]string,
    bar_blocks: [dynamic]Raw_Bar_Block,
    virtual_screens: [dynamic]Virtual_Screen_Profile,
    workspace_layouts: [dynamic]Workspace_Layout_Rule,
    source_paths: [dynamic]string,
}

// Load_Scratch accumulates raw settings + directives while the file is scanned.
// It exists so the `mod` from mod_key can be applied to every combo regardless
// of the order the lines appear in the file.
Load_Scratch :: struct {
    // mod token
    mod_key:     string,
    mod_key_set: bool,
    // numeric / boolean / colour config overrides (defaults applied at build)
    gap, outer_gap, inner_gap, border, corner_radius: i32,
    ffm, animations: bool,
    animation_duration_ms, animation_fps, preview_hover_delay_ms: i32,
    animation_easing: c.Animation_Easing,
    focused, unfocused: u32,
    decoration: c.Decoration_Config,
    bar_enabled: bool,
    bar_position: c.Bar_Position,
    bar_height, bar_tag_count, bar_font_size: i32,
    bar_font: string,
    bar_font_weight: c.Bar_Font_Weight,
    bar_foreground, bar_background: u32,
    bar_tag_foreground, bar_tag_background: u32,
    bar_block_foreground, bar_block_background: u32,
    gap_set, outer_set, inner_set, border_set, corner_radius_set, ffm_set: bool,
    animations_set, animation_duration_set, animation_fps_set, animation_easing_set, preview_hover_delay_set: bool,
    focused_set, unfocused_set: bool,
    decoration_enabled_set, decoration_titlebar_height_set: bool,
    decoration_border_width_set, decoration_resize_hit_width_set: bool,
    decoration_show_title_set, decoration_color_source_set: bool,
    decoration_audio_enabled_set, decoration_audio_show_percentage_set: bool,
    decoration_audio_slider_width_set, decoration_audio_volume_step_set: bool,
    decoration_accent_set, decoration_active_background_set: bool,
    decoration_inactive_background_set, decoration_active_foreground_set: bool,
    decoration_inactive_foreground_set, decoration_active_border_set: bool,
    decoration_inactive_border_set: bool,
    bar_enabled_set, bar_position_set, bar_height_set, bar_tag_count_set: bool,
    bar_font_set, bar_font_size_set, bar_font_weight_set: bool,
    bar_foreground_set, bar_background_set: bool,
    bar_tag_foreground_set, bar_tag_background_set: bool,
    bar_block_foreground_set, bar_block_background_set: bool,
    // directives
    binds:    [dynamic]Raw_Bind,
    rules:    [dynamic]Raw_Rule,
    startups: [dynamic]string,
    bar_blocks: [dynamic]Raw_Bar_Block,
    bar_blocks_set: bool,
    virtual_screens: [dynamic]Virtual_Screen_Profile,
    workspace_layouts: [dynamic]Workspace_Layout_Rule,
    warned:   [dynamic]string, // unknown settings already warned about
}

g_cfg_flag: string // -c FILE (owned; freed in cleanup_all)
g_active_config_path: string // successfully loaded absolute path (owned)
g_active_config_sources: [dynamic]string // main file plus recursive imports

// ----------------------------------------------------------------------------
// Scratch / list helpers
// ----------------------------------------------------------------------------

scratch_new :: proc() -> ^Load_Scratch {
    sc := new(Load_Scratch)
    sc.binds = make([dynamic]Raw_Bind, 0, 48)
    sc.rules = make([dynamic]Raw_Rule, 0, 8)
    sc.startups = make([dynamic]string, 0, 8)
    sc.bar_blocks = make([dynamic]Raw_Bar_Block, 0, 8)
    sc.virtual_screens = make([dynamic]Virtual_Screen_Profile, 0, 2)
    sc.workspace_layouts = make([dynamic]Workspace_Layout_Rule, 0, 4)
    sc.warned = make([dynamic]string, 0, 8)
    return sc
}

scratch_destroy :: proc(sc: ^Load_Scratch) {
    if sc == nil { return }
    if sc.mod_key != "" { delete(sc.mod_key) }
    if sc.bar_font != "" { delete(sc.bar_font) }
    for &b in sc.binds {
        if b.combo != "" { delete(b.combo) }
        if b.action != "" { delete(b.action) }
        if b.args != "" { delete(b.args) }
        if b.match_class != "" { delete(b.match_class) }
        if b.match_instance != "" { delete(b.match_instance) }
        if b.match_title != "" { delete(b.match_title) }
    }
    delete(sc.binds)
    release_rules(&sc.rules)
    for s in sc.startups { if s != "" { delete(s) } }
    delete(sc.startups)
    release_bar_blocks(&sc.bar_blocks)
    release_virtual_screens(&sc.virtual_screens)
    delete(sc.workspace_layouts)
    for w in sc.warned { if w != "" { delete(w) } }
    delete(sc.warned)
    free(sc)
}

// release_bindings frees every input.Binding.cmd string and the dynamic array itself,
// leaving *b zeroed. Safe to call on a moved-out (zero) dynamic array.
release_bindings :: proc(b: ^[dynamic]input.Binding) {
    for &x in b {
        if x.cmd != "" { delete(x.cmd) }
        if x.combo != "" { delete(x.combo) }
        if x.match_class != "" { delete(x.match_class) }
        if x.match_instance != "" { delete(x.match_instance) }
        if x.match_title != "" { delete(x.match_title) }
    }
    delete(b^)
    b^ = {}
}

// release_rules frees a [dynamic]Raw_Rule and its owned strings.
release_rules :: proc(rs: ^[dynamic]Raw_Rule) {
    for &r in rs {
        if r.class != "" { delete(r.class) }
        if r.instance != "" { delete(r.instance) }
        if r.title != "" { delete(r.title) }
    }
    delete(rs^)
    rs^ = {}
}

release_bar_blocks :: proc(blocks: ^[dynamic]Raw_Bar_Block) {
    for &block in blocks {
        if block.name != "" { delete(block.name) }
        if block.command != "" { delete(block.command) }
        if block.click_command != "" { delete(block.click_command) }
    }
    delete(blocks^)
    blocks^ = {}
}

release_virtual_screens :: proc(profiles: ^[dynamic]Virtual_Screen_Profile) {
    for &profile in profiles {
        if profile.output != "" { delete(profile.output) }
    }
    delete(profiles^)
    profiles^ = {}
}

free_errors :: proc(errs: ^[dynamic]string) {
    for e in errs { if e != "" { delete(e) } }
    delete(errs^)
    errs^ = {}
}

release_config_sources :: proc(paths: ^[dynamic]string) {
    for path in paths^ { if path != "" { delete(path) } }
    delete(paths^)
    paths^ = {}
}

clone_rule :: proc(r: Raw_Rule) -> Raw_Rule {
    out := r
    if r.class != "" { out.class = strings.clone(r.class) }
    if r.instance != "" { out.instance = strings.clone(r.instance) }
    if r.title != "" { out.title = strings.clone(r.title) }
    return out
}

// ----------------------------------------------------------------------------
// Small value parsers
// ----------------------------------------------------------------------------

// quoted_trim trims whitespace and one layer of surrounding double quotes.
quoted_trim :: proc(s: string) -> string {
    t := strings.trim_space(s)
    if len(t) >= 2 && t[0] == '"' && t[len(t) - 1] == '"' {
        t = t[1:len(t) - 1]
    }
    return strings.trim_space(t)
}

parse_i32_value :: proc(s: string) -> (i32, bool) {
    t := strings.trim_space(s)
    v, ok := strconv.parse_i64(t, 10)
    if !ok { return 0, false }
    return i32(v), true
}

// parse_color reads "#RRGGBB" (leading '#' optional) into a 0xRRGGBB u32.
parse_color :: proc(s: string) -> (u32, bool) {
    t := strings.trim_space(s)
    if len(t) > 0 && t[0] == '#' { t = t[1:] }
    if len(t) != 6 { return 0, false }
    v, ok := strconv.parse_u64(t, 16)
    if !ok || v > 0xFFFFFF { return 0, false }
    return u32(v), true
}

parse_bool_value :: proc(s: string) -> (bool, bool) {
    switch strings.trim_space(s) {
    case "true", "1":  return true, true
    case "false", "0": return false, true
    }
    return false, false
}

parse_animation_easing :: proc(s: string) -> (c.Animation_Easing, bool) {
    switch quoted_trim(s) {
    case "linear":         return .Linear, true
    case "ease_out_cubic": return .Ease_Out_Cubic, true
    }
    return {}, false
}

// split_ws splits on runs of spaces/tabs, dropping empty fields.
split_ws :: proc(s: string) -> [dynamic]string {
    out := make([dynamic]string, 0, 8)
    start := -1
    for i in 0 ..= len(s) {
        at_end := i == len(s)
        ch: u8 = 0
        if !at_end { ch = s[i] }
        if at_end || ch == ' ' || ch == '\t' {
            if start >= 0 {
                append(&out, s[start:i])
                start = -1
            }
        } else if start < 0 {
            start = i
        }
    }
    return out
}

// split_quoted_ws is the small selector tokenizer used by `call … focus`.
// Double quotes keep spaces inside one value; the returned strings borrow s.
split_quoted_ws :: proc(s: string) -> (out: [dynamic]string, err: string) {
    out = make([dynamic]string, 0, 8)
    i := 0
    for i < len(s) {
        for i < len(s) && (s[i] == ' ' || s[i] == '\t') { i += 1 }
        if i >= len(s) { break }
        if s[i] == '"' {
            start := i + 1
            i = start
            for i < len(s) && s[i] != '"' { i += 1 }
            if i >= len(s) {
                delete(out)
                return nil, strings.clone("unterminated quoted value")
            }
            append(&out, s[start:i])
            i += 1
            if i < len(s) && s[i] != ' ' && s[i] != '\t' {
                delete(out)
                return nil, strings.clone("expected whitespace after quoted value")
            }
        } else {
            start := i
            for i < len(s) && s[i] != ' ' && s[i] != '\t' { i += 1 }
            append(&out, s[start:i])
        }
    }
    return out, ""
}

parse_focus_bind :: proc(rb: ^Raw_Bind, args: string) -> string {
    toks, err := split_quoted_ws(args)
    if err != "" { return err }
    defer delete(toks)
    if len(toks) == 0 || len(toks) % 2 != 0 {
        return strings.clone("expected field/value pairs (class, instance, or title)")
    }
    for i := 0; i < len(toks); i += 2 {
        field, value := toks[i], toks[i + 1]
        if value == "" { return fmt.aprintf("empty %s value", field) }
        switch field {
        case "class":
            if rb.match_class != "" { return strings.clone("duplicate class criterion") }
            rb.match_class = strings.clone(value)
        case "instance":
            if rb.match_instance != "" { return strings.clone("duplicate instance criterion") }
            rb.match_instance = strings.clone(value)
        case "title":
            if rb.match_title != "" { return strings.clone("duplicate title criterion") }
            rb.match_title = strings.clone(value)
        case:
            return fmt.aprintf("unknown field %q (want class|instance|title)", field)
        }
    }
    return ""
}

// ----------------------------------------------------------------------------
// Combo + action resolution
// ----------------------------------------------------------------------------

// parse_combo splits a "mod + Shift + h" combo into a modifier mask and a
// keysym. The `mod` token resolves to the configured primary modifier (mod_key,
// "Mod4" by default). A combo with no modifier at all also gets that default.
parse_combo :: proc(combo, mod_key: string) -> (mods: u16, ks: u32, ok: bool, err: string) {
    parts := strings.split(combo, "+")
    defer delete(parts)
    mods = 0
    ks_name := ""
    for p in parts {
        t := strings.trim_space(p)
        if t == "" { continue }
        if t == "mod" {
            m := input.canonical_mods_for_name(mod_key, &g_wm.kb, &g_wm.mm)
            if m == 0 { m = x11.MOD_MASK_MOD4 }
            mods |= m
            continue
        }
        if m := input.canonical_mods_for_name(t, &g_wm.kb, &g_wm.mm); m != 0 {
            mods |= m
            continue
        }
        if ks_name != "" {
            return 0, 0, false, fmt.aprintf("combo %q names more than one key", combo)
        }
        ks_name = t
    }
    if ks_name == "" {
        return 0, 0, false, fmt.aprintf("combo %q names no key", combo)
    }
    if mods == 0 {
        m := input.canonical_mods_for_name(mod_key, &g_wm.kb, &g_wm.mm)
        if m == 0 { m = x11.MOD_MASK_MOD4 }
        mods = m
    }
    ks = input.keysym_from_name(ks_name)
    if ks == 0 {
        return 0, 0, false, fmt.aprintf("combo %q: unknown keysym %q", combo, ks_name)
    }
    return mods, ks, true, ""
}

// resolve_bind turns a Raw_Bind into a concrete input.Binding, or returns an error
// string. It allocates nothing that outlives the returned input.Binding.cmd.
resolve_bind :: proc(rb: Raw_Bind, mod_key: string) -> (out: input.Binding, err: string) {
    mods, ks, ok, e := parse_combo(rb.combo, mod_key)
    if !ok { return {}, e }
    base := input.Binding { mods = mods, keysym = ks }

    switch rb.action {
    case "spawn":
        if rb.args == "" {
            return {}, fmt.aprintf("bind(%q): empty command", rb.combo)
        }
        base.action = .Spawn
        base.cmd = strings.clone(rb.args)
        return base, ""

    case "focus", "focus_window":
        if rb.match_class == "" && rb.match_instance == "" && rb.match_title == "" {
            return {}, fmt.aprintf("bind(%q): focus requires class, instance, or title", rb.combo)
        }
        base.action = .Focus_Matching_Window
        if rb.match_class != "" { base.match_class = strings.clone(rb.match_class) }
        if rb.match_instance != "" { base.match_instance = strings.clone(rb.match_instance) }
        if rb.match_title != "" { base.match_title = strings.clone(rb.match_title) }
        return base, ""

    case "focusleft":  base.action = .Focus_Left;  return base, ""
    case "focusright": base.action = .Focus_Right; return base, ""
    case "focusup":    base.action = .Focus_Up;    return base, ""
    case "focusdown":  base.action = .Focus_Down;  return base, ""
    case "moveleft":   base.action = .Move_Left;   return base, ""
    case "moveright":  base.action = .Move_Right;  return base, ""
    case "moveup":     base.action = .Move_Up;     return base, ""
    case "movedown":   base.action = .Move_Down;   return base, ""
    case "resizeleft":  base.action = .Resize_Left;  return base, ""
    case "resizeright": base.action = .Resize_Right; return base, ""
    case "resizeup":    base.action = .Resize_Up;    return base, ""
    case "resizedown":  base.action = .Resize_Down;  return base, ""

    case "ws_up":    base.action = .WS_Next; return base, ""
    case "ws_down":  base.action = .WS_Prev; return base, ""
    case "ws_next":  base.action = .WS_Next; return base, ""
    case "ws_prev":  base.action = .WS_Prev; return base, ""
    case "tag_next", "move_to_ws_next": base.action = .Move_To_WS_Next; return base, ""
    case "tag_prev", "move_to_ws_prev": base.action = .Move_To_WS_Prev; return base, ""
    case "focus_output_next", "focusmonitor_next": base.action = .Focus_Output_Next; return base, ""
    case "focus_output_prev", "focusmonitor_prev": base.action = .Focus_Output_Prev; return base, ""
    case "move_to_output_next", "tagmonitor_next": base.action = .Move_To_Output_Next; return base, ""
    case "move_to_output_prev", "tagmonitor_prev": base.action = .Move_To_Output_Prev; return base, ""
    case "screen_split_toggle":
        if rb.argk == .Num && (rb.argi < 10 || rb.argi > 90) {
            return {}, fmt.aprintf("bind(%q): split ratio percent must be 10..90", rb.combo)
        }
        base.action = .Screen_Split_Toggle; base.arg = rb.argi; return base, ""
    case "screen_split_enable":
        if rb.argk == .Num && (rb.argi < 10 || rb.argi > 90) {
            return {}, fmt.aprintf("bind(%q): split ratio percent must be 10..90", rb.combo)
        }
        base.action = .Screen_Split_Enable; base.arg = rb.argi; return base, ""
    case "screen_split_disable":
        base.action = .Screen_Split_Disable; return base, ""
    case "screen_split_grow":
        base.action = .Screen_Split_Grow; base.arg = rb.argi; return base, ""
    case "screen_split_shrink":
        base.action = .Screen_Split_Shrink; base.arg = rb.argi; return base, ""
    case "screen_split_ratio":
        if rb.argk != .Num || rb.argi < 10 || rb.argi > 90 {
            return {}, fmt.aprintf("bind(%q): screen_split_ratio requires percent 10..90", rb.combo)
        }
        base.action = .Screen_Split_Ratio; base.arg = rb.argi; return base, ""

    case "togglefloating":   base.action = .Toggle_Floating;   return base, ""
    case "togglealwaysontop", "toggle_always_on_top", "alwaysontop":
        base.action = .Toggle_Always_On_Top; return base, ""
    case "togglefullscreen",
         "fullscreen":       base.action = .Toggle_Fullscreen; return base, ""
    case "layout_tabbed",
         "tabbed":           base.action = .Layout_Tabbed;     return base, ""
    case "layout_stacked",
         "stacked":          base.action = .Layout_Stacked;    return base, ""
    case "toggle_tabbed":    base.action = .Layout_Toggle;     return base, ""
    case "layout_scroller", "layout_scroll":
        base.action = .Layout_Scroller; return base, ""
    case "layout_scrolling_tile", "layout_scrolling-tile", "scrolling_tile", "scrolling-tile":
        base.action = .Layout_Scroller; return base, ""
    case "layout_vertical_scroller", "layout_vertical_scrolling_tile", "vertical-scroller", "vertical-scrolling-tile":
        base.action = .Layout_Vertical_Scroller; return base, ""
    case "layout_game", "layout_game_mode", "game", "game-mode":
        base.action = .Layout_Game; return base, ""
    case "layout_dwindle", "layout_fibonacci", "dwindle", "fibonacci":
        base.action = .Layout_Dwindle; return base, ""
    case "layout_monocle", "monocle":
        base.action = .Layout_Monocle; return base, ""
    case "layout_floating", "floating_all":
        base.action = .Layout_Floating; return base, ""
    case "layout_next", "switch_layout":
        base.action = .Layout_Next; return base, ""
    case "overview_next":    base.action = .Overview_Next;     return base, ""
    case "overview_prev":    base.action = .Overview_Prev;     return base, ""
    case "scratchpad_toggle", "scratchpad":
        if rb.argk != .Num || rb.argi < 0 {
            return {}, fmt.aprintf("bind(%q): scratchpad register must be >= 0", rb.combo)
        }
        base.action = .Scratchpad_Toggle; base.arg = rb.argi; return base, ""
    case "scratchpad_toggle_float":
        if rb.argk != .Num || rb.argi < 0 {
            return {}, fmt.aprintf("bind(%q): scratchpad register must be >= 0", rb.combo)
        }
        base.action = .Scratchpad_Toggle_Float; base.arg = rb.argi; return base, ""
    case "scratchpad_toggle_quake":
        if rb.argk != .Num || rb.argi < 0 {
            return {}, fmt.aprintf("bind(%q): scratchpad register must be >= 0", rb.combo)
        }
        base.action = .Scratchpad_Toggle_Quake; base.arg = rb.argi; return base, ""
    case "scratchpad_toggle_sidebar":
        if rb.argk != .Num || rb.argi < 0 {
            return {}, fmt.aprintf("bind(%q): scratchpad register must be >= 0", rb.combo)
        }
        base.action = .Scratchpad_Toggle_Sidebar; base.arg = rb.argi; return base, ""
    case "scratchpad_remove":
        if rb.argk != .Num || rb.argi < 0 {
            return {}, fmt.aprintf("bind(%q): scratchpad register must be >= 0", rb.combo)
        }
        base.action = .Scratchpad_Remove; base.arg = rb.argi; return base, ""
    case "show_bindings",
         "bindings_help":    base.action = .Show_Bindings;     return base, ""
    case "show_datetime",
         "notice_datetime":  base.action = .Show_Date_Time;    return base, ""
    case "show_battery",
         "notice_battery":   base.action = .Show_Battery;      return base, ""
    case "reminder_new",
         "set_reminder":     base.action = .Reminder_New;      return base, ""
    case "reminder_show_all",
         "show_reminders":   base.action = .Reminder_Show_All; return base, ""
    case "reminder_clear_all",
         "clear_reminders":  base.action = .Reminder_Clear_All; return base, ""
    case "close_window",
         "close":            base.action = .Close;             return base, ""
    case "reload_config",
         "reload":           base.action = .Reload;            return base, ""
    case "quit":             base.action = .Quit;              return base, ""

    case "ws_goto": // workspace : <combo> : view N
        if rb.argi < 1 {
            return {}, fmt.aprintf("bind(%q): workspace id must be >= 1", rb.combo)
        }
        base.action = .WS_Goto
        base.arg = rb.argi
        return base, ""
    case "ws_tag": // workspace : <combo> : tag N
        if rb.argi < 1 {
            return {}, fmt.aprintf("bind(%q): workspace id must be >= 1", rb.combo)
        }
        base.action = .Move_To_WS
        base.arg = rb.argi
        return base, ""

    case:
        return {}, fmt.aprintf("bind(%q): unknown action %q", rb.combo, rb.action)
    }
}

// Recognized legacy actions with no skarwm equivalent yet: warn and skip the
// line so older compatible configuration files still load.
unimplemented_action :: proc(action: string) -> bool {
    switch action {
    case "zoom", "togglemaximize", "inc_gaps", "dec_gaps", "zero_gaps",
         "setgaps", "restartwm", "movemouse", "resizemouse", "view":
        return true
    }
    return false
}

// Ignored legacy decorative settings accepted for compatibility but not applied.
ignored_setting :: proc(key: string) -> bool {
    switch key {
    case "norm_bg", "norm_inner_border",
         "sel_bg", "sel_inner_border",
         "urgent_color",
         "title_active_bg", "title_active_fg",
         "title_inactive_bg", "title_inactive_fg",
         "show_titlebar", "show_title", "show_buttons",
         "snap",
         "outer_border_width", "inner_border_width", "total_border_width",
         "insert_end", "strip_align",
         "show_move_indicator", "move_indicator_color":
        return true
    }
    return false
}

// ----------------------------------------------------------------------------
// build_result: resolve a filled Load_Scratch into a Config_Result
// ----------------------------------------------------------------------------

build_result :: proc(sc: ^Load_Scratch, errs: ^[dynamic]string) -> Config_Result {
    r: Config_Result
    r.cfg = c.Default_Config()
    if sc.gap_set     { r.cfg.Gap = sc.gap }
    if sc.outer_set   { r.cfg.OuterGap = sc.outer_gap }
    if sc.inner_set   { r.cfg.InnerGap = sc.inner_gap }
    if sc.border_set  { r.cfg.BorderWidth = sc.border }
    if sc.corner_radius_set { r.cfg.CornerRadius = sc.corner_radius }
    if sc.ffm_set     { r.cfg.FocusFollowsMouse = sc.ffm }
    if sc.preview_hover_delay_set { r.cfg.PreviewHoverDelayMs = sc.preview_hover_delay_ms }
    if sc.animations_set { r.cfg.Animations = sc.animations }
    if sc.animation_duration_set { r.cfg.AnimationDurationMs = sc.animation_duration_ms }
    if sc.animation_fps_set { r.cfg.AnimationFps = sc.animation_fps }
    if sc.animation_easing_set { r.cfg.AnimationEasing = sc.animation_easing }
    if sc.focused_set { r.cfg.FocusedBorder = sc.focused }
    if sc.unfocused_set { r.cfg.UnfocusedBorder = sc.unfocused }
    if sc.decoration_enabled_set { r.cfg.Decoration.Enabled = sc.decoration.Enabled }
    if sc.decoration_titlebar_height_set { r.cfg.Decoration.TitlebarHeight = sc.decoration.TitlebarHeight }
    if sc.decoration_border_width_set {
        r.cfg.Decoration.BorderWidth = sc.decoration.BorderWidth
    } else {
        // Decorated frames inherit the normal border unless explicitly overridden.
        r.cfg.Decoration.BorderWidth = r.cfg.BorderWidth
    }
    if sc.decoration_resize_hit_width_set { r.cfg.Decoration.ResizeHitWidth = sc.decoration.ResizeHitWidth }
    if sc.decoration_show_title_set { r.cfg.Decoration.ShowTitle = sc.decoration.ShowTitle }
    if sc.decoration_audio_enabled_set { r.cfg.Decoration.AudioEnabled = sc.decoration.AudioEnabled }
    if sc.decoration_audio_show_percentage_set { r.cfg.Decoration.AudioShowPercentage = sc.decoration.AudioShowPercentage }
    if sc.decoration_audio_slider_width_set { r.cfg.Decoration.AudioSliderWidth = sc.decoration.AudioSliderWidth }
    if sc.decoration_audio_volume_step_set { r.cfg.Decoration.AudioVolumeStep = sc.decoration.AudioVolumeStep }
    if sc.decoration_color_source_set { r.cfg.Decoration.ColorSource = sc.decoration.ColorSource }
    if sc.decoration_accent_set { r.cfg.Decoration.Accent = sc.decoration.Accent }
    if sc.decoration_active_background_set { r.cfg.Decoration.ActiveBackground = sc.decoration.ActiveBackground }
    if sc.decoration_inactive_background_set { r.cfg.Decoration.InactiveBackground = sc.decoration.InactiveBackground }
    if sc.decoration_active_foreground_set { r.cfg.Decoration.ActiveForeground = sc.decoration.ActiveForeground }
    if sc.decoration_inactive_foreground_set { r.cfg.Decoration.InactiveForeground = sc.decoration.InactiveForeground }
    if sc.decoration_active_border_set { r.cfg.Decoration.ActiveBorder = sc.decoration.ActiveBorder }
    if sc.decoration_inactive_border_set { r.cfg.Decoration.InactiveBorder = sc.decoration.InactiveBorder }
    if sc.bar_enabled_set { r.cfg.BarEnabled = sc.bar_enabled }
    if sc.bar_position_set { r.cfg.BarPosition = sc.bar_position }
    if sc.bar_height_set { r.cfg.BarHeight = sc.bar_height }
    if sc.bar_font_set {
        copy(r.cfg.BarFont[:], transmute([]u8)sc.bar_font)
        r.cfg.BarFontLen = i32(len(sc.bar_font))
    }
    if sc.bar_font_size_set { r.cfg.BarFontSize = sc.bar_font_size }
    if sc.bar_font_weight_set { r.cfg.BarFontWeight = sc.bar_font_weight }
    if sc.bar_foreground_set { r.cfg.BarForeground = sc.bar_foreground }
    if sc.bar_background_set { r.cfg.BarBackground = sc.bar_background }
    if sc.bar_tag_count_set { r.cfg.BarWorkspaceCount = sc.bar_tag_count }
    if sc.bar_tag_foreground_set { r.cfg.BarWorkspaceForeground = sc.bar_tag_foreground }
    if sc.bar_tag_background_set { r.cfg.BarWorkspaceBackground = sc.bar_tag_background }
    if sc.bar_block_foreground_set { r.cfg.BarBlockForeground = sc.bar_block_foreground }
    if sc.bar_block_background_set { r.cfg.BarBlockBackground = sc.bar_block_background }
    c.Apply_Gap_Alias(&r.cfg)

    mod_key := "Mod4"
    if sc.mod_key_set && sc.mod_key != "" { mod_key = sc.mod_key }
    r.primary_mod = input.canonical_mods_for_name(mod_key, &g_wm.kb, &g_wm.mm)

    r.bindings = make([dynamic]input.Binding, 0, 48)
    for rb in sc.binds {
        if unimplemented_action(rb.action) {
            logger.Warn("ignoring unsupported action:", rb.action,
                "(key", rb.combo, ")")
            continue
        }
        b, e := resolve_bind(rb, mod_key)
        if e != "" {
            append(errs, e)
            continue
        }
        b.combo = strings.clone(rb.combo)
        append(&r.bindings, b)
    }

    r.rules = make([dynamic]Raw_Rule, len(sc.rules))
    for rr, i in sc.rules {
        r.rules[i] = clone_rule(rr)
    }

    r.startups = make([dynamic]string, len(sc.startups))
    for s, i in sc.startups {
        r.startups[i] = strings.clone(s)
    }
    if sc.bar_blocks_set {
        r.bar_blocks = make([dynamic]Raw_Bar_Block, len(sc.bar_blocks))
        for block, i in sc.bar_blocks {
            r.bar_blocks[i] = block
            if block.name != "" { r.bar_blocks[i].name = strings.clone(block.name) }
            if block.command != "" { r.bar_blocks[i].command = strings.clone(block.command) }
            if block.click_command != "" {
                r.bar_blocks[i].click_command = strings.clone(block.click_command)
            }
        }
    } else {
        r.bar_blocks = make([dynamic]Raw_Bar_Block, 0, 3)
        append(&r.bar_blocks, Raw_Bar_Block{kind = .Workspaces, alignment = .Left})
        append(&r.bar_blocks, Raw_Bar_Block{kind = .Layout, alignment = .Left})
        append(&r.bar_blocks, Raw_Bar_Block{kind = .Title, alignment = .Center})
    }
    r.virtual_screens = make([dynamic]Virtual_Screen_Profile, len(sc.virtual_screens))
    for profile, i in sc.virtual_screens {
        r.virtual_screens[i] = profile
        r.virtual_screens[i].output = strings.clone(profile.output)
    }
    r.workspace_layouts = make([dynamic]Workspace_Layout_Rule, len(sc.workspace_layouts))
    copy(r.workspace_layouts[:], sc.workspace_layouts[:])
    return r
}

destroy_result :: proc(r: ^Config_Result) {
    release_bindings(&r.bindings)
    release_rules(&r.rules)
    for s in r.startups { if s != "" { delete(s) } }
    delete(r.startups)
    release_bar_blocks(&r.bar_blocks)
    release_virtual_screens(&r.virtual_screens)
    delete(r.workspace_layouts)
    release_config_sources(&r.source_paths)
    r^ = {}
}

// ----------------------------------------------------------------------------
// Loading
// ----------------------------------------------------------------------------

// warn_once logs an unknown setting key only the first time it is seen.
warn_once :: proc(sc: ^Load_Scratch, key: string) {
    for w in sc.warned {
        if w == key { return }
    }
    append(&sc.warned, strings.clone(key))
    logger.Warn("unknown setting ignored:", key)
}

// parse_setting handles a `key : value` line. Hard value errors are appended to
// errs and flag failure via the return value.
parse_setting :: proc(sc: ^Load_Scratch, key, value: string, errs: ^[dynamic]string) -> bool {
    switch key {
    case "mod_key", "modkey":
        v := strings.trim_space(value)
        if v == "" || input.canonical_mods_for_name(v, &g_wm.kb, &g_wm.mm) == 0 {
            append(errs, fmt.aprintf("mod_key: unknown modifier %q", v))
            return false
        }
        sc.mod_key = strings.clone(v)
        sc.mod_key_set = true
        return true

    case "gap":
        n, ok := parse_i32_value(value)
        if !ok { append(errs, fmt.aprintf("gap: bad number %q", value)); return false }
        sc.gap = n; sc.gap_set = true
        return true
    case "outer_gap":
        n, ok := parse_i32_value(value)
        if !ok { append(errs, fmt.aprintf("outer_gap: bad number %q", value)); return false }
        sc.outer_gap = n; sc.outer_set = true
        return true
    case "inner_gap":
        n, ok := parse_i32_value(value)
        if !ok { append(errs, fmt.aprintf("inner_gap: bad number %q", value)); return false }
        sc.inner_gap = n; sc.inner_set = true
        return true
    case "border_width":
        n, ok := parse_i32_value(value)
        if !ok || n < 0 || n > 4096 {
            append(errs, fmt.aprintf("border_width: expected 0..4096, got %q", value))
            return false
        }
        sc.border = n; sc.border_set = true
        return true
    case "corner_radius":
        n, ok := parse_i32_value(value)
        if !ok || n < 0 || n > 4096 {
            append(errs, fmt.aprintf("corner_radius: expected 0..4096, got %q", value))
            return false
        }
        sc.corner_radius = n; sc.corner_radius_set = true
        return true

    case "sel_outer_border":
        v, ok := parse_color(value)
        if !ok { append(errs, fmt.aprintf("sel_outer_border: expected #RRGGBB, got %q", value)); return false }
        sc.focused = v; sc.focused_set = true
        return true
    case "norm_outer_border":
        v, ok := parse_color(value)
        if !ok { append(errs, fmt.aprintf("norm_outer_border: expected #RRGGBB, got %q", value)); return false }
        sc.unfocused = v; sc.unfocused_set = true
        return true

    case "decorations_enabled":
        v, ok := parse_bool_value(value)
        if !ok { append(errs, fmt.aprintf("decorations_enabled: expected true/false, got %q", value)); return false }
        sc.decoration.Enabled = v; sc.decoration_enabled_set = true
        return true
    case "decoration_titlebar_height", "titlebar_height":
        n, ok := parse_i32_value(value)
        if !ok || n < 16 || n > 128 { append(errs, fmt.aprintf("decoration_titlebar_height: expected 16..128, got %q", value)); return false }
        sc.decoration.TitlebarHeight = n; sc.decoration_titlebar_height_set = true
        return true
    case "decoration_border_width":
        n, ok := parse_i32_value(value)
        if !ok || n < 0 || n > 32 { append(errs, fmt.aprintf("decoration_border_width: expected 0..32, got %q", value)); return false }
        sc.decoration.BorderWidth = n; sc.decoration_border_width_set = true
        return true
    case "decoration_resize_hit_width":
        n, ok := parse_i32_value(value)
        if !ok || n < 1 || n > 32 { append(errs, fmt.aprintf("decoration_resize_hit_width: expected 1..32, got %q", value)); return false }
        sc.decoration.ResizeHitWidth = n; sc.decoration_resize_hit_width_set = true
        return true
    case "decoration_show_title":
        v, ok := parse_bool_value(value)
        if !ok { append(errs, fmt.aprintf("decoration_show_title: expected true/false, got %q", value)); return false }
        sc.decoration.ShowTitle = v; sc.decoration_show_title_set = true
        return true
    case "decoration_audio_enabled":
        v, ok := parse_bool_value(value)
        if !ok { append(errs, fmt.aprintf("decoration_audio_enabled: expected true/false, got %q", value)); return false }
        sc.decoration.AudioEnabled = v; sc.decoration_audio_enabled_set = true
        return true
    case "decoration_audio_show_percentage":
        v, ok := parse_bool_value(value)
        if !ok { append(errs, fmt.aprintf("decoration_audio_show_percentage: expected true/false, got %q", value)); return false }
        sc.decoration.AudioShowPercentage = v; sc.decoration_audio_show_percentage_set = true
        return true
    case "decoration_audio_slider_width":
        n, ok := parse_i32_value(value)
        if !ok || n < 70 || n > 100 { append(errs, fmt.aprintf("decoration_audio_slider_width: expected 70..100, got %q", value)); return false }
        sc.decoration.AudioSliderWidth = n; sc.decoration_audio_slider_width_set = true
        return true
    case "decoration_audio_volume_step":
        n, ok := parse_i32_value(value)
        if !ok || n < 1 || n > 25 { append(errs, fmt.aprintf("decoration_audio_volume_step: expected 1..25, got %q", value)); return false }
        sc.decoration.AudioVolumeStep = n; sc.decoration_audio_volume_step_set = true
        return true
    case "decoration_color_source":
        switch quoted_trim(value) {
        case "active-border", "active_border": sc.decoration.ColorSource = .Active_Border
        case "accent": sc.decoration.ColorSource = .Accent
        case "explicit": sc.decoration.ColorSource = .Explicit
        case: append(errs, fmt.aprintf("decoration_color_source: expected active-border/accent/explicit, got %q", value)); return false
        }
        sc.decoration_color_source_set = true
        return true
    case "decoration_accent", "decoration_active_background", "decoration_inactive_background",
         "decoration_active_foreground", "decoration_inactive_foreground",
         "decoration_active_border", "decoration_inactive_border":
        v, ok := parse_color(value)
        if !ok { append(errs, fmt.aprintf("%s: expected #RRGGBB, got %q", key, value)); return false }
        switch key {
        case "decoration_accent": sc.decoration.Accent = v; sc.decoration_accent_set = true
        case "decoration_active_background": sc.decoration.ActiveBackground = v; sc.decoration_active_background_set = true
        case "decoration_inactive_background": sc.decoration.InactiveBackground = v; sc.decoration_inactive_background_set = true
        case "decoration_active_foreground": sc.decoration.ActiveForeground = v; sc.decoration_active_foreground_set = true
        case "decoration_inactive_foreground": sc.decoration.InactiveForeground = v; sc.decoration_inactive_foreground_set = true
        case "decoration_active_border": sc.decoration.ActiveBorder = v; sc.decoration_active_border_set = true
        case "decoration_inactive_border": sc.decoration.InactiveBorder = v; sc.decoration_inactive_border_set = true
        }
        return true

    case "focus_follows_mouse":
        v, ok := parse_bool_value(value)
        if !ok { append(errs, fmt.aprintf("focus_follows_mouse: expected true/false, got %q", value)); return false }
        sc.ffm = v; sc.ffm_set = true
        return true

    case "preview_hover_delay_ms":
        n, ok := parse_i32_value(value)
        if !ok || n < 0 || n > 5000 {
            append(errs, fmt.aprintf("preview_hover_delay_ms: expected 0..5000, got %q", value))
            return false
        }
        sc.preview_hover_delay_ms = n; sc.preview_hover_delay_set = true
        return true

    case "animations":
        v, ok := parse_bool_value(value)
        if !ok { append(errs, fmt.aprintf("animations: expected true/false, got %q", value)); return false }
        sc.animations = v; sc.animations_set = true
        return true
    case "animation_duration_ms":
        n, ok := parse_i32_value(value)
        if !ok || n < 0 || n > 5000 {
            append(errs, fmt.aprintf("animation_duration_ms: expected 0..5000, got %q", value))
            return false
        }
        sc.animation_duration_ms = n; sc.animation_duration_set = true
        return true
    case "animation_fps":
        n, ok := parse_i32_value(value)
        if !ok || n < 1 || n > 240 {
            append(errs, fmt.aprintf("animation_fps: expected 1..240, got %q", value))
            return false
        }
        sc.animation_fps = n; sc.animation_fps_set = true
        return true
    case "animation_easing":
        v, ok := parse_animation_easing(value)
        if !ok {
            append(errs, fmt.aprintf("animation_easing: expected linear/ease_out_cubic, got %q", value))
            return false
        }
        sc.animation_easing = v; sc.animation_easing_set = true
        return true

    case "bar_enabled":
        v, ok := parse_bool_value(value)
        if !ok { append(errs, fmt.aprintf("bar_enabled: expected true/false, got %q", value)); return false }
        sc.bar_enabled = v; sc.bar_enabled_set = true
        return true
    case "bar_position":
        switch quoted_trim(value) {
        case "top":    sc.bar_position = .Top
        case "bottom": sc.bar_position = .Bottom
        case:
            append(errs, fmt.aprintf("bar_position: expected top/bottom, got %q", value))
            return false
        }
        sc.bar_position_set = true
        return true
    case "bar_height":
        n, ok := parse_i32_value(value)
        if !ok || n < 1 || n > 512 {
            append(errs, fmt.aprintf("bar_height: expected 1..512, got %q", value))
            return false
        }
        sc.bar_height = n; sc.bar_height_set = true
        return true
    case "bar_font":
        font := quoted_trim(value)
        if font == "" || len(font) >= len(c.Config{}.BarFont) {
            append(errs, fmt.aprintf("bar_font: expected a font family shorter than 128 bytes, got %q", value))
            return false
        }
        if sc.bar_font != "" { delete(sc.bar_font) }
        sc.bar_font = strings.clone(font); sc.bar_font_set = true
        return true
    case "bar_font_size":
        n, ok := parse_i32_value(value)
        if !ok || n < 6 || n > 72 {
            append(errs, fmt.aprintf("bar_font_size: expected 6..72, got %q", value))
            return false
        }
        sc.bar_font_size = n; sc.bar_font_size_set = true
        return true
    case "bar_font_weight":
        switch quoted_trim(value) {
        case "normal", "regular": sc.bar_font_weight = .Normal
        case "medium": sc.bar_font_weight = .Medium
        case "bold": sc.bar_font_weight = .Bold
        case:
            append(errs, fmt.aprintf("bar_font_weight: expected normal/medium/bold, got %q", value))
            return false
        }
        sc.bar_font_weight_set = true
        return true
    case "bar_foreground":
        v, ok := parse_color(value)
        if !ok { append(errs, fmt.aprintf("bar_foreground: expected #RRGGBB, got %q", value)); return false }
        sc.bar_foreground = v; sc.bar_foreground_set = true
        return true
    case "bar_background":
        v, ok := parse_color(value)
        if !ok { append(errs, fmt.aprintf("bar_background: expected #RRGGBB, got %q", value)); return false }
        sc.bar_background = v; sc.bar_background_set = true
        return true
    case "bar_tag_count", "bar_workspace_count":
        n, ok := parse_i32_value(value)
        if !ok || n < 1 || n > 64 {
            append(errs, fmt.aprintf("bar_tag_count: expected 1..64, got %q", value))
            return false
        }
        sc.bar_tag_count = n; sc.bar_tag_count_set = true
        return true
    case "bar_tag_foreground", "bar_workspace_foreground":
        v, ok := parse_color(value)
        if !ok { append(errs, fmt.aprintf("bar_tag_foreground: expected #RRGGBB, got %q", value)); return false }
        sc.bar_tag_foreground = v; sc.bar_tag_foreground_set = true
        return true
    case "bar_tag_background", "bar_workspace_background":
        v, ok := parse_color(value)
        if !ok { append(errs, fmt.aprintf("bar_tag_background: expected #RRGGBB, got %q", value)); return false }
        sc.bar_tag_background = v; sc.bar_tag_background_set = true
        return true
    case "bar_block_foreground":
        v, ok := parse_color(value)
        if !ok { append(errs, fmt.aprintf("bar_block_foreground: expected #RRGGBB, got %q", value)); return false }
        sc.bar_block_foreground = v; sc.bar_block_foreground_set = true
        return true
    case "bar_block_background":
        v, ok := parse_color(value)
        if !ok { append(errs, fmt.aprintf("bar_block_background: expected #RRGGBB, got %q", value)); return false }
        sc.bar_block_background = v; sc.bar_block_background_set = true
        return true

    case:
        if ignored_setting(key) { return true }
        warn_once(sc, key)
        return true
    }
}

next_directive_field :: proc(rest: ^string) -> (string, bool) {
    colon := strings.index_byte(rest^, ':')
    if colon < 0 { return "", false }
    field := strings.trim_space(rest^[:colon])
    rest^ = strings.trim_space(rest^[colon + 1:])
    return field, field != ""
}

parse_bar_alignment :: proc(value: string) -> (Bar_Block_Alignment, bool) {
    switch strings.trim_space(value) {
    case "left": return .Left, true
    case "center": return .Center, true
    case "right": return .Right, true
    }
    return {}, false
}

parse_optional_bar_colour :: proc(value: string) -> (colour: u32, set, valid: bool) {
    trimmed := strings.trim_space(value)
    if trimmed == "_" { return 0, false, true }
    parsed, ok := parse_color(trimmed)
    return parsed, ok, ok
}

parse_bar_colours :: proc(value: string) -> (
    foreground, background: u32, foreground_set, background_set, valid: bool,
) {
    fields := strings.split(value, ":")
    defer delete(fields)
    if len(fields) != 2 { return 0, 0, false, false, false }
    foreground_ok, background_ok: bool
    foreground, foreground_set, foreground_ok = parse_optional_bar_colour(fields[0])
    background, background_set, background_ok = parse_optional_bar_colour(fields[1])
    return foreground, background, foreground_set, background_set,
        foreground_ok && background_ok
}

// Script/button commands remain the final field and may themselves contain
// colons. Treat two leading fields as colours only when both parse as a colour
// (or `_`, meaning inherit); otherwise leave the command untouched.
take_leading_bar_colours :: proc(remaining: ^string) -> (
    foreground, background: u32, foreground_set, background_set: bool,
) {
    original := remaining^
    foreground_text, has_foreground := next_directive_field(remaining)
    background_text, has_background := next_directive_field(remaining)
    if !has_foreground || !has_background {
        remaining^ = original
        return
    }
    foreground_ok, background_ok: bool
    foreground, foreground_set, foreground_ok = parse_optional_bar_colour(foreground_text)
    background, background_set, background_ok = parse_optional_bar_colour(background_text)
    if !foreground_ok || !background_ok {
        remaining^ = original
        return 0, 0, false, false
    }
    return foreground, background, foreground_set, background_set
}

parse_bar_block :: proc(sc: ^Load_Scratch, rest: string, errs: ^[dynamic]string) -> bool {
    remaining := rest
    kind, has_kind := next_directive_field(&remaining)
    if !has_kind {
        append(errs, fmt.aprintf("bar_block: expected a block kind and alignment, got %q", remaining))
        return false
    }

    switch kind {
    case "workspaces", "layout", "title", "systray":
        alignment_text := remaining
        colour_text := ""
        if parsed_alignment, has_more := next_directive_field(&remaining); has_more {
            alignment_text = parsed_alignment
            colour_text = remaining
        }
        alignment, ok := parse_bar_alignment(alignment_text)
        if !ok {
            append(errs, fmt.aprintf("bar_block(%s): expected left/center/right, got %q", kind, alignment_text))
            return false
        }
        foreground, background: u32
        foreground_set, background_set := false, false
        if colour_text != "" {
            valid: bool
            foreground, background, foreground_set, background_set, valid = parse_bar_colours(colour_text)
            if !valid {
                append(errs, fmt.aprintf("bar_block(%s): expected foreground : background colours, got %q", kind, colour_text))
                return false
            }
        }
        block_kind := Bar_Block_Kind.Workspaces
        if kind == "layout" { block_kind = .Layout }
        if kind == "title" { block_kind = .Title }
        if kind == "systray" { block_kind = .Systray }
        append(&sc.bar_blocks, Raw_Bar_Block{
            kind = block_kind, alignment = alignment,
            foreground = foreground, background = background,
            foreground_set = foreground_set, background_set = background_set,
        })
    case "script":
        alignment_text, ok_alignment := next_directive_field(&remaining)
        name, ok_name := next_directive_field(&remaining)
        interval_text, ok_interval := next_directive_field(&remaining)
        timeout_text, ok_timeout := next_directive_field(&remaining)
        alignment, valid_alignment := parse_bar_alignment(alignment_text)
        interval, valid_interval := parse_i32_value(interval_text)
        timeout, valid_timeout := parse_i32_value(timeout_text)
        foreground, background, foreground_set, background_set :=
            take_leading_bar_colours(&remaining)
        command := quoted_trim(remaining)
        if !ok_alignment || !valid_alignment || !ok_name || len(name) > 64 ||
           !ok_interval || !valid_interval || interval < 1 || interval > 86400 ||
           !ok_timeout || !valid_timeout || timeout < 1 || timeout > 60 ||
           command == "" || len(command) >= 1024 {
            append(errs, fmt.aprintf(
                "bar_block(script): expected alignment : name : interval(1..86400) : timeout(1..60) : command, got %q",
                remaining,
            ))
            return false
        }
        append(&sc.bar_blocks, Raw_Bar_Block{
            kind = .Script, alignment = alignment,
            name = strings.clone(name), command = strings.clone(command),
            interval_ms = interval * 1000, timeout_ms = timeout * 1000,
            foreground = foreground, background = background,
            foreground_set = foreground_set, background_set = background_set,
        })
    case "button":
        alignment_text, ok_alignment := next_directive_field(&remaining)
        label, ok_label := next_directive_field(&remaining)
        alignment, valid_alignment := parse_bar_alignment(alignment_text)
        foreground, background, foreground_set, background_set :=
            take_leading_bar_colours(&remaining)
        command := quoted_trim(remaining)
        if !ok_alignment || !valid_alignment || !ok_label || label == "" || len(label) > 64 ||
           command == "" || len(command) >= 1024 {
            append(errs, fmt.aprintf(
                "bar_block(button): expected alignment : label : command, got %q",
                remaining,
            ))
            return false
        }
        append(&sc.bar_blocks, Raw_Bar_Block{
            kind = .Button, alignment = alignment,
            name = strings.clone(label), command = strings.clone(command),
            foreground = foreground, background = background,
            foreground_set = foreground_set, background_set = background_set,
        })
    case "audio", "bluetooth", "network", "battery", "clock":
        original := remaining
        alignment_text := strings.trim_space(remaining)
        tail := ""
        if parsed_alignment, has_tail := next_directive_field(&remaining); has_tail {
            alignment_text = parsed_alignment
            tail = strings.trim_space(remaining)
        }
        alignment, valid_alignment := parse_bar_alignment(alignment_text)
        label := ""
        foreground, background: u32
        foreground_set, background_set := false, false
        click_command := ""
        valid_tail := true
        if tail != "" {
            foreground, background, foreground_set, background_set, colours_only :=
                parse_bar_colours(tail)
            if !colours_only && tail[0] == '"' {
                click_command = quoted_trim(tail)
                valid_tail = click_command != "" && len(click_command) < 1024
            } else if !colours_only {
                colours_and_command := tail
                foreground, background, foreground_set, background_set =
                    take_leading_bar_colours(&colours_and_command)
                if colours_and_command != tail {
                    click_command = quoted_trim(colours_and_command)
                    valid_tail = click_command != "" && len(click_command) < 1024
                } else {
                    legacy := tail
                    parsed_label, has_extra := next_directive_field(&legacy)
                    if has_extra {
                        label = parsed_label
                        foreground, background, foreground_set, background_set, colours_only =
                            parse_bar_colours(legacy)
                        if !colours_only {
                            colour_tail := legacy
                            foreground, background, foreground_set, background_set =
                                take_leading_bar_colours(&colour_tail)
                            if colour_tail != legacy {
                                click_command = quoted_trim(colour_tail)
                            } else {
                                click_command = quoted_trim(legacy)
                            }
                            valid_tail = click_command != "" && len(click_command) < 1024
                        }
                    } else {
                        label = tail
                    }
                }
            }
        }
        if !valid_alignment || len(label) > 64 || !valid_tail {
            append(errs, fmt.aprintf(
                "bar_block(%s): expected alignment [: label] [: foreground : background] [: click command], got %q",
                kind, original,
            ))
            return false
        }
        block_kind := Bar_Block_Kind.Audio
        if kind == "bluetooth" { block_kind = .Bluetooth }
        if kind == "network" { block_kind = .Network }
        if kind == "battery" { block_kind = .Battery }
        if kind == "clock" { block_kind = .Clock }
        append(&sc.bar_blocks, Raw_Bar_Block{
            kind = block_kind, alignment = alignment, name = strings.clone(label),
            click_command = strings.clone(click_command),
            foreground = foreground, background = background,
            foreground_set = foreground_set, background_set = background_set,
        })
    case:
        append(errs, fmt.aprintf("bar_block: unknown block kind %q", kind))
        return false
    }
    sc.bar_blocks_set = true
    return true
}

parse_virtual_screen :: proc(sc: ^Load_Scratch, rest: string, errs: ^[dynamic]string) -> bool {
    fields := strings.split(rest, ":")
    defer delete(fields)
    if len(fields) < 3 || len(fields) > 4 {
        append(errs, fmt.aprintf(
            "virtual_screen: expected output : split : percent [: offset], got %q", rest,
        ))
        return false
    }
    output := strings.trim_space(fields[0])
    mode := strings.trim_space(fields[1])
    ratio_text := strings.trim_space(fields[2])
    has_offset := len(fields) == 4
    offset_text := ""
    if has_offset { offset_text = strings.trim_space(fields[3]) }
    if output == "" || mode != "split" || ratio_text == "" || (has_offset && offset_text == "") {
        append(errs, fmt.aprintf(
            "virtual_screen: expected output : split : percent [: offset], got %q", rest,
        ))
        return false
    }
    ratio, ok := parse_i32_value(ratio_text)
    if !ok || ratio < 10 || ratio > 90 {
        append(errs, fmt.aprintf("virtual_screen(%q): split percent must be 10..90", output))
        return false
    }
    offset: i32
    if has_offset {
        offset, ok = parse_i32_value(offset_text)
        if !ok {
            append(errs, fmt.aprintf("virtual_screen(%q): invalid pixel offset %q", output, offset_text))
            return false
        }
    }
    for profile in sc.virtual_screens {
        if profile.output == output {
            append(errs, fmt.aprintf("virtual_screen: duplicate output %q", output))
            return false
        }
    }
    append(&sc.virtual_screens, Virtual_Screen_Profile{
        output = strings.clone(output), ratio_percent = ratio, offset = offset,
    })
    return true
}

parse_workspace_layout :: proc(sc: ^Load_Scratch, rest: string, errs: ^[dynamic]string) -> bool {
    fields := strings.split(rest, ":")
    defer delete(fields)
    if len(fields) != 2 {
        append(errs, fmt.aprintf(
            "workspace_layout: expected workspace : layout, got %q", rest,
        ))
        return false
    }
    workspace_text := strings.trim_space(fields[0])
    layout_text := strings.trim_space(fields[1])
    workspace, ok := parse_i32_value(workspace_text)
    if !ok || workspace < 1 || workspace > c.IPC_MAX_WORKSPACE_ID {
        append(errs, fmt.aprintf(
            "workspace_layout: workspace must be 1..%d, got %q",
            c.IPC_MAX_WORKSPACE_ID, workspace_text,
        ))
        return false
    }
    layout: c.Workspace_Layout
    switch layout_text {
    case "scrolling-tile", "scrolling_tile", "scroller", "scroll": layout = .Scroller
    case "vertical-scrolling-tile", "vertical_scrolling_tile", "vertical-scroller": layout = .Vertical_Scroller
    case "game", "game-mode", "game_mode": layout = .Game
    case "dwindle", "fibonacci": layout = .Dwindle
    case "monocle": layout = .Monocle
    case "floating", "float": layout = .Floating
    case:
        append(errs, fmt.aprintf(
            "workspace_layout(%d): unknown layout %q", workspace, layout_text,
        ))
        return false
    }
    for rule in sc.workspace_layouts {
        if rule.workspace == int(workspace) {
            append(errs, fmt.aprintf(
                "workspace_layout: duplicate workspace %d", workspace,
            ))
            return false
        }
    }
    append(&sc.workspace_layouts, Workspace_Layout_Rule{
        workspace = int(workspace), layout = layout,
    })
    return true
}

parse_workspace_declaration :: proc(sc: ^Load_Scratch, rest: string, errs: ^[dynamic]string) -> bool {
    fields := strings.split(rest, ":")
    defer delete(fields)
    if len(fields) < 3 || len(fields) > 4 {
        append(errs, fmt.aprintf("workspace: expected ID : layout : icon [: name], got %q", rest))
        return false
    }
    id_text := strings.trim_space(fields[0])
    layout_text := strings.trim_space(fields[1])
    icon := quoted_trim(fields[2])
    name := ""
    if len(fields) == 4 { name = quoted_trim(fields[3]) }
    id, id_ok := parse_i32_value(id_text)
    if !id_ok || id < 1 || id > 64 || icon == "" || len(icon) > 64 || len(name) > 128 {
        append(errs, fmt.aprintf("workspace: invalid ID, icon, or name in %q", rest))
        return false
    }
    for block in sc.bar_blocks {
        if block.kind == .Workspace_Meta && block.interval_ms == id {
            append(errs, fmt.aprintf("workspace: duplicate declaration for %d", id))
            return false
        }
    }
    layout_rule := fmt.aprintf("%s : %s", id_text, layout_text)
    defer delete(layout_rule)
    if !parse_workspace_layout(sc, layout_rule, errs) { return false }
    append(&sc.bar_blocks, Raw_Bar_Block{kind = .Workspace_Meta,
        name = strings.clone(icon), command = strings.clone(name), interval_ms = id})
    sc.bar_blocks_set = true
    return true
}

// parse_directive handles bind/call/workspace/rule/autostart/bar_block,
// virtual_screen, workspace-N metadata, deprecated per-workspace layout
// directives, and mousebind lines.
parse_directive :: proc(sc: ^Load_Scratch, key, rest: string, errs: ^[dynamic]string) -> bool {
    // Keep these compatibility names ahead of the workspace_ID prefix parser.
    if key == "workspace_layout" || key == "tag_layout" {
        return parse_workspace_layout(sc, rest, errs)
    }

    prefix_len := 0
    if len(key) > len("workspace-") && key[:len("workspace-")] == "workspace-" {
        prefix_len = len("workspace-")
    } else if len(key) > len("workspace_") && key[:len("workspace_")] == "workspace_" {
        prefix_len = len("workspace_")
    }
    if prefix_len > 0 {
        id, ok := parse_i32_value(key[prefix_len:])
        if !ok { append(errs, fmt.aprintf("%s: invalid workspace ID", key)); return false }
        declaration := fmt.aprintf("%d : %s", id, rest)
        defer delete(declaration)
        return parse_workspace_declaration(sc, declaration, errs)
    }
    switch key {
    case "virtual_screen":
        return parse_virtual_screen(sc, rest, errs)

    case "bar_block":
        return parse_bar_block(sc, rest, errs)

    case "autostart":
        cmd := quoted_trim(rest)
        if cmd == "" {
            append(errs, "autostart: empty command")
            return false
        }
        append(&sc.startups, strings.clone(cmd))
        return true

    case "mousebind":
        logger.Warn("ignoring mousebind (no mouse-action system yet):", rest)
        return true

    case "bind", "call", "workspace":
        // rest = "<combo> : <tail>"
        c2 := strings.index_byte(rest, ':')
        if c2 < 0 {
            append(errs, fmt.aprintf("%s: expected \"combo : …\", got %q", key, rest))
            return false
        }
        combo := strings.trim_space(rest[:c2])
        tail := strings.trim_space(rest[c2 + 1:])
        if combo == "" {
            append(errs, fmt.aprintf("%s: empty combo", key))
            return false
        }

        rb := Raw_Bind { combo = strings.clone(combo) }
        switch key {
        case "bind":
            cmd := quoted_trim(tail)
            if cmd == "" {
                append(errs, fmt.aprintf("bind(%q): empty command", combo))
                free_bind(&rb)
                return false
            }
            rb.action = strings.clone("spawn")
            rb.argk = .Str
            rb.args = strings.clone(cmd)
        case "call":
            act := quoted_trim(tail)
            action_end := 0
            for action_end < len(act) && act[action_end] != ' ' && act[action_end] != '\t' {
                action_end += 1
            }
            action_name := act[:action_end]
            action_args := strings.trim_space(act[action_end:])
            if action_name == "focus" || action_name == "focus_window" {
                rb.action = strings.clone(action_name)
                if focus_err := parse_focus_bind(&rb, action_args); focus_err != "" {
                    append(errs, fmt.aprintf("call(%q): focus: %s", combo, focus_err))
                    delete(focus_err)
                    free_bind(&rb)
                    return false
                }
                append(&sc.binds, rb)
                return true
            }
            toks := split_ws(act)
            defer delete(toks)
            if len(toks) < 1 || len(toks) > 2 {
                append(errs, fmt.aprintf("call(%q): expected an action and optional number, got %q", combo, tail))
                free_bind(&rb)
                return false
            }
            rb.action = strings.clone(toks[0])
            if len(toks) == 2 {
                n, ok := parse_i32_value(toks[1])
                if !ok || n < 0 {
                    append(errs, fmt.aprintf("call(%q): bad numeric argument %q", combo, toks[1]))
                    free_bind(&rb)
                    return false
                }
                rb.argk = .Num
                rb.argi = int(n)
            }
        case "workspace":
            // tail = "view N" | "tag N"
            toks := split_ws(tail)
            defer delete(toks)
            if len(toks) != 2 || (toks[0] != "view" && toks[0] != "tag") {
                append(errs, fmt.aprintf("workspace(%q): expected \"view <N>\" or \"tag <N>\", got %q", combo, tail))
                free_bind(&rb)
                return false
            }
            n, ok := parse_i32_value(toks[1])
            if !ok || n < 1 {
                append(errs, fmt.aprintf("workspace(%q): bad workspace id %q", combo, toks[1]))
                free_bind(&rb)
                return false
            }
            if toks[0] == "view" { rb.action = strings.clone("ws_goto") } else { rb.action = strings.clone("ws_tag") }
            rb.argk = .Num
            rb.argi = int(n)
        }
        append(&sc.binds, rb)
        return true

    case "rule":
        // rest = "<field> : <pattern> : <effects…>"
        c2 := strings.index_byte(rest, ':')
        if c2 < 0 {
            append(errs, fmt.aprintf("rule: expected \"field : pattern : effects\", got %q", rest))
            return false
        }
        field := strings.trim_space(rest[:c2])
        rest2 := rest[c2 + 1:]
        c3 := strings.index_byte(rest2, ':')
        if c3 < 0 {
            append(errs, fmt.aprintf("rule: expected \"field : pattern : effects\", got %q", rest))
            return false
        }
        pattern := quoted_trim(rest2[:c3])
        effects := strings.trim_space(rest2[c3 + 1:])

        rr := Raw_Rule {}
        switch field {
        case "class":
            rr.class = strings.clone(pattern)
        case "instance":
            rr.instance = strings.clone(pattern)
        case "title":
            rr.title = strings.clone(pattern)
        case:
            append(errs, fmt.aprintf("rule: unknown match field %q (want class|instance|title)", field))
            return false
        }

        toks := split_ws(effects)
        defer delete(toks)
        i := 0
        bad := false
        for i < len(toks) {
            switch toks[i] {
            case "workspace":
                if i + 1 >= len(toks) {
                    append(errs, fmt.aprintf("rule %q: workspace needs a number", pattern))
                    bad = true; i += 1; continue
                }
                n, ok := parse_i32_value(toks[i + 1])
                if !ok || n < 1 {
                    append(errs, fmt.aprintf("rule %q: bad workspace id %q", pattern, toks[i + 1]))
                    bad = true; i += 2; continue
                }
                rr.ws = int(n); rr.ws_set = true
                i += 2
            case "floating":
                rr.floating = true; rr.floating_set = true
                i += 1
                if i < len(toks) {
                    if toks[i] == "true" { i += 1 }
                    else if toks[i] == "false" { rr.floating = false; i += 1 }
                }
            case "decorate":
                rr.decorate = true; rr.decorate_set = true
                i += 1
                if i < len(toks) {
                    if toks[i] == "true" { i += 1 }
                    else if toks[i] == "false" { rr.decorate = false; i += 1 }
                }
            case:
                append(errs, fmt.aprintf("rule %q: unknown effect %q (want workspace <N>, floating, or decorate)", pattern, toks[i]))
                bad = true
                i += 1
            }
        }
        if bad {
            release_rule(&rr)
            return false
        }
        append(&sc.rules, rr)
        return true
    }
    return true
}

free_bind :: proc(rb: ^Raw_Bind) {
    if rb.combo != "" { delete(rb.combo) }
    if rb.action != "" { delete(rb.action) }
    if rb.args != "" { delete(rb.args) }
    if rb.match_class != "" { delete(rb.match_class) }
    if rb.match_instance != "" { delete(rb.match_instance) }
    if rb.match_title != "" { delete(rb.match_title) }
    rb^ = {}
}

release_rule :: proc(rr: ^Raw_Rule) {
    if rr.class != "" { delete(rr.class) }
    if rr.instance != "" { delete(rr.instance) }
    if rr.title != "" { delete(rr.title) }
    rr^ = {}
}

// scan_rc parses `data` into the scratch. Imports are expanded in place and
// relative paths are resolved from the file containing the directive.
scan_rc :: proc(
    sc: ^Load_Scratch,
    data: []byte,
    source_path: string,
    import_stack: ^[dynamic]string,
    source_paths: ^[dynamic]string,
    errs: ^[dynamic]string,
) -> bool {
    ok := true
    lines := strings.split_lines(string(data))
    defer delete(lines)
    for ln in lines {
        line := strings.trim_space(ln)
        if line == "" { continue }
        if line[0] == '#' { continue } // whole-line comment

        colon := strings.index_byte(line, ':')
        if colon < 0 {
            append(errs, fmt.aprintf("ignoring line with no ':' — %q", line))
            ok = false
            continue
        }
        key := strings.trim_space(line[:colon])
        rest := strings.trim_space(line[colon + 1:])

        if key == "workspace_layout" || key == "tag_layout" {
            if !parse_directive(sc, key, rest, errs) { ok = false }
            continue
        }
        if len(key) > len("workspace-") && key[:len("workspace-")] == "workspace-" ||
           len(key) > len("workspace_") && key[:len("workspace_")] == "workspace_" {
            if !parse_directive(sc, key, rest, errs) { ok = false }
            continue
        }
        switch key {
        case "import":
            target := quoted_trim(rest)
            if target == "" {
                append(errs, fmt.aprintf("%s: import path is empty", source_path))
                ok = false
                continue
            }
            import_path := target
            joined := ""
            if !filepath.is_abs(target) {
                joined_path, join_error := filepath.join({filepath.dir(source_path), target})
                if join_error != nil {
                    append(errs, fmt.aprintf("%s: cannot resolve import %q", source_path, target))
                    ok = false
                    continue
                }
                joined = joined_path
                import_path = joined
            }
            if !scan_rc_file(sc, import_path, import_stack, source_paths, errs) { ok = false }
            if joined != "" { delete(joined) }
        case "bind", "call", "workspace",
             "rule", "autostart", "bar_block", "virtual_screen", "mousebind":
            if !parse_directive(sc, key, rest, errs) { ok = false }
        case:
            if !parse_setting(sc, key, rest, errs) { ok = false }
        }
    }
    return ok
}

// scan_rc_file canonicalizes each source before checking the active recursion
// stack, so direct, indirect, and symlink-assisted import cycles are rejected.
scan_rc_file :: proc(
    sc: ^Load_Scratch,
    path: string,
    import_stack: ^[dynamic]string,
    source_paths: ^[dynamic]string,
    errs: ^[dynamic]string,
) -> bool {
    if len(import_stack^) >= 64 {
        append(errs, fmt.aprintf("config import depth exceeds 64 at: %s", path))
        return false
    }
    absolute, path_error := filepath.abs(path)
    if path_error != nil {
        append(errs, fmt.aprintf("cannot read config file: %s", path))
        return false
    }
    defer delete(absolute)

    for active in import_stack^ {
        if active == absolute {
            append(errs, fmt.aprintf("config import cycle: %s", absolute))
            return false
        }
    }

    data, file_error := os.read_entire_file_from_path(absolute, context.allocator)
    if file_error != nil {
        append(errs, fmt.aprintf("cannot read config file: %s", absolute))
        return false
    }
    defer delete(data)

    seen := false
    for source in source_paths^ {
        if source == absolute { seen = true; break }
    }
    if !seen { append(source_paths, strings.clone(absolute)) }

    append(import_stack, strings.clone(absolute))
    defer delete(pop(import_stack))
    return scan_rc(sc, data, absolute, import_stack, source_paths, errs)
}

// cfg_file_result loads and validates an rc config file. `ok` is true only when
// every directive resolved; r is then valid. On failure r is undefined (caller
// must not touch it) and errs carries the diagnostic messages.
cfg_file_result :: proc(path: string) -> (r: Config_Result, errs: [dynamic]string, ok: bool) {
    errs = make([dynamic]string, 0, 4)
    sc := scratch_new()
    defer scratch_destroy(sc)
    import_stack := make([dynamic]string, 0, 4)
    defer delete(import_stack)
    source_paths := make([dynamic]string, 0, 4)

    if !scan_rc_file(sc, path, &import_stack, &source_paths, &errs) {
        release_config_sources(&source_paths)
        return {}, errs, false
    }

    r = build_result(sc, &errs)
    if len(errs) > 0 {
        destroy_result(&r)
        release_config_sources(&source_paths)
        return {}, errs, false
    }
    r.source_paths = source_paths
    return r, errs, true
}

// ----------------------------------------------------------------------------
// Applying
// ----------------------------------------------------------------------------

startup_ran :: proc(s: string) -> bool {
    for e in g_wm.ran_startups {
        if e == s { return true }
    }
    return false
}

profile_for_output :: proc(profiles: []Virtual_Screen_Profile, output: string) -> (^Virtual_Screen_Profile, bool) {
    for &profile in profiles {
        if profile.output == output { return &profile, true }
    }
    return nil, false
}

virtual_profile_fits :: proc(profile: Virtual_Screen_Profile, p: ^c.Physical_Output) -> bool {
    if p == nil { return true } // retain profiles for disconnected outputs
    left := i32(f64(p.Geom.W) * (f64(profile.ratio_percent) / 100.0) + 0.5) + profile.offset
    return left >= c.MIN_LOGICAL_SCREEN_WIDTH &&
           p.Geom.W - left >= c.MIN_LOGICAL_SCREEN_WIDTH
}

validate_virtual_profiles :: proc(profiles: []Virtual_Screen_Profile) -> string {
    if g_wm.m == nil { return "" }
    for profile in profiles {
        p := c.Find_Physical_Output(g_wm.m, profile.output)
        if !virtual_profile_fits(profile, p) {
            return fmt.aprintf(
                "virtual_screen(%q): split does not fit current physical width", profile.output,
            )
        }
    }
    return ""
}

apply_current_virtual_screens :: proc() {
    if g_wm.m == nil { return }
    for profile in g_wm.virtual_screens {
        p := c.Find_Physical_Output(g_wm.m, profile.output)
        if p == nil || len(p.Screens) == 0 { continue }
        if !virtual_profile_fits(profile, p) {
            logger.Warn("virtual screen profile no longer fits output:", profile.output)
            continue
        }
        _ = c.Enable_Output_Split(
            g_wm.m, p.Screens[0], f64(profile.ratio_percent) / 100.0, profile.offset,
        )
    }
}

apply_virtual_profiles :: proc(next: ^[dynamic]Virtual_Screen_Profile) {
    if g_wm.m != nil {
        // A profile removed by reload returns only the topology that profile
        // managed to normal. Unrelated runtime-created splits are untouched.
        for old in g_wm.virtual_screens {
            if _, found := profile_for_output(next^[:], old.output); found { continue }
            p := c.Find_Physical_Output(g_wm.m, old.output)
            if p != nil && p.Split && len(p.Screens) > 0 {
                _ = c.Disable_Output_Split(g_wm.m, p.Screens[0])
            }
        }
    }
    release_virtual_screens(&g_wm.virtual_screens)
    g_wm.virtual_screens = next^
    next^ = {}
    apply_current_virtual_screens()
    randr_sync_virtual_monitors()
    // One invalidation is sufficient for snapshot-based consumers, but emit
    // every surviving logical name for event-oriented bars as well. At startup
    // there are no IPC peers yet, so this is naturally a no-op.
    for output in g_wm.m.Outputs {
        ipc_broadcast_output_event("geometry", output.Name)
    }
}

apply_workspace_layout_rules :: proc() {
    m := g_wm.m
    if m == nil || len(g_wm.workspace_layouts) == 0 { return }
    saved_active := m.Active
    saved_currents := make([]^c.Workspace, len(m.Outputs), context.temp_allocator)
    for o, i in m.Outputs { saved_currents[i] = o.Current }

    for o, output_index in m.Outputs {
        m.Active = output_index
        for rule in g_wm.workspace_layouts {
            ws := c.Ensure_WS_On_Output(o, rule.workspace)
            if ws == nil { continue }
            o.Current = ws
            m.Focused = ws.Focus
            _ = c.Set_Workspace_Layout(m, rule.layout)
        }
    }
    for o, i in m.Outputs { o.Current = saved_currents[i] }
    m.Active = saved_active
    active := c.Active_Output(m)
    m.Focused = nil
    if active != nil && active.Current != nil { m.Focused = active.Current.Focus }
}

apply_workspace_layout_config :: proc(next: ^[dynamic]Workspace_Layout_Rule) {
    delete(g_wm.workspace_layouts)
    g_wm.workspace_layouts = next^
    next^ = {}
    apply_workspace_layout_rules()
}

// cfg_apply swaps the live WM state to r. After this call every heap resource r
// owned has been moved into the WM or freed, so the caller must not destroy it
// again.
cfg_apply :: proc(r: ^Config_Result, label: string) {
    if g_wm.m != nil { g_wm.m.Cfg = r.cfg }
    g_wm.primary_mod = r.primary_mod
    release_config_sources(&g_active_config_sources)
    g_active_config_sources = r.source_paths
    r.source_paths = {}

    ui.Hide_Help(&g_wm.ui)
    reminder_dialog_end()
    release_bindings(&g_wm.bindings)
    g_wm.bindings = r.bindings
    r.bindings = {}

    release_rules(&g_wm.rules)
    g_wm.rules = r.rules
    r.rules = {}
    for cl in g_wm.m.Clients {
        if !cl.Dock { cl.Decorated = decoration_for_client(cl) }
    }
    ui.Sync_Decorations(&g_wm.ui, g_wm.m)
    audio_sync_config()

    release_bar_blocks(&g_wm.bar_blocks)
    g_wm.bar_blocks = r.bar_blocks
    r.bar_blocks = {}

    apply_virtual_profiles(&r.virtual_screens)
    apply_workspace_layout_config(&r.workspace_layouts)

    // Startup commands run once per command text, so a reload never relaunches
    // programs the running config already started.
    for s in r.startups {
        if !startup_ran(s) {
            process.Spawn(s)
            append(&g_wm.ran_startups, strings.clone(s))
        }
        delete(s)
    }
    delete(r.startups)
    r.startups = {}

    grab_all_keys()
    regrab_client_buttons()
    bar_sync_config()
    reflow()
    x11.xcb_flush(g_wm.conn)
    logger.Info("config applied:", label)
}

// ----------------------------------------------------------------------------
// Discovery + entry points
// ----------------------------------------------------------------------------

join_exists :: proc(base, tail: string) -> string {
    p := strings.concatenate({base, "/", tail})
    defer delete(p)
    if os.exists(p) {
        return strings.clone(p)
    }
    return ""
}

// cfg_discover_path resolves the config file: -c FILE wins, followed by
// $SKARWM_CONFIG, then skarwm.rc in the XDG, home, and system locations.
// The legacy config.rc name is a fallback at each location.
// Returns "" when no file exists.
cfg_discover_path :: proc() -> string {
    if g_cfg_flag != "" {
        if os.exists(g_cfg_flag) {
            return strings.clone(g_cfg_flag)
        }
        logger.Error("config file not found:", g_cfg_flag)
        return ""
    }
    eb: [1024]byte
    if configured := os.get_env_buf(eb[:], "SKARWM_CONFIG"); configured != "" {
        if os.exists(configured) {
            return strings.clone(configured)
        }
        logger.Error("SKARWM_CONFIG file not found:", configured)
        return ""
    }
    xb: [1024]byte
    if xdg := os.get_env_buf(xb[:], "XDG_CONFIG_HOME"); xdg != "" {
        if p := join_exists(xdg, "skarwm/skarwm.rc"); p != "" { return p }
        if p := join_exists(xdg, "skarwm/config.rc"); p != "" { return p }
    }
    hb: [1024]byte
    if home := os.get_env_buf(hb[:], "HOME"); home != "" {
        if p := join_exists(home, ".config/skarwm/skarwm.rc"); p != "" { return p }
        if p := join_exists(home, ".config/skarwm/config.rc"); p != "" { return p }
    }
    if os.exists("/etc/skarwm/skarwm.rc") {
        return strings.clone("/etc/skarwm/skarwm.rc")
    }
    if os.exists("/etc/skarwm/config.rc") {
        return strings.clone("/etc/skarwm/config.rc")
    }
    return ""
}

// add_bind_def appends a built-in Raw_Bind (mirroring the default key chords).
add_bind_def :: proc(sc: ^Load_Scratch, combo, action, arg_str: string, arg_num: int = 0) {
    rb := Raw_Bind {}
    rb.combo = strings.clone(combo)
    rb.action = strings.clone(action)
    if arg_str != "" {
        rb.argk = .Str
        rb.args = strings.clone(arg_str)
    } else if arg_num > 0 {
        rb.argk = .Num
        rb.argi = arg_num
    }
    append(&sc.binds, rb)
}

// cfg_apply_default installs the built-in defaults (same chords the WM had
// before any config existed). It runs when no rc file is present.
cfg_apply_default :: proc() {
    sc := scratch_new()
    defer scratch_destroy(sc)

    // A terminal spawn is only bound when we found one at startup; an empty
    // command would be a config error.
    if g_wm.terminal != "" {
        add_bind_def(sc, "Mod4+Return", "spawn", g_wm.terminal)
    }
    add_bind_def(sc, "Mod4+h", "focusleft", "")
    add_bind_def(sc, "Mod4+l", "focusright", "")
    add_bind_def(sc, "Mod4+j", "focusdown", "")
    add_bind_def(sc, "Mod4+k", "focusup", "")

    add_bind_def(sc, "Mod4+Shift+h", "moveleft", "")
    add_bind_def(sc, "Mod4+Shift+l", "moveright", "")
    add_bind_def(sc, "Mod4+Shift+j", "movedown", "")
    add_bind_def(sc, "Mod4+Shift+k", "moveup", "")

    add_bind_def(sc, "Mod4+Control+h", "resizeleft", "")
    add_bind_def(sc, "Mod4+Control+l", "resizeright", "")
    add_bind_def(sc, "Mod4+Control+j", "resizedown", "")
    add_bind_def(sc, "Mod4+Control+k", "resizeup", "")

    add_bind_def(sc, "Mod4+space", "togglefloating", "")
    add_bind_def(sc, "Mod4+Shift+space", "togglealwaysontop", "")
    add_bind_def(sc, "Mod4+f", "togglefullscreen", "")
    add_bind_def(sc, "Mod4+t", "toggle_tabbed", "")
    add_bind_def(sc, "Mod4+g", "layout_next", "")
    add_bind_def(sc, "Mod4+slash", "show_bindings", "")
    add_bind_def(sc, "Mod4+Control+Alt+h", "show_bindings", "")
    add_bind_def(sc, "Mod4+Control+Alt+t", "show_datetime", "")
    add_bind_def(sc, "Mod4+Control+Alt+b", "show_battery", "")
    add_bind_def(sc, "Mod4+Control+r", "reminder_new", "")
    add_bind_def(sc, "Mod4+Control+Alt+r", "reminder_show_all", "")
    add_bind_def(sc, "Mod4+Control+Shift+r", "reminder_clear_all", "")
    add_bind_def(sc, "Mod4+grave", "scratchpad_toggle", "", 1)
    add_bind_def(sc, "Mod4+Shift+grave", "scratchpad_toggle_float", "", 2)
    add_bind_def(sc, "Mod4+Alt+grave", "scratchpad_toggle_quake", "", 3)
    add_bind_def(sc, "Mod4+Control+Alt+grave", "scratchpad_toggle_sidebar", "", 4)
    add_bind_def(sc, "Mod4+Control+grave", "scratchpad_remove", "", 1)
    add_bind_def(sc, "Mod4+Shift+q", "close_window", "")
    add_bind_def(sc, "Mod4+Shift+r", "reload_config", "")

    add_bind_def(sc, "Mod4+n", "ws_next", "")
    add_bind_def(sc, "Mod4+p", "ws_prev", "")
    add_bind_def(sc, "Mod4+Control+n", "tag_next", "")
    add_bind_def(sc, "Mod4+Control+p", "tag_prev", "")
    add_bind_def(sc, "Mod4+comma", "focus_output_prev", "")
    add_bind_def(sc, "Mod4+period", "focus_output_next", "")
    add_bind_def(sc, "Mod4+Shift+comma", "move_to_output_prev", "")
    add_bind_def(sc, "Mod4+Shift+period", "move_to_output_next", "")
    for i in 0 ..< 9 {
        d := fmt.aprintf("%d", i + 1)
        combo := strings.concatenate({"Mod4+", d})
        mcombo := strings.concatenate({"Mod4+Shift+", d})
        add_bind_def(sc, combo, "ws_goto", "", i + 1)
        add_bind_def(sc, mcombo, "ws_tag", "", i + 1)
        delete(d)
        delete(combo)
        delete(mcombo)
    }

    errs := make([dynamic]string, 0, 4)
    defer free_errors(&errs)
    r := build_result(sc, &errs)
    if len(errs) > 0 {
        logger.Error("internal: built-in config failed:")
        for e in errs { logger.Error("  ", e) }
        destroy_result(&r)
        return
    }
    if g_active_config_path != "" {
        delete(g_active_config_path)
        g_active_config_path = ""
    }
    cfg_apply(&r, "built-in defaults")
}

// load_config_path attempts to apply the config file at `path`. On any error it
// logs, leaves the current configuration untouched, and reports failure.
load_config_path :: proc(path, verb: string) -> bool {
    r, errs, ok := cfg_file_result(path)
    if !ok {
        logger.Error("could not", verb, "config — keeping current settings:")
        for e in errs { logger.Error("  ", e) }
        free_errors(&errs)
        return false
    }
    free_errors(&errs)
    if topology_error := validate_virtual_profiles(r.virtual_screens[:]); topology_error != "" {
        logger.Error("could not", verb, "config — keeping current settings:")
        logger.Error("  ", topology_error)
        delete(topology_error)
        destroy_result(&r)
        return false
    }
    active_path, path_error := os.get_absolute_path(path, context.allocator)
    if path_error != nil { active_path = strings.clone(path) }
    if g_active_config_path != "" { delete(g_active_config_path) }
    g_active_config_path = active_path
    label := fmt.aprintf("%s from %s", verb, path)
    cfg_apply(&r, label)
    delete(label)
    return true
}

// cfg_initial_load runs once at startup, before window adoption.
cfg_initial_load :: proc() {
    path := cfg_discover_path()
    if path == "" {
        cfg_apply_default()
        return
    }
    defer delete(path)
    load_config_path(path, "load")
}

// cfg_reload is the `.Reload` action: re-run discovery so a config that
// appeared (or disappeared) since startup is honoured too.
cfg_reload :: proc() {
    path := cfg_discover_path()
    source_changed := cfg_watch_sources_changed(path)
    ok := true
    if path == "" {
        cfg_apply_default()
        cfg_watch_sync()
    } else {
        defer delete(path)
        ok = load_config_path(path, "reload")
        cfg_watch_sync()
    }
    if source_changed {
        notice_show("Configuration reloaded" if ok else "Configuration reload failed", false)
    }
}

// ----------------------------------------------------------------------------
// Automatic reload
// ----------------------------------------------------------------------------

// Editors commonly save by replacing config files, so watching open file
// descriptors is not sufficient. Poll the main file and every imported file by
// path instead; this catches both in-place writes and atomic rename-over saves.
// A short stability delay keeps us from parsing while an editor is still
// writing. Invalid files retain the previous live configuration.

CONFIG_WATCH_INTERVAL :: 250 * time.Millisecond
CONFIG_WATCH_SETTLE   :: 100 * time.Millisecond

Config_File_Snapshot :: struct {
    exists:      bool,
    readable:    bool,
    inode:       u128,
    device:      u64,
    size:        i64,
    mtime:       i64,
    content_hash: u64,
}

Config_Watched_File :: struct {
    path: string,
    observed: Config_File_Snapshot,
    loaded:   Config_File_Snapshot,
}

Config_Watch :: struct {
    files:      [dynamic]Config_Watched_File,
    next_check: time.Tick,
    reload_due: time.Tick,
    pending:    bool,
}

g_config_watch: Config_Watch

cfg_file_snapshot :: proc(path: string, include_contents := false) -> Config_File_Snapshot {
    if path == "" { return {} }
    info, err := os.stat(path, context.allocator)
    if err != nil { return {} }
    defer os.file_info_delete(info, context.allocator)

    snapshot := Config_File_Snapshot{
        exists = true,
        inode  = info.inode,
        device = info.device,
        size   = info.size,
        mtime  = time.to_unix_nanoseconds(info.modification_time),
    }
    if include_contents {
        data, read_error := os.read_entire_file_from_path(path, context.allocator)
        if read_error == nil {
            defer delete(data)
            snapshot.readable = true
            snapshot.content_hash = 0xcbf29ce484222325
            for byte in data {
                snapshot.content_hash ~= u64(byte)
                snapshot.content_hash *= 0x100000001b3
            }
        }
    }
    return snapshot
}

cfg_snapshots_equal :: proc(a, b: Config_File_Snapshot) -> bool {
    return a.exists == b.exists &&
           a.inode == b.inode && a.device == b.device &&
           a.size == b.size && a.mtime == b.mtime
}

cfg_snapshot_contents_equal :: proc(a, b: Config_File_Snapshot) -> bool {
    return a.exists == b.exists && a.readable == b.readable &&
           a.size == b.size && a.content_hash == b.content_hash
}

// Notices describe a real source change, not merely receipt of a reload
// command. This also keeps unrelated clients that accidentally request a
// reload from producing a false "Configuration reloaded" message.
cfg_watch_sources_changed :: proc(discovered_path: string) -> bool {
    if discovered_path == "" {
        if len(g_active_config_sources) == 0 { return false }
    } else if len(g_active_config_sources) == 0 ||
              discovered_path != g_active_config_sources[0] {
        return true
    }

    if len(g_config_watch.files) == 0 {
        return len(g_active_config_sources) > 0
    }
    for &file in g_config_watch.files {
        current := cfg_file_snapshot(file.path, true)
        if !cfg_snapshot_contents_equal(current, file.loaded) { return true }
    }
    return false
}

cfg_watch_clear_files :: proc() {
    for &file in g_config_watch.files {
        if file.path != "" { delete(file.path) }
    }
    delete(g_config_watch.files)
    g_config_watch.files = {}
}

// Sync after startup and explicit reloads. On a successful file-backed load,
// replace the watch set with the main file and all recursive imports. If the
// config disappeared, retain the previous set so its recreation is detected.
cfg_watch_sync :: proc() {
    if len(g_active_config_sources) > 0 {
        cfg_watch_clear_files()
        g_config_watch.files = make(
            [dynamic]Config_Watched_File, 0, len(g_active_config_sources),
        )
        for path in g_active_config_sources {
            snapshot := cfg_file_snapshot(path, true)
            append(&g_config_watch.files, Config_Watched_File{
                path = strings.clone(path),
                observed = snapshot,
                loaded = snapshot,
            })
        }
    }
    if len(g_config_watch.files) == 0 { return }
    for &file in g_config_watch.files {
        file.observed = cfg_file_snapshot(file.path, true)
        file.loaded = file.observed
    }
    g_config_watch.pending = false
    g_config_watch.next_check = time.tick_add(time.tick_now(), CONFIG_WATCH_INTERVAL)
}

cfg_watch_init :: proc() {
    cfg_watch_sync()
}

cfg_watch_shutdown :: proc() {
    cfg_watch_clear_files()
    release_config_sources(&g_active_config_sources)
    g_config_watch = {}
}

cfg_watch_poll_timeout_ms :: proc() -> i32 {
    if len(g_config_watch.files) == 0 { return -1 }
    deadline := g_config_watch.next_check
    if g_config_watch.pending && time.tick_diff(g_config_watch.reload_due, deadline) > 0 {
        deadline = g_config_watch.reload_due
    }
    remaining := time.tick_diff(time.tick_now(), deadline)
    if remaining <= 0 { return 0 }
    return i32((i64(remaining) + i64(time.Millisecond) - 1) / i64(time.Millisecond))
}

cfg_watch_run_due :: proc() {
    if len(g_config_watch.files) == 0 { return }
    now := time.tick_now()

    if time.tick_diff(g_config_watch.next_check, now) >= 0 {
        for &file in g_config_watch.files {
            current := cfg_file_snapshot(file.path)
            if !cfg_snapshots_equal(current, file.observed) {
                current = cfg_file_snapshot(file.path, true)
                file.observed = current
                g_config_watch.pending = true
                g_config_watch.reload_due = time.tick_add(now, CONFIG_WATCH_SETTLE)
            }
        }
        g_config_watch.next_check = time.tick_add(now, CONFIG_WATCH_INTERVAL)
    }

    if g_config_watch.pending && time.tick_diff(g_config_watch.reload_due, now) >= 0 {
        // Confirm that every source remained unchanged throughout the settle window.
        unstable := false
        for &file in g_config_watch.files {
            current := cfg_file_snapshot(file.path)
            if !cfg_snapshots_equal(current, file.observed) {
                current = cfg_file_snapshot(file.path, true)
                file.observed = current
                unstable = true
            }
        }
        if unstable {
            g_config_watch.reload_due = time.tick_add(now, CONFIG_WATCH_SETTLE)
            return
        }

        content_changed := false
        for &file in g_config_watch.files {
            if !cfg_snapshot_contents_equal(file.observed, file.loaded) {
                content_changed = true
                break
            }
        }
        g_config_watch.pending = false
        if content_changed {
            if ipc_has_ui_subscriber() {
                for &file in g_config_watch.files { file.loaded = file.observed }
            } else {
                cfg_reload()
            }
        } else {
            // Some editors replace a file even when its contents are unchanged.
            // Accept the new metadata without announcing a configuration reload.
            for &file in g_config_watch.files { file.loaded = file.observed }
        }
    }
}

// ----------------------------------------------------------------------------
// Rules (applied from manage() when a window is first managed)
// ----------------------------------------------------------------------------

// rule_matches: a rule matches when every non-empty matcher is a substring of
// the client's corresponding property.
rule_matches :: proc(r: Raw_Rule, cl: ^c.Client) -> bool {
    if r.class != "" && !strings.contains(cl.Class, r.class)          { return false }
    if r.instance != "" && !strings.contains(cl.Instance, r.instance) { return false }
    if r.title != "" && !strings.contains(cl.Title, r.title)          { return false }
    return true
}

decoration_for_client :: proc(cl: ^c.Client) -> bool {
    enabled := g_wm.m.Cfg.Decoration.Enabled
    for r in g_wm.rules {
        if !rule_matches(r, cl) { continue }
        if r.decorate_set { enabled = r.decorate }
        break // all rule effects consistently use the first matching rule
    }
    return enabled
}

// rule_for_client returns the first matching rule's effects. hit is false when
// no rule matches. A rule that names a workspace sends the window there (the
// workspace is created on demand if it does not exist yet).
rule_for_client :: proc(cl: ^c.Client) -> (tgt: ^c.Workspace, floating: bool, hit: bool) {
    for r in g_wm.rules {
        if !rule_matches(r, cl) { continue }
        if r.ws_set && r.ws >= 1 {
            tgt = c.Ensure_WS(g_wm.m, r.ws)
        }
        floating = r.floating_set && r.floating
        hit = r.ws_set || r.floating_set || r.decorate_set
        return tgt, floating, hit
    }
    return nil, false, false
}
