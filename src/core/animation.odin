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

Animation_Scale_From_Center :: proc(rect: Rect, percent: i32) -> Rect {
    scale := clamp(percent, i32(0), i32(100))
    width := max(i32(1), rect.W*scale/100)
    height := max(i32(1), rect.H*scale/100)
    return Rect{
        X = rect.X+rect.W/2-width/2,
        Y = rect.Y+rect.H/2-height/2,
        W = width,
        H = height,
    }
}

Animation_Nearest_Edge_Rect :: proc(rect, output: Rect) -> Rect {
    center_x := rect.X+rect.W/2
    center_y := rect.Y+rect.H/2
    left := abs(center_x-output.X)
    right := abs(output.X+output.W-center_x)
    top := abs(center_y-output.Y)
    bottom := abs(output.Y+output.H-center_y)
    edge := min(left, right, top, bottom)
    result := rect
    if edge == left {
        result.X = output.X-rect.W
    } else if edge == right {
        result.X = output.X+output.W
    } else if edge == top {
        result.Y = output.Y-rect.H
    } else {
        result.Y = output.Y+output.H
    }
    return result
}

Animation_Transition_Endpoints :: proc(
    current, target, output: Rect,
    current_parked, target_parked: bool,
) -> (start, end: Rect) {
    start, end = current, target
    if current_parked && !target_parked {
        start = Animation_Nearest_Edge_Rect(target, output)
    } else if !current_parked && target_parked {
        end = Animation_Nearest_Edge_Rect(current, output)
    }
    return
}
