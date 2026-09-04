package main

// Keysym name lookup + per-server keymap/modifier-mapping caches.
//
// libxcb-keysyms is not linked (headers absent), so the equivalent work is done
// directly against the X core protocol:
//   - xcb_get_keyboard_mapping  -> keycode -> keysyms (levels per keycode)
//   - xcb_get_modifier_mapping  -> modifier index -> keycodes
// Caches are rebuilt on XCB_MAPPING_NOTIFY.

// Keyboard mapping snapshot. `syms` is a flat array laid out as
//   syms[(keycode - MIN_KEYCODE) * keysyms_per_keycode + level]
// for every keycode in [MIN_KEYCODE, 255].
MIN_KEYCODE :: u8(8)
KEYCODE_COUNT :: int(255 - 8 + 1)

Kbd_Map :: struct {
    keysyms_per_keycode: int,
    syms:                []u32,
}

Mod_Map :: struct {
    keycodes_per_modifier: int,
    keycodes:              []u8, // 8 rows x keycodes_per_modifier, row-major
}

kbd_load :: proc(c: ^Connection) -> (m: Kbd_Map, ok: bool) {
    cookie := xcb_get_keyboard_mapping(c, MIN_KEYCODE, u8(KEYCODE_COUNT))
    e: ^Error
    reply := xcb_get_keyboard_mapping_reply(c, cookie, &e)
    if e != nil {
        free_libc(e)
        return m, false
    }
    if reply == nil { return m, false }
    defer free_libc(reply)

    kpm := int(reply.keysyms_per_keycode)
    if kpm == 0 { return m, false }
    n := KEYCODE_COUNT * kpm
    arr := make([]u32, n)
    src := rawptr(uintptr(rawptr(reply)) + uintptr(size_of(Get_Keyboard_Mapping_Reply)))
    copy(arr, ([^]u32)(src)[:n])
    m.keysyms_per_keycode = kpm
    m.syms = arr
    return m, true
}

mod_load :: proc(c: ^Connection) -> (m: Mod_Map, ok: bool) {
    cookie := xcb_get_modifier_mapping(c)
    e: ^Error
    reply := xcb_get_modifier_mapping_reply(c, cookie, &e)
    if e != nil {
        free_libc(e)
        return m, false
    }
    if reply == nil { return m, false }
    defer free_libc(reply)

    kcpm := int(reply.keycodes_per_modifier)
    if kcpm == 0 { return m, false }
    n := 8 * kcpm
    arr := make([]u8, n)
    src := rawptr(uintptr(rawptr(reply)) + uintptr(size_of(Get_Modifier_Mapping_Reply)))
    copy(arr, ([^]u8)(src)[:n])
    m.keycodes_per_modifier = kcpm
    m.keycodes = arr
    return m, true
}

kbd_free :: proc(m: ^Kbd_Map) {
    if m.syms != nil { delete(m.syms) }
    m.syms = nil
}

mod_free :: proc(m: ^Mod_Map) {
    if m.keycodes != nil { delete(m.keycodes) }
    m.keycodes = nil
}

// keysym_at_level returns the keysym for `keycode` at `level`, 0 if unknown.
keysym_at_level :: proc(kb: ^Kbd_Map, keycode: u8, level: int = 0) -> u32 {
    if kb.syms == nil || int(keycode) < int(MIN_KEYCODE) { return 0 }
    idx := (int(keycode) - int(MIN_KEYCODE)) * kb.keysyms_per_keycode + level
    if idx < 0 || idx >= len(kb.syms) { return 0 }
    return kb.syms[idx]
}

// keysym_to_keycode finds the keycode whose keysym list contains `ks` and
// returns it plus the level at which it matched. A level of 1 means Shift must
// be held to produce the symbol (grab callers OR in the shift modifier).
keysym_to_keycode :: proc(kb: ^Kbd_Map, ks: u32) -> (keycode: u8, level: int) {
    if kb.syms == nil || kb.keysyms_per_keycode <= 0 { return 0, 0 }
    for kc in int(MIN_KEYCODE) ..= 255 {
        base := (kc - int(MIN_KEYCODE)) * kb.keysyms_per_keycode
        for lv in 0 ..< kb.keysyms_per_keycode {
            if kb.syms[base + lv] == ks {
                return u8(kc), lv
            }
        }
    }
    return 0, 0
}

// modifier_mask_for_keysym scans the modifier map for a modifier row that owns a
// keycode producing `ks` (level 0) and returns its mask bit, e.g. the row that
// owns Super_L gives 1<<row. Returns 0 when not found.
modifier_mask_for_keysym :: proc(kb: ^Kbd_Map, mm: ^Mod_Map, ks: u32) -> u16 {
    if mm.keycodes == nil || kb.syms == nil { return 0 }
    for row in 0 ..< 8 {
        base := row * mm.keycodes_per_modifier
        for i in 0 ..< mm.keycodes_per_modifier {
            kc := mm.keycodes[base + i]
            if kc == 0 { continue }
            if keysym_at_level(kb, kc) == ks {
                return u16(1 << uint(row))
            }
        }
    }
    return 0
}

// keysym_from_name looks up a keysym value from its X11 name ("Return",
// "Super_L", "f1", "j" …). Returns 0 for unknown names.
keysym_from_name :: proc(name: string) -> u32 {
    if name == "" { return 0 }
    for e in keysym_names {
        if e.name == name { return e.value }
    }
    return 0
}

// canonical_mods_for_name resolves a config modifier token to a mask.
// Super/Hyper are resolved dynamically from the modifier map so the WM is
// insensitive to which physical modifier index the server assigned them.
canonical_mods_for_name :: proc(name: string, kb: ^Kbd_Map, mm: ^Mod_Map) -> u16 {
    switch name {
    case "Shift", "shift":
        return MOD_MASK_SHIFT
    case "Control", "Ctrl", "control":
        return MOD_MASK_CONTROL
    case "Mod1":
        return MOD_MASK_MOD1
    case "Mod2":
        return MOD_MASK_MOD2
    case "Mod3":
        return MOD_MASK_MOD3
    case "Mod4":
        return MOD_MASK_MOD4
    case "Mod5":
        return MOD_MASK_MOD5
    case "Super", "super":
        if m := modifier_mask_for_keysym(kb, mm, keysym_from_name("Super_L")); m != 0 {
            return m
        }
        return MOD_MASK_MOD4
    case "Hyper", "hyper":
        if m := modifier_mask_for_keysym(kb, mm, keysym_from_name("Hyper_L")); m != 0 {
            return m
        }
        return MOD_MASK_MOD3
    case "Alt", "alt":
        return MOD_MASK_MOD1
    case:
        return 0
    }
}
