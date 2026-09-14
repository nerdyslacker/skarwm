package core

// Resize_Pair moves one tiled boundary while preserving the pair's total
// extent. max <= 0 means unbounded. It is shared by column and row resizing.
Resize_Pair :: proc(
    first_start, second_start, delta, first_min, second_min: i32,
    first_max: i32 = 0, second_max: i32 = 0,
) -> (first, second: i32) {
    total := max(i32(2), first_start + second_start)
    lo := clamp(max(i32(1), first_min), i32(1), total - 1)
    hi := clamp(total - max(i32(1), second_min), i32(1), total - 1)
    if second_max > 0 { lo = max(lo, total - second_max) }
    if first_max > 0 { hi = min(hi, first_max) }
    lo = clamp(lo, i32(1), total - 1)
    hi = clamp(hi, i32(1), total - 1)
    if hi < lo {
        // Conflicting hints cannot be satisfied while retaining a filled pair.
        // Prefer positive geometry and the requested first-side minimum.
        hi = lo
    }
    first = clamp(first_start + delta, lo, hi)
    second = max(i32(1), total - first)
    return
}

Constrain_Size :: proc(hints: Size_Hints, width, height: i32) -> (w, h: i32) {
    w, h = max(i32(1), width), max(i32(1), height)
    if hints.MinW > 0 { w = max(w, hints.MinW) }
    if hints.MinH > 0 { h = max(h, hints.MinH) }
    if hints.MaxW > 0 { w = min(w, hints.MaxW) }
    if hints.MaxH > 0 { h = min(h, hints.MaxH) }

    base_w := hints.BaseW
    base_h := hints.BaseH
    if base_w <= 0 && hints.MinW > 0 { base_w = hints.MinW }
    if base_h <= 0 && hints.MinH > 0 { base_h = hints.MinH }
    if hints.IncW > 0 && w > base_w { w = base_w + (w - base_w) / hints.IncW * hints.IncW }
    if hints.IncH > 0 && h > base_h { h = base_h + (h - base_h) / hints.IncH * hints.IncH }

    if hints.MinW > 0 { w = max(w, hints.MinW) }
    if hints.MinH > 0 { h = max(h, hints.MinH) }
    if hints.MaxW > 0 { w = min(w, hints.MaxW) }
    if hints.MaxH > 0 { h = min(h, hints.MaxH) }
    return
}
