package wm

import conf "../config"
import c "../core"
import "core:fmt"
import "core:strconv"
import "core:strings"

conf_error :: proc(errs: ^[dynamic]string, entry: ^conf.Resolved_Assignment, message: string) {
    append(errs, fmt.aprintf("%s:%d: [%s] %s: %s",
        entry.source, entry.line, entry.section, entry.key, message))
}

conf_parse_setting :: proc(sc: ^Load_Scratch, entry: ^conf.Resolved_Assignment, legacy_key: string, errs: ^[dynamic]string) -> bool {
    local := make([dynamic]string, 0, 1)
    valid := parse_setting(sc, legacy_key, entry.value, &local)
    for message in local { conf_error(errs, entry, message) }
    free_errors(&local)
    return valid
}

conf_setting_key :: proc(section, key: string) -> string {
    switch section {
    case "general": if key == "mod_key" { return "mod_key" }
    case "window":
        switch key {
        case "gap", "outer_gap", "inner_gap", "border_width", "corner_radius", "focus_follows_mouse": return key
        }
    case "window.border":
        if key == "normal" { return "norm_outer_border" }
        if key == "selected" { return "sel_outer_border" }
    case "window.decoration":
        switch key {
        case "enabled": return "decorations_enabled"
        case "titlebar_height": return "decoration_titlebar_height"
        case "border_width": return "decoration_border_width"
        case "resize_hit_width": return "decoration_resize_hit_width"
        case "show_title": return "decoration_show_title"
        case "color_source": return "decoration_color_source"
        case "accent", "active_background", "inactive_background", "active_foreground",
             "inactive_foreground", "active_border", "inactive_border":
            return fmt.tprintf("decoration_%s", key)
        }
    case "scroll": if key == "preview_hover_delay_ms" { return key }
    case "animation":
        switch key {
        case "enabled": return "animations"
        case "duration_ms": return "animation_duration_ms"
        case "fps": return "animation_fps"
        case "easing": return "animation_easing"
        }
    case "bar":
        switch key {
        case "enabled": return "bar_enabled"
        case "position": return "bar_position"
        case "height": return "bar_height"
        case "font": return "bar_font"
        case "font_size": return "bar_font_size"
        case "font_weight": return "bar_font_weight"
        case "foreground": return "bar_foreground"
        case "background": return "bar_background"
        case "tag_count": return "bar_tag_count"
        }
    case "bar.tag":
        if key == "foreground" { return "bar_tag_foreground" }
        if key == "background" { return "bar_tag_background" }
    case "bar.block":
        if key == "foreground" { return "bar_block_foreground" }
        if key == "background" { return "bar_block_background" }
    }
    return ""
}

conf_find :: proc(document: ^conf.Merged_Document, section, key: string) -> (^conf.Resolved_Assignment, bool) {
    return conf.Find(document, section, key)
}

conf_seen :: proc(sections: []string, section: string) -> bool {
    for item in sections { if item == section { return true } }
    return false
}

conf_named_section :: proc(section: string) -> bool {
    return strings.has_prefix(section, "rule.") ||
           strings.has_prefix(section, "bar.blocks.") ||
           strings.has_prefix(section, "virtual_screen.") ||
           strings.has_prefix(section, "workspace.") && section != "workspace.bindings"
}

conf_validate_repeated_named_sections :: proc(document: ^conf.Resolved_Document, errs: ^[dynamic]string) -> bool {
    valid := true
    for &entry, index in document.assignments {
        if !conf_named_section(entry.section) { continue }
        first_in_instance := true
        repeated := false
        for previous_index := 0; previous_index < index; previous_index += 1 {
            previous := &document.assignments[previous_index]
            if previous.source != entry.source || previous.section != entry.section { continue }
            if previous.section_instance == entry.section_instance { first_in_instance = false; break }
            repeated = true
        }
        if first_in_instance && repeated {
            conf_error(errs, &entry, "named section is repeated in the same file")
            valid = false
        }
    }
    return valid
}

conf_validate_binding_duplicates :: proc(document: ^conf.Resolved_Document, errs: ^[dynamic]string) -> bool {
    valid := true
    for &entry, index in document.assignments {
        binding := entry.section == "bind" || entry.section == "call" || entry.section == "workspace.bindings"
        if !binding { continue }
        normalized := conf.Normalize_Binding_Key(entry.key)
        defer delete(normalized)
        for previous_index := 0; previous_index < index; previous_index += 1 {
            previous := &document.assignments[previous_index]
            if previous.source != entry.source || previous.section_instance != entry.section_instance { continue }
            previous_binding := previous.section == "bind" || previous.section == "call" || previous.section == "workspace.bindings"
            if !previous_binding { continue }
            previous_normalized := conf.Normalize_Binding_Key(previous.key)
            duplicate := previous_normalized == normalized
            delete(previous_normalized)
            if duplicate {
                conf_error(errs, &entry, "duplicate normalized binding in one section declaration")
                valid = false
                break
            }
        }
    }
    return valid
}

conf_parse_binding :: proc(sc: ^Load_Scratch, entry: ^conf.Resolved_Assignment, errs: ^[dynamic]string) -> bool {
    directive := "bind"
    if entry.section == "call" { directive = "call" }
    if entry.section == "workspace.bindings" { directive = "workspace" }
    rest := fmt.aprintf("%s : %s", entry.key, entry.value)
    defer delete(rest)
    local := make([dynamic]string, 0, 1)
    valid := parse_directive(sc, directive, rest, &local)
    for message in local { conf_error(errs, entry, message) }
    free_errors(&local)
    return valid
}

conf_parse_rule :: proc(sc: ^Load_Scratch, document: ^conf.Merged_Document, section: string, first: ^conf.Resolved_Assignment, errs: ^[dynamic]string) -> bool {
    rule: Raw_Rule
    valid := true
    for &entry in document.entries {
        if entry.section != section { continue }
        switch entry.key {
        case "class": rule.class = strings.clone(entry.value)
        case "instance": rule.instance = strings.clone(entry.value)
        case "title": rule.title = strings.clone(entry.value)
        case "workspace":
            value, ok := strconv.parse_i64(entry.value, 10)
            if !ok || value < 1 || value > c.IPC_MAX_WORKSPACE_ID {
                conf_error(errs, &entry, "expected a valid workspace id"); valid = false
            } else { rule.ws = int(value); rule.ws_set = true }
        case "floating", "decorate":
            value, ok := parse_bool_value(entry.value)
            if !ok { conf_error(errs, &entry, "expected true or false"); valid = false }
            else if entry.key == "floating" { rule.floating = value; rule.floating_set = true }
            else { rule.decorate = value; rule.decorate_set = true }
        case: conf_error(errs, &entry, "unknown rule property"); valid = false
        }
    }
    if rule.class == "" && rule.instance == "" && rule.title == "" {
        conf_error(errs, first, "rule requires class, instance, or title"); valid = false
    }
    if !rule.ws_set && !rule.floating_set && !rule.decorate_set {
        conf_error(errs, first, "rule requires at least one effect"); valid = false
    }
    if valid { append(&sc.rules, rule) } else { release_rule(&rule) }
    return valid
}

conf_parse_workspace :: proc(sc: ^Load_Scratch, document: ^conf.Merged_Document, section: string, first: ^conf.Resolved_Assignment, errs: ^[dynamic]string) -> bool {
    id_text := section[len("workspace."):]
    id, id_ok := strconv.parse_i64(id_text, 10)
    if !id_ok || id < 1 || id > 64 { conf_error(errs, first, "invalid workspace section id"); return false }
    layout, has_layout := conf_find(document, section, "layout")
    icon, has_icon := conf_find(document, section, "icon")
    name, has_name := conf_find(document, section, "name")
    valid := true
    for &entry in document.entries {
        if entry.section == section && entry.key != "layout" && entry.key != "icon" && entry.key != "name" {
            conf_error(errs, &entry, "unknown workspace property"); valid = false
        }
    }
    if !has_layout { conf_error(errs, first, "workspace requires layout"); valid = false }
    if has_name && !has_icon { conf_error(errs, name, "name requires an icon"); valid = false }
    if !valid { return false }
    if has_icon {
        declaration := fmt.aprintf("%d : %s : %s : %s", id, layout.value, icon.value, name.value if has_name else "")
        defer delete(declaration)
        return parse_workspace_declaration(sc, declaration, errs)
    }
    declaration := fmt.aprintf("%d : %s", id, layout.value)
    defer delete(declaration)
    return parse_workspace_layout(sc, declaration, errs)
}

conf_parse_virtual_screen :: proc(sc: ^Load_Scratch, document: ^conf.Merged_Document, section: string, first: ^conf.Resolved_Assignment, errs: ^[dynamic]string) -> bool {
    output := section[len("virtual_screen."):]
    mode, has_mode := conf_find(document, section, "mode")
    ratio, has_ratio := conf_find(document, section, "ratio")
    offset, has_offset := conf_find(document, section, "offset")
    valid := true
    for &entry in document.entries {
        if entry.section == section && entry.key != "mode" && entry.key != "ratio" && entry.key != "offset" {
            conf_error(errs, &entry, "unknown virtual-screen property"); valid = false
        }
    }
    if !has_mode || !has_ratio { conf_error(errs, first, "virtual screen requires mode and ratio"); return false }
    if !valid { return false }
    declaration := fmt.aprintf("%s : %s : %s", output, mode.value, ratio.value)
    if has_offset {
        with_offset := fmt.aprintf("%s : %s", declaration, offset.value)
        delete(declaration); declaration = with_offset
    }
    defer delete(declaration)
    return parse_virtual_screen(sc, declaration, errs)
}

conf_parse_bar_block :: proc(sc: ^Load_Scratch, document: ^conf.Merged_Document, section: string, first: ^conf.Resolved_Assignment, errs: ^[dynamic]string) -> bool {
    kind_entry, has_kind := conf_find(document, section, "type")
    position_entry, has_position := conf_find(document, section, "position")
    if !has_kind || !has_position { conf_error(errs, first, "bar block requires type and position"); return false }
    alignment, alignment_ok := parse_bar_alignment(position_entry.value)
    if !alignment_ok { conf_error(errs, position_entry, "expected left, center, or right"); return false }
    block := Raw_Bar_Block{alignment = alignment}
    switch kind_entry.value {
    case "workspaces": block.kind = .Workspaces
    case "layout": block.kind = .Layout
    case "title": block.kind = .Title
    case "systray": block.kind = .Systray
    case "script": block.kind = .Script
    case "button": block.kind = .Button
    case "audio": block.kind = .Audio
    case "bluetooth": block.kind = .Bluetooth
    case "network": block.kind = .Network
    case: conf_error(errs, kind_entry, "unknown bar block type"); return false
    }
    valid := true
    for &entry in document.entries {
        if entry.section != section || entry.key == "type" || entry.key == "position" { continue }
        switch entry.key {
        case "icon", "label":
            if block.name != "" { delete(block.name) }
            block.name = strings.clone(entry.value)
        case "command":
            if block.kind == .Audio || block.kind == .Bluetooth || block.kind == .Network {
                block.click_command = strings.clone(entry.value)
            } else { block.command = strings.clone(entry.value) }
        case "interval", "timeout":
            value, ok := strconv.parse_i64(entry.value, 10)
            limit := i64(86400) if entry.key == "interval" else i64(60)
            if !ok || value < 1 || value > limit { conf_error(errs, &entry, "invalid duration in seconds"); valid = false }
            else if entry.key == "interval" { block.interval_ms = i32(value * 1000) }
            else { block.timeout_ms = i32(value * 1000) }
        case "foreground", "background":
            colour, ok := parse_color(entry.value)
            if !ok { conf_error(errs, &entry, "expected #RRGGBB"); valid = false }
            else if entry.key == "foreground" { block.foreground = colour; block.foreground_set = true }
            else { block.background = colour; block.background_set = true }
        case: conf_error(errs, &entry, "unknown bar-block property"); valid = false
        }
    }
    if block.kind == .Script && (block.command == "" || block.interval_ms == 0 || block.timeout_ms == 0) {
        conf_error(errs, first, "script block requires command, interval, and timeout"); valid = false
    }
    if block.kind == .Button && (block.name == "" || block.command == "") {
        conf_error(errs, first, "button block requires label and command"); valid = false
    }
    if (block.kind == .Audio || block.kind == .Bluetooth || block.kind == .Network) && block.name == "" {
        conf_error(errs, first, "status block requires an icon"); valid = false
    }
    if valid { append(&sc.bar_blocks, block); sc.bar_blocks_set = true } else {
        if block.name != "" { delete(block.name) }; if block.command != "" { delete(block.command) }; if block.click_command != "" { delete(block.click_command) }
    }
    return valid
}

scan_conf :: proc(sc: ^Load_Scratch, document: ^conf.Merged_Document, errs: ^[dynamic]string) -> bool {
    valid := true
    processed := make([dynamic]string, 0, 16)
    defer { for section in processed { delete(section) }; delete(processed) }
    for &entry in document.entries {
        if legacy_key := conf_setting_key(entry.section, entry.key); legacy_key != "" {
            if !conf_parse_setting(sc, &entry, legacy_key, errs) { valid = false }
            continue
        }
        if binding_section := entry.section == "bind" || entry.section == "call" || entry.section == "workspace.bindings"; binding_section {
            if !conf_parse_binding(sc, &entry, errs) { valid = false }
            continue
        }
        if entry.section == "autostart" {
            if entry.value == "" { conf_error(errs, &entry, "empty command"); valid = false }
            else { append(&sc.startups, strings.clone(entry.value)) }
            continue
        }
        named := strings.has_prefix(entry.section, "rule.") || strings.has_prefix(entry.section, "workspace.") ||
                 strings.has_prefix(entry.section, "virtual_screen.") || strings.has_prefix(entry.section, "bar.blocks.")
        if named && !conf_seen(processed[:], entry.section) {
            append(&processed, strings.clone(entry.section))
            object_ok := false
            if strings.has_prefix(entry.section, "rule.") { object_ok = conf_parse_rule(sc, document, entry.section, &entry, errs) }
            else if strings.has_prefix(entry.section, "workspace.") { object_ok = conf_parse_workspace(sc, document, entry.section, &entry, errs) }
            else if strings.has_prefix(entry.section, "virtual_screen.") { object_ok = conf_parse_virtual_screen(sc, document, entry.section, &entry, errs) }
            else { object_ok = conf_parse_bar_block(sc, document, entry.section, &entry, errs) }
            if !object_ok { valid = false }
            continue
        }
        if named { continue }
        conf_error(errs, &entry, "unknown section or property")
        valid = false
    }
    return valid
}

conf_file_result :: proc(path: string) -> (r: Config_Result, errs: [dynamic]string, ok: bool) {
    errs = make([dynamic]string, 0, 4)
    resolved, resolve_diagnostics, resolved_ok := conf.Resolve(path)
    defer conf.Destroy_Resolved_Document(&resolved)
    defer conf.Destroy_Resolve_Diagnostics(&resolve_diagnostics)
    if !resolved_ok {
        for diagnostic in resolve_diagnostics {
            message := conf.Format_Resolve_Diagnostic(diagnostic)
            append(&errs, message)
        }
        return {}, errs, false
    }
    if !conf_validate_repeated_named_sections(&resolved, &errs) ||
       !conf_validate_binding_duplicates(&resolved, &errs) {
        return {}, errs, false
    }
    merged := conf.Merge(&resolved)
    defer conf.Destroy_Merged_Document(&merged)
    sc := scratch_new()
    defer scratch_destroy(sc)
    if !scan_conf(sc, &merged, &errs) { return {}, errs, false }
    r = build_result(sc, &errs)
    if len(errs) > 0 { destroy_result(&r); return {}, errs, false }
    r.config_files = make([dynamic]string, 0, len(resolved.dependencies))
    for dependency in resolved.dependencies {
        append(&r.config_files, strings.clone(dependency))
    }
    return r, errs, true
}
