package config

import "core:fmt"
import "core:strings"

Assignment :: struct {
    section: string,
    key:     string,
    value:   string,
    line:    int,
    section_instance: int,
}

Document :: struct {
    source:      string,
    assignments: [dynamic]Assignment,
}

Diagnostic :: struct {
    line:    int,
    message: string,
}

Destroy_Document :: proc(doc: ^Document) {
    if doc.source != "" { delete(doc.source) }
    for &assignment in doc.assignments {
        delete(assignment.section)
        delete(assignment.key)
        delete(assignment.value)
    }
    delete(doc.assignments)
    doc^ = {}
}

Destroy_Diagnostics :: proc(diagnostics: ^[dynamic]Diagnostic) {
    for &diagnostic in diagnostics { delete(diagnostic.message) }
    delete(diagnostics^)
    diagnostics^ = {}
}

append_diagnostic :: proc(diagnostics: ^[dynamic]Diagnostic, line: int, message: string) {
    append(diagnostics, Diagnostic{line = line, message = strings.clone(message)})
}

name_byte_valid :: proc(value: byte) -> bool {
    return value >= 'a' && value <= 'z' ||
           value >= 'A' && value <= 'Z' ||
           value >= '0' && value <= '9' ||
           value == '_' || value == '-'
}

section_valid :: proc(section: string) -> bool {
    if section == "" || section[0] == '.' || section[len(section)-1] == '.' { return false }
    previous_dot := false
    for value in transmute([]u8)section {
        if value == '.' {
            if previous_dot { return false }
            previous_dot = true
        } else {
            if !name_byte_valid(value) { return false }
            previous_dot = false
        }
    }
    return true
}

bare_key_valid :: proc(key: string) -> bool {
    if key == "" { return false }
    for value in transmute([]u8)key {
        if !name_byte_valid(value) { return false }
    }
    return true
}

decode_quoted :: proc(value: string) -> (decoded: string, ok: bool) {
    if len(value) < 2 || value[0] != '"' || value[len(value)-1] != '"' {
        return "", false
    }
    builder := strings.builder_make_len_cap(0, len(value)-2)
    defer strings.builder_destroy(&builder)
    index := 1
    for index < len(value)-1 {
        current := value[index]
        if current == '"' { return "", false }
        if current == '\\' && index+1 < len(value)-1 {
            next := value[index+1]
            if next == '"' || next == '\\' {
                strings.write_byte(&builder, next)
                index += 2
                continue
            }
        }
        strings.write_byte(&builder, current)
        index += 1
    }
    return strings.clone(strings.to_string(builder)), true
}

decode_key :: proc(raw: string) -> (key: string, ok: bool) {
    value := strings.trim_space(raw)
    if value == "" { return "", false }
    if value[0] == '"' { return decode_quoted(value) }
    if !bare_key_valid(value) { return "", false }
    return strings.clone(value), true
}

decode_value :: proc(raw: string) -> (value: string, ok: bool) {
    trimmed := strings.trim_space(raw)
    if trimmed == "" { return "", false }
    if trimmed[0] == '"' { return decode_quoted(trimmed) }
    return strings.clone(trimmed), true
}

assignment_separator :: proc(line: string) -> int {
    quoted := false
    escaped := false
    for value, index in transmute([]u8)line {
        if escaped {
            escaped = false
        } else if quoted && value == '\\' {
            escaped = true
        } else if value == '"' {
            quoted = !quoted
        } else if value == '=' && !quoted {
            return index
        }
    }
    return -1
}

Parse :: proc(data: []byte, source: string) -> (
    document: Document,
    diagnostics: [dynamic]Diagnostic,
    ok: bool,
) {
    document.source = strings.clone(source)
    document.assignments = make([dynamic]Assignment, 0, 32)
    diagnostics = make([dynamic]Diagnostic, 0, 4)
    current_section := ""
    section_instance := 0
    section_assignment_start := 0
    lines := strings.split_lines(string(data))
    defer delete(lines)

    for raw_line, line_index in lines {
        line_number := line_index + 1
        line := strings.trim_space(raw_line)
        if line == "" || line[0] == '#' || line[0] == ';' { continue }

        if line[0] == '[' {
            if len(line) < 3 || line[len(line)-1] != ']' {
                append_diagnostic(&diagnostics, line_number, "malformed section declaration")
                continue
            }
            section := strings.trim_space(line[1:len(line)-1])
            if !section_valid(section) {
                append_diagnostic(&diagnostics, line_number, "invalid section name")
                continue
            }
            current_section = section
            section_instance += 1
            section_assignment_start = len(document.assignments)
            continue
        }

        if current_section == "" {
            append_diagnostic(&diagnostics, line_number, "assignment appears before any section")
            continue
        }
        separator := assignment_separator(line)
        if separator < 0 {
            append_diagnostic(&diagnostics, line_number, "expected key = value assignment")
            continue
        }
        key, key_ok := decode_key(line[:separator])
        if !key_ok || key == "" {
            append_diagnostic(&diagnostics, line_number, "invalid assignment key")
            continue
        }
        value, value_ok := decode_value(line[separator+1:])
        if !value_ok {
            delete(key)
            append_diagnostic(&diagnostics, line_number, "invalid or unterminated assignment value")
            continue
        }
        duplicate := false
        for index := section_assignment_start; index < len(document.assignments); index += 1 {
            previous := &document.assignments[index]
            if previous.section_instance == section_instance && previous.key == key {
                message := fmt.aprintf("duplicate assignment %q (first declared on line %d)", key, previous.line)
                append_diagnostic(&diagnostics, line_number, message)
                delete(message)
                duplicate = true
                break
            }
        }
        if duplicate { delete(key); delete(value); continue }
        append(&document.assignments, Assignment{
            section = strings.clone(current_section),
            key = key,
            value = value,
            line = line_number,
            section_instance = section_instance,
        })
    }
    return document, diagnostics, len(diagnostics) == 0
}

Format_Diagnostic :: proc(source: string, diagnostic: Diagnostic) -> string {
    return fmt.aprintf("%s:%d: %s", source, diagnostic.line, diagnostic.message)
}
