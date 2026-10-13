package core

import "core:fmt"
import "core:strings"

Screen_Source :: enum u8 {
    Root,
    Xinerama,
}

Screen_Identity_Confidence :: enum u8 {
    Degraded,
    New,
    Exact,
    Overlap,
    Proximity,
}

Discovered_Screen :: struct {
    Identity: string,
    Geom: Rect,
    Confidence: Screen_Identity_Confidence,
    Source: Screen_Source,
}

Screen_Topology_Snapshot :: struct {
    Screens: [dynamic]Discovered_Screen,
    RootGeometry: Rect,
    Generation: u64,
    Source: Screen_Source,
    Degraded: bool,
}

Free_Screen_Topology :: proc(snapshot: ^Screen_Topology_Snapshot) {
    if snapshot == nil { return }
    for screen in snapshot.Screens {
        if screen.Identity != "" { delete(screen.Identity) }
    }
    delete(snapshot.Screens)
    snapshot^ = {}
}

Screen_Topology_Equal :: proc(a, b: ^Screen_Topology_Snapshot) -> bool {
    if a == nil || b == nil || a.RootGeometry != b.RootGeometry || a.Source != b.Source ||
       a.Degraded != b.Degraded || len(a.Screens) != len(b.Screens) { return false }
    for screen, i in a.Screens {
        other := b.Screens[i]
        if screen.Identity != other.Identity || screen.Geom != other.Geom ||
           screen.Source != other.Source { return false }
    }
    return true
}

rect_contains :: proc(outer, inner: Rect) -> bool {
    if outer.W <= 0 || outer.H <= 0 || inner.W <= 0 || inner.H <= 0 { return false }
    return i64(inner.X) >= i64(outer.X) && i64(inner.Y) >= i64(outer.Y) &&
        i64(inner.X) + i64(inner.W) <= i64(outer.X) + i64(outer.W) &&
        i64(inner.Y) + i64(inner.H) <= i64(outer.Y) + i64(outer.H)
}

screen_rect_ordered :: proc(a, b: Rect) -> bool {
    return a.X < b.X || (a.X == b.X && (a.Y < b.Y ||
        (a.Y == b.Y && (a.W < b.W || (a.W == b.W && a.H <= b.H)))))
}

Normalize_Xinerama_Rects :: proc(rects: []Rect) -> [dynamic]Rect {
    unique := make([dynamic]Rect, 0, len(rects))
    for rect in rects {
        if rect.W <= 0 || rect.H <= 0 { continue }
        duplicate := false
        for prior in unique {
            if prior == rect { duplicate = true; break }
        }
        if !duplicate { append(&unique, rect) }
    }

    result := make([dynamic]Rect, 0, len(unique))
    for rect, i in unique {
        contained := false
        for other, j in unique {
            if i != j && rect != other && rect_contains(other, rect) {
                contained = true
                break
            }
        }
        if !contained { append(&result, rect) }
    }
    delete(unique)

    for i in 1 ..< len(result) {
        j := i
        for j > 0 && !screen_rect_ordered(result[j - 1], result[j]) {
            result[j - 1], result[j] = result[j], result[j - 1]
            j -= 1
        }
    }
    return result
}

rect_overlap_area :: proc(a, b: Rect) -> i64 {
    left := max(i64(a.X), i64(b.X))
    top := max(i64(a.Y), i64(b.Y))
    right := min(i64(a.X) + i64(a.W), i64(b.X) + i64(b.W))
    bottom := min(i64(a.Y) + i64(a.H), i64(b.Y) + i64(b.H))
    if right <= left || bottom <= top { return 0 }
    return (right - left) * (bottom - top)
}

rect_center_distance :: proc(a, b: Rect) -> i64 {
    dx := (i64(a.X) * 2 + i64(a.W)) - (i64(b.X) * 2 + i64(b.W))
    dy := (i64(a.Y) * 2 + i64(a.H)) - (i64(b.Y) * 2 + i64(b.H))
    return dx * dx + dy * dy
}

Build_Xinerama_Snapshot :: proc(
    root: Rect,
    queried: []Rect,
    previous: ^Screen_Topology_Snapshot,
    next_identity: ^u64,
) -> (snapshot: Screen_Topology_Snapshot, ok: bool) {
    if root.W <= 0 || root.H <= 0 || next_identity == nil { return {}, false }
    rects := Normalize_Xinerama_Rects(queried)
    defer delete(rects)
    if len(rects) == 0 { return {}, false }

    snapshot.RootGeometry = root
    snapshot.Source = .Xinerama
    snapshot.Screens = make([dynamic]Discovered_Screen, len(rects))
    for rect, i in rects {
        snapshot.Screens[i] = Discovered_Screen{Geom = rect, Source = .Xinerama, Confidence = .New}
    }

    old_used := make([]bool, len(previous.Screens) if previous != nil else 0)
    new_used := make([]bool, len(snapshot.Screens))
    defer delete(old_used)
    defer delete(new_used)

    if previous != nil && previous.Source == .Xinerama {
        for &screen, i in snapshot.Screens {
            for old, j in previous.Screens {
                if !old_used[j] && old.Source == .Xinerama && old.Geom == screen.Geom {
                    screen.Identity = strings.clone(old.Identity)
                    screen.Confidence = .Exact
                    old_used[j], new_used[i] = true, true
                    break
                }
            }
        }

        for {
            best_new, best_old := -1, -1
            best_overlap, best_distance := i64(-1), i64(0x7fff_ffff_ffff_ffff)
            for screen, i in snapshot.Screens {
                if new_used[i] { continue }
                for old, j in previous.Screens {
                    if old_used[j] || old.Source != .Xinerama { continue }
                    overlap := rect_overlap_area(screen.Geom, old.Geom)
                    distance := rect_center_distance(screen.Geom, old.Geom)
                    better := overlap > best_overlap ||
                        (overlap == best_overlap && (distance < best_distance ||
                        (distance == best_distance && (best_new < 0 || i < best_new ||
                        (i == best_new && old.Identity < previous.Screens[best_old].Identity)))))
                    if better {
                        best_new, best_old = i, j
                        best_overlap, best_distance = overlap, distance
                    }
                }
            }
            if best_new < 0 { break }
            snapshot.Screens[best_new].Identity = strings.clone(previous.Screens[best_old].Identity)
            snapshot.Screens[best_new].Confidence = best_overlap > 0 ? .Overlap : .Proximity
            new_used[best_new], old_used[best_old] = true, true
        }
    }

    for &screen in snapshot.Screens {
        if screen.Identity != "" { continue }
        next_identity^ += 1
        screen.Identity = fmt.aprintf("xinerama-%d", next_identity^)
    }
    if previous != nil { snapshot.Generation = previous.Generation + 1 }
    return snapshot, true
}

Build_Root_Snapshot :: proc(root: Rect, generation: u64 = 0) -> (Screen_Topology_Snapshot, bool) {
    if root.W <= 0 || root.H <= 0 { return {}, false }
    snapshot := Screen_Topology_Snapshot{
        RootGeometry = root,
        Generation = generation,
        Source = .Root,
        Degraded = true,
        Screens = make([dynamic]Discovered_Screen, 0, 1),
    }
    append(&snapshot.Screens, Discovered_Screen{
        Identity = strings.clone("screen"),
        Geom = root,
        Confidence = .Degraded,
        Source = .Root,
    })
    return snapshot, true
}

Screen_Snapshot_Specs :: proc(snapshot: ^Screen_Topology_Snapshot) -> [dynamic]Output_Spec {
    result := make([dynamic]Output_Spec, 0, len(snapshot.Screens) if snapshot != nil else 0)
    if snapshot == nil { return result }
    for screen, i in snapshot.Screens {
        append(&result, Output_Spec{Name = strings.clone(screen.Identity), Geom = screen.Geom, Primary = i == 0})
    }
    return result
}
