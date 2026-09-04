package main

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
//     border_width, norm_outer_border (unfocused colour), sel_outer_border
//     (focused colour), focus_follows_mouse. Legacy decorative/titlebar keys
//     are accepted and ignored; an unknown setting logs one warning.
//   - directives:
//       bind       : <combo> : "<command>"
//       call       : <combo> : <action>
//       workspace  : <combo> : view <N>      (switch to N)
//       workspace  : <combo> : tag <N>       (move focused window to N)
//       rule       : <class|instance|title> : <pattern> : <effects…>
//       autostart  : "<command>"
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
import "core:strconv"
import "core:strings"

import c "core"

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
}

// Raw_Rule is a `rule :` line. Empty match field == wildcard. Only fields whose
// *_set flag is true impose anything.
Raw_Rule :: struct {
    class, instance, title: string,
    ws:                 int,
    floating:           bool,
    ws_set:             bool,
    floating_set:       bool,
}

// Config_Result is the fully-resolved product of a config load, ready to apply.
Config_Result :: struct {
    cfg:       c.Config,
    primary_mod: u16,
    bindings:  [dynamic]Binding,
    rules:     [dynamic]Raw_Rule,
    startups:  [dynamic]string,
}

// Load_Scratch accumulates raw settings + directives while the file is scanned.
// It exists so the `mod` from mod_key can be applied to every combo regardless
// of the order the lines appear in the file.
Load_Scratch :: struct {
    // mod token
    mod_key:     string,
    mod_key_set: bool,
    // numeric / boolean / colour config overrides (defaults applied at build)
    gap, outer_gap, inner_gap, border: i32,
    ffm:  bool,
    focused, unfocused: u32,
    gap_set, outer_set, inner_set, border_set, ffm_set: bool,
    focused_set, unfocused_set: bool,
    // directives
    binds:    [dynamic]Raw_Bind,
    rules:    [dynamic]Raw_Rule,
    startups: [dynamic]string,
    warned:   [dynamic]string, // unknown settings already warned about
}

g_cfg_flag: string // -c FILE (owned; freed in cleanup_all)

// ----------------------------------------------------------------------------
// Scratch / list helpers
// ----------------------------------------------------------------------------

scratch_new :: proc() -> ^Load_Scratch {
    sc := new(Load_Scratch)
    sc.binds = make([dynamic]Raw_Bind, 0, 48)
    sc.rules = make([dynamic]Raw_Rule, 0, 8)
    sc.startups = make([dynamic]string, 0, 8)
    sc.warned = make([dynamic]string, 0, 8)
    return sc
}

scratch_destroy :: proc(sc: ^Load_Scratch) {
    if sc == nil { return }
    if sc.mod_key != "" { delete(sc.mod_key) }
    for &b in sc.binds {
        if b.combo != "" { delete(b.combo) }
        if b.action != "" { delete(b.action) }
        if b.args != "" { delete(b.args) }
    }
    delete(sc.binds)
    release_rules(&sc.rules)
    for s in sc.startups { if s != "" { delete(s) } }
    delete(sc.startups)
    for w in sc.warned { if w != "" { delete(w) } }
    delete(sc.warned)
    free(sc)
}

// release_bindings frees every Binding.cmd string and the dynamic array itself,
// leaving *b zeroed. Safe to call on a moved-out (zero) dynamic array.
release_bindings :: proc(b: ^[dynamic]Binding) {
    for &x in b {
        if x.cmd != "" { delete(x.cmd) }
        if x.combo != "" { delete(x.combo) }
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

free_errors :: proc(errs: ^[dynamic]string) {
    for e in errs { if e != "" { delete(e) } }
    delete(errs^)
    errs^ = {}
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
            m := canonical_mods_for_name(mod_key, &g_wm.kb, &g_wm.mm)
            if m == 0 { m = MOD_MASK_MOD4 }
            mods |= m
            continue
        }
        if m := canonical_mods_for_name(t, &g_wm.kb, &g_wm.mm); m != 0 {
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
        m := canonical_mods_for_name(mod_key, &g_wm.kb, &g_wm.mm)
        if m == 0 { m = MOD_MASK_MOD4 }
        mods = m
    }
    ks = keysym_from_name(ks_name)
    if ks == 0 {
        return 0, 0, false, fmt.aprintf("combo %q: unknown keysym %q", combo, ks_name)
    }
    return mods, ks, true, ""
}

// resolve_bind turns a Raw_Bind into a concrete Binding, or returns an error
// string. It allocates nothing that outlives the returned Binding.cmd.
resolve_bind :: proc(rb: Raw_Bind, mod_key: string) -> (out: Binding, err: string) {
    mods, ks, ok, e := parse_combo(rb.combo, mod_key)
    if !ok { return {}, e }
    base := Binding { mods = mods, keysym = ks }

    switch rb.action {
    case "spawn":
        if rb.args == "" {
            return {}, fmt.aprintf("bind(%q): empty command", rb.combo)
        }
        base.action = .Spawn
        base.cmd = strings.clone(rb.args)
        return base, ""

    case "focusleft":  base.action = .Focus_Left;  return base, ""
    case "focusright": base.action = .Focus_Right; return base, ""
    case "focusup":    base.action = .Focus_Up;    return base, ""
    case "focusdown":  base.action = .Focus_Down;  return base, ""
    case "moveleft":   base.action = .Move_Left;   return base, ""
    case "moveright":  base.action = .Move_Right;  return base, ""
    case "moveup":     base.action = .Move_Up;     return base, ""
    case "movedown":   base.action = .Move_Down;   return base, ""

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

    case "togglefloating":   base.action = .Toggle_Floating;   return base, ""
    case "togglefullscreen",
         "fullscreen":       base.action = .Toggle_Fullscreen; return base, ""
    case "layout_tabbed",
         "tabbed":           base.action = .Layout_Tabbed;     return base, ""
    case "layout_stacked",
         "stacked":          base.action = .Layout_Stacked;    return base, ""
    case "toggle_tabbed":    base.action = .Layout_Toggle;     return base, ""
    case "show_bindings",
         "bindings_help":    base.action = .Show_Bindings;     return base, ""
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
    if sc.ffm_set     { r.cfg.FocusFollowsMouse = sc.ffm }
    if sc.focused_set { r.cfg.FocusedBorder = sc.focused }
    if sc.unfocused_set { r.cfg.UnfocusedBorder = sc.unfocused }
    c.Apply_Gap_Alias(&r.cfg)

    mod_key := "Mod4"
    if sc.mod_key_set && sc.mod_key != "" { mod_key = sc.mod_key }
    r.primary_mod = canonical_mods_for_name(mod_key, &g_wm.kb, &g_wm.mm)

    r.bindings = make([dynamic]Binding, 0, 48)
    for rb in sc.binds {
        if unimplemented_action(rb.action) {
            log_warn("ignoring unsupported action:", rb.action,
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
    return r
}

destroy_result :: proc(r: ^Config_Result) {
    release_bindings(&r.bindings)
    release_rules(&r.rules)
    for s in r.startups { if s != "" { delete(s) } }
    delete(r.startups)
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
    log_warn("unknown setting ignored:", key)
}

// parse_setting handles a `key : value` line. Hard value errors are appended to
// errs and flag failure via the return value.
parse_setting :: proc(sc: ^Load_Scratch, key, value: string, errs: ^[dynamic]string) -> bool {
    switch key {
    case "mod_key", "modkey":
        v := strings.trim_space(value)
        if v == "" || canonical_mods_for_name(v, &g_wm.kb, &g_wm.mm) == 0 {
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
        if !ok { append(errs, fmt.aprintf("border_width: bad number %q", value)); return false }
        sc.border = n; sc.border_set = true
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

    case "focus_follows_mouse":
        v, ok := parse_bool_value(value)
        if !ok { append(errs, fmt.aprintf("focus_follows_mouse: expected true/false, got %q", value)); return false }
        sc.ffm = v; sc.ffm_set = true
        return true

    case:
        if ignored_setting(key) { return true }
        warn_once(sc, key)
        return true
    }
}

// parse_directive handles bind/call/workspace/rule/autostart/mousebind lines.
parse_directive :: proc(sc: ^Load_Scratch, key, rest: string, errs: ^[dynamic]string) -> bool {
    switch key {
    case "autostart":
        cmd := quoted_trim(rest)
        if cmd == "" {
            append(errs, "autostart: empty command")
            return false
        }
        append(&sc.startups, strings.clone(cmd))
        return true

    case "mousebind":
        log_warn("ignoring mousebind (no mouse-action system yet):", rest)
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
            if strings.contains(act, " ") {
                append(errs, fmt.aprintf("call(%q): action must be a single token, got %q", combo, tail))
                free_bind(&rb)
                return false
            }
            rb.action = strings.clone(act)
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
            case:
                append(errs, fmt.aprintf("rule %q: unknown effect %q (want workspace <N> or floating)", pattern, toks[i]))
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
    rb^ = {}
}

release_rule :: proc(rr: ^Raw_Rule) {
    if rr.class != "" { delete(rr.class) }
    if rr.instance != "" { delete(rr.instance) }
    if rr.title != "" { delete(rr.title) }
    rr^ = {}
}

// scan_rc parses `data` into the scratch. Returns false when any hard error was
// recorded (errs then carries the messages; nothing should be applied).
scan_rc :: proc(sc: ^Load_Scratch, data: []byte, errs: ^[dynamic]string) -> bool {
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

        switch key {
        case "bind", "call", "workspace", "rule", "autostart", "mousebind":
            if !parse_directive(sc, key, rest, errs) { ok = false }
        case:
            if !parse_setting(sc, key, rest, errs) { ok = false }
        }
    }
    return ok
}

// cfg_file_result loads and validates an rc config file. `ok` is true only when
// every directive resolved; r is then valid. On failure r is undefined (caller
// must not touch it) and errs carries the diagnostic messages.
cfg_file_result :: proc(path: string) -> (r: Config_Result, errs: [dynamic]string, ok: bool) {
    errs = make([dynamic]string, 0, 4)
    data, ferr := os.read_entire_file_from_path(path, context.allocator)
    if ferr != nil {
        append(&errs, strings.concatenate({"cannot read config file: ", path}))
        return {}, errs, false
    }
    defer delete(data)

    sc := scratch_new()
    defer scratch_destroy(sc)

    if !scan_rc(sc, data, &errs) {
        return {}, errs, false
    }

    r = build_result(sc, &errs)
    if len(errs) > 0 {
        destroy_result(&r)
        return {}, errs, false
    }
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

// cfg_apply swaps the live WM state to r. After this call every heap resource r
// owned has been moved into the WM or freed, so the caller must not destroy it
// again.
cfg_apply :: proc(r: ^Config_Result, label: string) {
    if g_wm.m != nil { g_wm.m.Cfg = r.cfg }
    g_wm.primary_mod = r.primary_mod

    help_hide()
    release_bindings(&g_wm.bindings)
    g_wm.bindings = r.bindings
    r.bindings = {}

    release_rules(&g_wm.rules)
    g_wm.rules = r.rules
    r.rules = {}

    // Startup commands run once per command text, so a reload never relaunches
    // programs the running config already started.
    for s in r.startups {
        if !startup_ran(s) {
            spawn_sh(s)
            append(&g_wm.ran_startups, strings.clone(s))
        }
        delete(s)
    }
    delete(r.startups)
    r.startups = {}

    grab_all_keys()
    regrab_client_buttons()
    reflow()
    xcb_flush(g_wm.conn)
    log_info("config applied:", label)
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

// cfg_discover_path resolves the config file: -c FILE wins, then
// $XDG_CONFIG_HOME/skarwm/config.rc, then ~/.config/skarwm/config.rc. Returns ""
// when no file exists (built-in defaults are used).
cfg_discover_path :: proc() -> string {
    if g_cfg_flag != "" {
        if os.exists(g_cfg_flag) {
            return strings.clone(g_cfg_flag)
        }
        log_error("config file not found:", g_cfg_flag)
        return ""
    }
    xb: [1024]byte
    if xdg := os.get_env_buf(xb[:], "XDG_CONFIG_HOME"); xdg != "" {
        if p := join_exists(xdg, "skarwm/config.rc"); p != "" { return p }
    }
    hb: [1024]byte
    if home := os.get_env_buf(hb[:], "HOME"); home != "" {
        if p := join_exists(home, ".config/skarwm/config.rc"); p != "" { return p }
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

    add_bind_def(sc, "Mod4+space", "togglefloating", "")
    add_bind_def(sc, "Mod4+f", "togglefullscreen", "")
    add_bind_def(sc, "Mod4+t", "toggle_tabbed", "")
    add_bind_def(sc, "Mod4+slash", "show_bindings", "")
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
        log_error("internal: built-in config failed:")
        for e in errs { log_error("  ", e) }
        destroy_result(&r)
        return
    }
    cfg_apply(&r, "built-in defaults")
}

// load_config_path attempts to apply the config file at `path`. On any error it
// logs and leaves the current configuration untouched.
load_config_path :: proc(path, verb: string) {
    r, errs, ok := cfg_file_result(path)
    if !ok {
        log_error("could not", verb, "config — keeping current settings:")
        for e in errs { log_error("  ", e) }
        free_errors(&errs)
        return
    }
    free_errors(&errs)
    label := fmt.aprintf("%s from %s", verb, path)
    cfg_apply(&r, label)
    delete(label)
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
    if path == "" {
        cfg_apply_default()
        return
    }
    defer delete(path)
    load_config_path(path, "reload")
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
        hit = r.ws_set || r.floating_set
        return tgt, floating, hit
    }
    return nil, false, false
}
