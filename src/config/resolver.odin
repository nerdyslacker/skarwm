package config

import "core:fmt"
import "core:os"
import "core:strings"

Resolved_Assignment :: struct {
    section: string,
    key:     string,
    value:   string,
    source:  string,
    line:    int,
    section_instance: int,
}

Resolved_Document :: struct {
    root:        string,
    assignments: [dynamic]Resolved_Assignment,
    files:       [dynamic]string,
    dependencies: [dynamic]string,
}

Resolve_Diagnostic :: struct {
    source:  string,
    line:    int,
    message: string,
}

resolver_state :: struct {
    result:      Resolved_Document,
    diagnostics: [dynamic]Resolve_Diagnostic,
    stack:       [dynamic]string,
}

Destroy_Resolved_Document :: proc(document: ^Resolved_Document) {
    delete(document.root)
    for &assignment in document.assignments {
        delete(assignment.section)
        delete(assignment.key)
        delete(assignment.value)
        delete(assignment.source)
    }
    delete(document.assignments)
    for file in document.files { delete(file) }
    delete(document.files)
    for dependency in document.dependencies { delete(dependency) }
    delete(document.dependencies)
    document^ = {}
}

Destroy_Resolve_Diagnostics :: proc(diagnostics: ^[dynamic]Resolve_Diagnostic) {
    for &diagnostic in diagnostics {
        delete(diagnostic.source)
        delete(diagnostic.message)
    }
    delete(diagnostics^)
    diagnostics^ = {}
}

resolve_error :: proc(state: ^resolver_state, source: string, line: int, message: string) {
    append(&state.diagnostics, Resolve_Diagnostic{
        source = strings.clone(source),
        line = line,
        message = strings.clone(message),
    })
}

string_list_contains :: proc(values: []string, wanted: string) -> bool {
    for value in values { if value == wanted { return true } }
    return false
}

normalized_path :: proc(path, relative_to: string) -> (string, bool) {
    candidate := path
    joined := ""
    if !os.is_absolute_path(path) && relative_to != "" {
        directory, _ := os.split_path(relative_to)
        joined, _ = os.join_path({directory, path}, context.allocator)
        if joined == "" { return "", false }
        candidate = joined
    } else if !os.is_absolute_path(path) {
        working_directory, cwd_error := os.get_working_directory(context.allocator)
        if cwd_error != nil { return "", false }
        defer delete(working_directory)
        joined, _ = os.join_path({working_directory, path}, context.allocator)
        if joined == "" { return "", false }
        candidate = joined
    }
    normalized := ""
    succeeded := false
    if os.exists(candidate) {
        absolute, error := os.get_absolute_path(candidate, context.allocator)
        normalized, succeeded = absolute, error == nil
    } else {
        cleaned, error := os.clean_path(candidate, context.allocator)
        normalized, succeeded = cleaned, error == nil
    }
    if joined != "" { delete(joined) }
    return normalized, succeeded
}

cycle_message :: proc(stack: []string, repeated: string) -> string {
    builder := strings.builder_make()
    defer strings.builder_destroy(&builder)
    start := 0
    for path, index in stack {
        if path == repeated { start = index; break }
    }
    for index := start; index < len(stack); index += 1 {
        if index > start { strings.write_string(&builder, " -> ") }
        strings.write_string(&builder, stack[index])
    }
    strings.write_string(&builder, " -> ")
    strings.write_string(&builder, repeated)
    return strings.clone(strings.to_string(builder))
}

resolve_file :: proc(state: ^resolver_state, requested, relative_to, importer: string, import_line: int, optional: bool) -> bool {
    path, path_ok := normalized_path(requested, relative_to)
    if !path_ok {
        resolve_error(state, importer, import_line, "could not normalize import path")
        return false
    }
    defer delete(path)

    if !string_list_contains(state.result.dependencies[:], path) {
        append(&state.result.dependencies, strings.clone(path))
    }

    if string_list_contains(state.stack[:], path) {
        chain := cycle_message(state.stack[:], path)
        message := fmt.aprintf("import cycle: %s", chain)
        resolve_error(state, importer, import_line, message)
        delete(message)
        delete(chain)
        return false
    }
    if string_list_contains(state.result.files[:], path) { return true }
    if !os.exists(path) {
        if optional { return true }
        message := fmt.aprintf("required configuration file does not exist: %s", path)
        resolve_error(state, importer, import_line, message)
        delete(message)
        return false
    }

    data, read_error := os.read_entire_file_from_path(path, context.allocator)
    if read_error != nil {
        message := fmt.aprintf("cannot read configuration file: %s", path)
        resolve_error(state, importer, import_line, message)
        delete(message)
        return false
    }
    defer delete(data)

    document, parse_diagnostics, parsed := Parse(data, path)
    defer Destroy_Document(&document)
    defer Destroy_Diagnostics(&parse_diagnostics)
    if !parsed {
        for diagnostic in parse_diagnostics {
            resolve_error(state, path, diagnostic.line, diagnostic.message)
        }
        return false
    }

    stack_path := strings.clone(path)
    append(&state.stack, stack_path)
    defer {
        delete(pop(&state.stack))
    }

    valid := true
    for assignment in document.assignments {
        if assignment.section == "import" {
            import_path := assignment.value
            import_optional := false
            if len(import_path) > 0 && import_path[0] == '?' {
                import_optional = true
                import_path = strings.trim_space(import_path[1:])
            }
            if import_path == "" {
                resolve_error(state, path, assignment.line, "empty import path")
                valid = false
                continue
            }
            if !resolve_file(state, import_path, path, path, assignment.line, import_optional) {
                valid = false
            }
            continue
        }
        append(&state.result.assignments, Resolved_Assignment{
            section = strings.clone(assignment.section),
            key = strings.clone(assignment.key),
            value = strings.clone(assignment.value),
            source = strings.clone(path),
            line = assignment.line,
            section_instance = assignment.section_instance,
        })
    }
    append(&state.result.files, strings.clone(path))
    return valid
}

Resolve :: proc(root: string) -> (
    result: Resolved_Document,
    diagnostics: [dynamic]Resolve_Diagnostic,
    ok: bool,
) {
    state: resolver_state
    state.result.assignments = make([dynamic]Resolved_Assignment, 0, 64)
    state.result.files = make([dynamic]string, 0, 8)
    state.result.dependencies = make([dynamic]string, 0, 8)
    state.diagnostics = make([dynamic]Resolve_Diagnostic, 0, 4)
    state.stack = make([dynamic]string, 0, 8)
    root_path, root_ok := normalized_path(root, "")
    if root_ok { state.result.root = strings.clone(root_path); delete(root_path) }
    valid := resolve_file(&state, root, "", root, 0, false)
    delete(state.stack)
    return state.result, state.diagnostics, valid && len(state.diagnostics) == 0
}

Format_Resolve_Diagnostic :: proc(diagnostic: Resolve_Diagnostic) -> string {
    if diagnostic.line > 0 {
        return fmt.aprintf("%s:%d: %s", diagnostic.source, diagnostic.line, diagnostic.message)
    }
    return fmt.aprintf("%s: %s", diagnostic.source, diagnostic.message)
}
