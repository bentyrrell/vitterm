import Foundation
import QuartzCore

/// Cursor trail settings, resolved to concrete values by the app.
public struct CursorTrailOptions: Equatable {
    public var color: UInt32          // 0x00RRGGBB
    public var opacity: Float
    public var fastDecay: Double      // seconds: leading corners
    public var slowDecay: Double      // seconds: trailing corners
    public var threshold: Int         // minimum jump, in cells, that animates

    public init(color: UInt32, opacity: Float, fastDecay: Double, slowDecay: Double, threshold: Int) {
        self.color = color; self.opacity = opacity; self.fastDecay = fastDecay; self.slowDecay = slowDecay; self.threshold = threshold
    }
}

/// Animates a "smear" from the cursor's previous position to its new one. Each corner of the cursor
/// box eases toward its target independently: corners facing the direction of travel move quickly,
/// the trailing ones slowly, so the box stretches into a trail and then collapses onto the cursor.
struct CursorTrail {
    /// Corners: top-left, top-right, bottom-right, bottom-left (pixels).
    private var corners: [SIMD2<Float>] = []
    private var target: [SIMD2<Float>] = []
    private var decay: [Double] = [0, 0, 0, 0]
    private var lastTime: CFTimeInterval = 0
    private(set) var animating = false
    /// A large jump the trail hasn't committed to yet, and when it was first seen.
    private var pending: [SIMD2<Float>] = []
    private var pendingSince: CFTimeInterval = 0
    /// The cursor box in the previous frame. Moves are measured frame to frame, so steady small
    /// steps (fast typing, key repeat) never add up to a jump.
    private var lastSeen: [SIMD2<Float>] = []

    /// How long the cursor must stay at a far-away position before the trail animates to it.
    /// Shells and TUIs move the cursor around while redrawing (zsh's Tab completion goes to the
    /// next row's first column and back within a millisecond). A frame can catch one of those
    /// intermediate positions, and animating to it and back smears across the text being drawn.
    static let settleTime: CFTimeInterval = 0.025

    /// True while more frames are needed: animating, or waiting to see whether a jump settles.
    var needsFrames: Bool { animating || !pending.isEmpty }

    static func box(_ x: Float, _ y: Float, _ w: Float, _ h: Float) -> [SIMD2<Float>] {
        [SIMD2(x, y), SIMD2(x + w, y), SIMD2(x + w, y + h), SIMD2(x, y + h)]
    }

    mutating func reset() {
        corners = []
        target = []
        pending = []
        lastSeen = []
        animating = false
    }

    /// Advance the animation toward the cursor box. Returns the polygon to draw (empty when idle).
    mutating func update(cursor: [SIMD2<Float>], cell: SIMD2<Float>, options o: CursorTrailOptions,
                         now: CFTimeInterval = CACurrentMediaTime()) -> [SIMD2<Float>] {
        if corners.isEmpty {
            corners = cursor
            target = cursor
            lastSeen = cursor
            lastTime = now
            return []
        }
        func cells(_ a: [SIMD2<Float>], _ b: [SIMD2<Float>]) -> Float {
            let d = (a[0] - b[0]) / cell
            return max(abs(d.x), abs(d.y))
        }
        let step = cells(cursor, lastSeen)
        lastSeen = cursor
        let threshold = Float(o.threshold)
        /// Leading corners (pointing along the motion from `origin`) are fast, trailing ones slow.
        func aim(from origin: SIMD2<Float>) {
            let center = (cursor[0] + cursor[2]) / 2
            let dir = simd_normalize_safe(center - origin)
            for i in 0..<4 {
                let out = simd_normalize_safe(cursor[i] - center)
                let d = Double(out.x * dir.x + out.y * dir.y) // -1 ... 1
                let t = (d + 1) / 2                             // 0 trailing ... 1 leading
                decay[i] = o.slowDecay + (o.fastDecay - o.slowDecay) * t
            }
        }
        if cursor == target {
            pending = []
        } else if animating {
            // In flight, follow the cursor at once. After Enter the shell parks the cursor at the
            // start of the next row while it computes the prompt, then draws the prompt (often a
            // row further down): waiting for that to settle bends the trail into two hops. A new
            // jump re-aims the corners from where the smear is now; small moves (typing straight
            // after Enter) just carry the target along.
            if cells(cursor, target) >= threshold && step >= threshold {
                aim(from: (corners[0] + corners[1] + corners[2] + corners[3]) / 4)
            }
            pending = []
            target = cursor
        } else if cells(cursor, target) < threshold
                    || (step < threshold && cursor != pending && (pending.isEmpty || pending[0].y == target[0].y)) {
            // Back near where the cursor rests, or a small move since the last frame (fast typing,
            // even with a 2-cell step pending): snap. A pending jump to another row (Enter) survives
            // small steps: the output and the prompt arrive a row or so at a time.
            corners = cursor
            pending = []
            target = cursor
        } else if cursor != pending {
            // Possibly an intermediate position of a redraw: wait and see whether it stays.
            pending = cursor
            pendingSince = now
        } else if now - pendingSince >= CursorTrail.settleTime {
            pending = []
            aim(from: (target[0] + target[2]) / 2)
            lastTime = now
            animating = true
            target = cursor
        }
        guard animating else { return [] }

        let dt = min(max(now - lastTime, 0), 0.05)
        lastTime = now
        var maxDist: Float = 0
        for i in 0..<4 {
            // Exponential ease; `decay` is the time to cover ~98% of the distance.
            let tau = max(decay[i] / 4, 0.001)
            let k = Float(1 - exp(-dt / tau))
            corners[i] += (target[i] - corners[i]) * k
            let d = corners[i] - target[i]
            maxDist = max(maxDist, max(abs(d.x), abs(d.y)))
        }
        if maxDist < 0.5 {
            corners = target
            animating = false
            return []
        }
        // Draw the convex hull of the moving box and the cursor box, so the smear always connects
        // to the cursor and never twists.
        return CursorTrail.triangulatedHull(corners + target)
    }

    /// Convex hull (monotone chain) as a triangle fan expanded to a triangle list.
    static func triangulatedHull(_ pts: [SIMD2<Float>]) -> [SIMD2<Float>] {
        let p = pts.sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
        guard p.count >= 3 else { return [] }
        func cross(_ o: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [SIMD2<Float>] = [], upper: [SIMD2<Float>] = []
        for q in p {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], q) <= 0 { lower.removeLast() }
            lower.append(q)
        }
        for q in p.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], q) <= 0 { upper.removeLast() }
            upper.append(q)
        }
        let hull = Array(lower.dropLast() + upper.dropLast())
        guard hull.count >= 3 else { return [] }
        var tris: [SIMD2<Float>] = []
        for i in 1..<(hull.count - 1) { tris += [hull[0], hull[i], hull[i + 1]] }
        return tris
    }
}

@inline(__always) func simd_normalize_safe(_ v: SIMD2<Float>) -> SIMD2<Float> {
    let l = (v.x * v.x + v.y * v.y).squareRoot()
    return l > 0 ? v / l : SIMD2(0, 0)
}
