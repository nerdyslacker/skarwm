package core

import "core:math"

// Animation_Progress converts elapsed monotonic time to a stable normalized
// progress value. A non-positive duration deliberately completes immediately.
Animation_Progress :: proc(elapsed, duration: i64) -> f64 {
    if duration <= 0 || elapsed >= duration { return 1 }
    if elapsed <= 0 { return 0 }
    return f64(elapsed) / f64(duration)
}

Animation_Ease :: proc(easing: Animation_Easing, progress: f64) -> f64 {
    t := clamp(progress, f64(0), f64(1))
    switch easing {
    case .Linear:
        return t
    case .Ease_Out_Cubic:
        inv := 1 - t
        return 1 - inv * inv * inv
    }
    return t
}

Animation_Lerp_I32 :: proc(start, target: i32, factor: f64) -> i32 {
    if factor <= 0 { return start }
    if factor >= 1 { return target }
    return i32(math.round(f64(start) + f64(target - start) * factor))
}

Animation_Lerp_Rect :: proc(start, target: Rect, factor: f64) -> Rect {
    return Rect {
        X = Animation_Lerp_I32(start.X, target.X, factor),
        Y = Animation_Lerp_I32(start.Y, target.Y, factor),
        W = max(i32(1), Animation_Lerp_I32(start.W, target.W, factor)),
        H = max(i32(1), Animation_Lerp_I32(start.H, target.H, factor)),
    }
}
