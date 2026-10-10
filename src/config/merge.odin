package config

import "core:strings"

Merged_Document :: struct {
    entries: [dynamic]Resolved_Assignment,
}

Destroy_Merged_Document :: proc(document: ^Merged_Document) {
    for &entry in document.entries {
        delete(entry.section)
        delete(entry.key)
        delete(entry.value)
        delete(entry.source)
    }
    delete(document.entries)
    document^ = {}
}

clone_resolved_assignment :: proc(assignment: Resolved_Assignment) -> Resolved_Assignment {
    return Resolved_Assignment{
        section = strings.clone(assignment.section),
        key = strings.clone(assignment.key),
        value = strings.clone(assignment.value),
        source = strings.clone(assignment.source),
        line = assignment.line,
        section_instance = assignment.section_instance,
    }
}

destroy_resolved_assignment :: proc(assignment: ^Resolved_Assignment) {
    delete(assignment.section)
    delete(assignment.key)
    delete(assignment.value)
    delete(assignment.source)
    assignment^ = {}
}

binding_section :: proc(section: string) -> bool {
    return section == "bind" || section == "call" || section == "workspace.bindings"
}

modifier_index :: proc(token: string) -> (int, bool) {
    switch token {
    case "mod":                         return 0, true
    case "shift", "Shift":             return 1, true
    case "control", "Control", "Ctrl": return 2, true
    case "mod1", "Mod1", "alt", "Alt": return 3, true
    case "mod2", "Mod2":               return 4, true
    case "mod3", "Mod3":               return 5, true
    case "mod4", "Mod4":               return 6, true
    case "mod5", "Mod5":               return 7, true
    case "super", "Super":             return 8, true
    case "hyper", "Hyper":             return 9, true
    }
    return 0, false
}

Normalize_Binding_Key :: proc(combo: string) -> string {
    parts := strings.split(combo, "+")
    defer delete(parts)
    modifiers: [10]bool
    keys := make([dynamic]string, 0, 2)
    defer delete(keys)
    for part in parts {
        token := strings.trim_space(part)
        if token == "" { continue }
        if index, modifier := modifier_index(token); modifier {
            modifiers[index] = true
        } else {
            append(&keys, token)
        }
    }
    has_modifier := false
    for enabled in modifiers {
        if enabled { has_modifier = true; break }
    }
    if !has_modifier && len(keys) > 0 { modifiers[0] = true }
    names := [10]string{"mod", "shift", "control", "mod1", "mod2", "mod3", "mod4", "mod5", "super", "hyper"}
    builder := strings.builder_make()
    defer strings.builder_destroy(&builder)
    first := true
    for enabled, index in modifiers {
        if !enabled { continue }
        if !first { strings.write_byte(&builder, '+') }
        strings.write_string(&builder, names[index])
        first = false
    }
    for key in keys {
        if !first { strings.write_byte(&builder, '+') }
        strings.write_string(&builder, key)
        first = false
    }
    return strings.clone(strings.to_string(builder))
}

same_merge_identity :: proc(existing: Resolved_Assignment, incoming: Resolved_Assignment) -> bool {
    if binding_section(existing.section) && binding_section(incoming.section) {
        existing_key := Normalize_Binding_Key(existing.key)
        incoming_key := Normalize_Binding_Key(incoming.key)
        defer delete(existing_key)
        defer delete(incoming_key)
        return existing_key == incoming_key
    }
    return existing.section == incoming.section && existing.key == incoming.key
}

Merge :: proc(document: ^Resolved_Document) -> Merged_Document {
    merged: Merged_Document
    merged.entries = make([dynamic]Resolved_Assignment, 0, len(document.assignments))
    for assignment in document.assignments {
        replaced := false
        for &entry in merged.entries {
            if !same_merge_identity(entry, assignment) { continue }
            replacement := clone_resolved_assignment(assignment)
            destroy_resolved_assignment(&entry)
            entry = replacement
            replaced = true
            break
        }
        if !replaced { append(&merged.entries, clone_resolved_assignment(assignment)) }
    }
    return merged
}

Find :: proc(document: ^Merged_Document, section, key: string) -> (^Resolved_Assignment, bool) {
    for &entry in document.entries {
        if entry.section == section && entry.key == key { return &entry, true }
    }
    return nil, false
}
