package main

import "core:fmt"
import "core:os"
import "core:strings"
import cfg "../../src/config"

g_pass, g_fail: int

check :: proc(condition: bool, message: string) {
    if condition { g_pass += 1 } else { g_fail += 1; fmt.eprintln("FAIL:", message) }
}

equal :: proc(got, want: $T, message: string) {
    if got == want {
        g_pass += 1
    } else {
        g_fail += 1
        fmt.eprintln("FAIL:", message, " got=", got, " want=", want)
    }
}

parse_ok :: proc(text: string) -> cfg.Document {
    document, diagnostics, valid := cfg.Parse(transmute([]byte)text, "test.conf")
    defer cfg.Destroy_Diagnostics(&diagnostics)
    check(valid, "configuration should parse")
    return document
}

test_sections_and_values :: proc() {
    document := parse_ok(`
# first comment
; second comment
[general]
mod_key = super

[window.border]
normal = #504D47
selected = #FCE8C3
`)
    defer cfg.Destroy_Document(&document)
    equal(len(document.assignments), 3, "three assignments are retained")
    equal(document.assignments[0].section, "general", "simple section")
    equal(document.assignments[1].section, "window.border", "hierarchical section")
    equal(document.assignments[1].value, "#504D47", "hex colour is not a comment")
    equal(document.assignments[2].line, 9, "source line is retained")
}

test_bindings_commands_and_unicode :: proc() {
    document := parse_ok(`
[bind]
"mod + Return" = "sh -c \"printf '%s=%s:100%%' '$A' 'x\\y'\""
[bar.block.clock]
icon = 󰃭
command = date '+%a, %b %d - %H:%M:%S' # literal shell text
`)
    defer cfg.Destroy_Document(&document)
    equal(len(document.assignments), 3, "binding and block assignments parse")
    equal(document.assignments[0].key, "mod + Return", "quoted assignment key")
    equal(document.assignments[0].value, `sh -c "printf '%s=%s:100%%' '$A' 'x\y'"`, "minimal quote and slash escapes")
    equal(document.assignments[1].value, "󰃭", "unicode value")
    equal(document.assignments[2].value, "date '+%a, %b %d - %H:%M:%S' # literal shell text", "unquoted shell punctuation is preserved")
}

test_order :: proc() {
    document := parse_ok(`
[window]
outer_gap = 4
[import]
appearance = config.d/appearance.conf
[window]
outer_gap = 8
`)
    defer cfg.Destroy_Document(&document)
    equal(len(document.assignments), 3, "ordered stream contains import")
    equal(document.assignments[0].section, "window", "setting before import")
    equal(document.assignments[1].section, "import", "import retains relative position")
    equal(document.assignments[2].value, "8", "setting after import")
    check(document.assignments[0].section_instance != document.assignments[2].section_instance,
        "reopened scalar sections retain distinct source occurrences")
}

expect_invalid :: proc(text, message: string) {
    document, diagnostics, valid := cfg.Parse(transmute([]byte)text, "bad.conf")
    defer cfg.Destroy_Document(&document)
    defer cfg.Destroy_Diagnostics(&diagnostics)
    check(!valid, message)
    check(len(diagnostics) > 0, "invalid input has a diagnostic")
    if len(diagnostics) > 0 { check(diagnostics[0].line > 0, "diagnostic has a source line") }
}

test_errors :: proc() {
    expect_invalid("key = value", "assignment before section is rejected")
    expect_invalid("[window\nkey = value", "unterminated section is rejected")
    expect_invalid("[window..border]\nkey = value", "empty section component is rejected")
    expect_invalid("[window]\nnot an assignment", "missing equals is rejected")
    expect_invalid("[window]\n\"bad key = value", "unterminated quoted key is rejected")
    expect_invalid("[window]\nkey = \"value", "unterminated quoted value is rejected")
    expect_invalid("[window]\nkey =", "empty value is rejected")
    expect_invalid("[window]\nouter_gap = 4\nouter_gap = 8", "duplicate assignment in one section declaration is rejected")
}

test_imports :: proc() {
    resolved, diagnostics, valid := cfg.Resolve("tests/config_tests/fixtures/root.conf")
    defer cfg.Destroy_Resolved_Document(&resolved)
    defer cfg.Destroy_Resolve_Diagnostics(&diagnostics)
    check(valid, "relative, nested, optional, and repeated imports resolve")
    equal(len(resolved.assignments), 5, "imports expand in place and repeated files deduplicate")
    equal(resolved.assignments[0].value, "4", "local value before import stays first")
    equal(resolved.assignments[1].key, "inner_gap", "relative import follows declaration")
    equal(resolved.assignments[2].section, "window.border", "nested relative import resolves from importer directory")
    equal(resolved.assignments[3].section, "animation", "nested local assignment follows its import")
    equal(resolved.assignments[4].value, "8", "local value after imports stays last")
    equal(len(resolved.files), 4, "root and three unique imported files are recorded")
    equal(len(resolved.dependencies), 5, "missing optional imports remain tracked dependencies")
    check(strings.has_suffix(resolved.dependencies[2], "missing.conf"), "optional dependency keeps its normalized target path")

    absolute, absolute_error := os.get_absolute_path("tests/config_tests/fixtures/root.conf", context.allocator)
    check(absolute_error == nil, "fixture absolute path resolves")
    if absolute_error == nil {
        absolute_result, absolute_diagnostics, absolute_valid := cfg.Resolve(absolute)
        cfg.Destroy_Resolved_Document(&absolute_result)
        cfg.Destroy_Resolve_Diagnostics(&absolute_diagnostics)
        check(absolute_valid, "absolute root paths resolve")
        delete(absolute)
    }
}

test_merge :: proc() {
    normalized := cfg.Normalize_Binding_Key("Shift + mod + Return")
    equal(normalized, "mod+shift+Return", "binding normalization is deterministic")
    delete(normalized)
    resolved, diagnostics, valid := cfg.Resolve("tests/config_tests/fixtures/root.conf")
    defer cfg.Destroy_Resolved_Document(&resolved)
    defer cfg.Destroy_Resolve_Diagnostics(&diagnostics)
    check(valid, "merge fixture resolves")
    merged := cfg.Merge(&resolved)
    defer cfg.Destroy_Merged_Document(&merged)
    equal(len(merged.entries), 4, "later scalar replaces earlier value in place")
    if outer_gap, found := cfg.Find(&merged, "window", "outer_gap"); found {
        equal(outer_gap.value, "8", "later local scalar wins")
    } else {
        check(false, "merged outer gap exists")
    }

    binding_source: cfg.Resolved_Document
    binding_source.assignments = make([dynamic]cfg.Resolved_Assignment, 0, 4)
    append(&binding_source.assignments,
        cfg.Resolved_Assignment{section = "bind", key = "Shift + mod + Return", value = "xterm"},
        cfg.Resolved_Assignment{section = "call", key = "mod+Shift+Return", value = "close_window"},
        cfg.Resolved_Assignment{section = "call", key = "h", value = "focusleft"},
        cfg.Resolved_Assignment{section = "call", key = "mod + h", value = "focusright"},
    )
    bindings := cfg.Merge(&binding_source)
    defer cfg.Destroy_Merged_Document(&bindings)
    delete(binding_source.assignments)
    equal(len(bindings.entries), 2, "normalized binding combination replaces across binding sections")
    equal(bindings.entries[0].section, "call", "later binding kind wins without reordering")
    equal(bindings.entries[0].value, "close_window", "later binding action wins")
    equal(bindings.entries[1].value, "focusright", "implicit primary modifier normalizes to mod")

    named_source: cfg.Resolved_Document
    named_source.assignments = make([dynamic]cfg.Resolved_Assignment, 0, 5)
    append(&named_source.assignments,
        cfg.Resolved_Assignment{section = "rule.terminal", key = "class", value = "XTerm"},
        cfg.Resolved_Assignment{section = "rule.terminal", key = "floating", value = "true"},
        cfg.Resolved_Assignment{section = "rule.browser", key = "class", value = "Firefox"},
        cfg.Resolved_Assignment{section = "rule.terminal", key = "floating", value = "false"},
        cfg.Resolved_Assignment{section = "rule.terminal", key = "workspace", value = "2"},
    )
    named := cfg.Merge(&named_source)
    defer cfg.Destroy_Merged_Document(&named)
    delete(named_source.assignments)
    equal(len(named.entries), 4, "named object properties merge independently")
    equal(named.entries[1].value, "false", "named property override replaces in place")
    equal(named.entries[2].section, "rule.browser", "overriding an object does not reorder peers")
    equal(named.entries[3].key, "workspace", "new named property appends in declaration order")
}

expect_resolve_invalid :: proc(path, fragment, message: string) {
    resolved, diagnostics, valid := cfg.Resolve(path)
    defer cfg.Destroy_Resolved_Document(&resolved)
    defer cfg.Destroy_Resolve_Diagnostics(&diagnostics)
    check(!valid, message)
    check(len(diagnostics) > 0, "resolver failure includes a diagnostic")
    if len(diagnostics) > 0 {
        check(strings.contains(diagnostics[0].message, fragment), "resolver diagnostic identifies the failure")
    }
}

test_import_errors :: proc() {
    expect_resolve_invalid("tests/config_tests/fixtures/missing-required.conf", "does not exist", "required import is enforced")
    expect_resolve_invalid("tests/config_tests/fixtures/invalid-root.conf", "section", "invalid imported file fails the graph")
    expect_resolve_invalid("tests/config_tests/fixtures/cycle-a.conf", "cycle", "import cycles are rejected")
}

test_shipped_default :: proc() {
    resolved, diagnostics, valid := cfg.Resolve("assets/default.conf")
    defer cfg.Destroy_Resolved_Document(&resolved)
    defer cfg.Destroy_Resolve_Diagnostics(&diagnostics)
    check(valid, "shipped modular default resolves")
    equal(len(resolved.files), 8, "default root and seven modules load")
    equal(len(resolved.dependencies), 9, "optional local override is tracked")
    merged := cfg.Merge(&resolved)
    defer cfg.Destroy_Merged_Document(&merged)
    check(len(merged.entries) > 70, "complete default retains settings, bindings, blocks, rules, and autostart")
}

main :: proc() {
    test_sections_and_values()
    test_bindings_commands_and_unicode()
    test_order()
    test_errors()
    test_imports()
    test_import_errors()
    test_merge()
    test_shipped_default()
    fmt.printf("\n%d passed, %d failed\n", g_pass, g_fail)
    if g_fail > 0 { os.exit(1) }
}
