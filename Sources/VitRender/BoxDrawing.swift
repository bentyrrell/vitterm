import CoreGraphics

/// Procedural rendering of box drawing, block elements and Powerline glyphs, so they tile
/// seamlessly regardless of the font.
enum BoxDrawing {
    static func handles(_ cp: UInt32) -> Bool {
        (cp >= 0x2500 && cp <= 0x259F) || (cp >= 0xE0B0 && cp <= 0xE0B3) || cp == 0xE0B4 || cp == 0xE0B6
    }

    /// Line weights per direction for U+2500...U+257F: up, right, down, left.
    /// 0 none, 1 light, 2 heavy, 3 double. 0xFF marks characters drawn specially.
    static let lines: [UInt32: (UInt8, UInt8, UInt8, UInt8)] = {
        var m: [UInt32: (UInt8, UInt8, UInt8, UInt8)] = [:]
        let table: [(UInt32, String)] = [
            (0x2500, "0101"), (0x2501, "0202"), (0x2502, "1010"), (0x2503, "2020"),
            (0x250C, "0110"), (0x250D, "0210"), (0x250E, "0120"), (0x250F, "0220"),
            (0x2510, "0011"), (0x2511, "0012"), (0x2512, "0021"), (0x2513, "0022"),
            (0x2514, "1100"), (0x2515, "1200"), (0x2516, "2100"), (0x2517, "2200"),
            (0x2518, "1001"), (0x2519, "1002"), (0x251A, "2001"), (0x251B, "2002"),
            (0x251C, "1110"), (0x251D, "1210"), (0x251E, "2110"), (0x251F, "1120"),
            (0x2520, "2120"), (0x2521, "2210"), (0x2522, "1220"), (0x2523, "2220"),
            (0x2524, "1011"), (0x2525, "1012"), (0x2526, "2011"), (0x2527, "1021"),
            (0x2528, "2021"), (0x2529, "2012"), (0x252A, "1022"), (0x252B, "2022"),
            (0x252C, "0111"), (0x252D, "0112"), (0x252E, "0211"), (0x252F, "0212"),
            (0x2530, "0121"), (0x2531, "0122"), (0x2532, "0221"), (0x2533, "0222"),
            (0x2534, "1101"), (0x2535, "1102"), (0x2536, "1201"), (0x2537, "1202"),
            (0x2538, "2101"), (0x2539, "2102"), (0x253A, "2201"), (0x253B, "2202"),
            (0x253C, "1111"), (0x253D, "1112"), (0x253E, "1211"), (0x253F, "1212"),
            (0x2540, "2111"), (0x2541, "1121"), (0x2542, "2121"), (0x2543, "2112"),
            (0x2544, "2211"), (0x2545, "1122"), (0x2546, "1221"), (0x2547, "2212"),
            (0x2548, "1222"), (0x2549, "2122"), (0x254A, "2221"), (0x254B, "2222"),
            (0x2550, "0303"), (0x2551, "3030"), (0x2552, "0310"), (0x2553, "0130"),
            (0x2554, "0330"), (0x2555, "0013"), (0x2556, "0031"), (0x2557, "0033"),
            (0x2558, "1300"), (0x2559, "3100"), (0x255A, "3300"), (0x255B, "1003"),
            (0x255C, "3001"), (0x255D, "3003"), (0x255E, "1310"), (0x255F, "3130"),
            (0x2560, "3330"), (0x2561, "1013"), (0x2562, "3031"), (0x2563, "3033"),
            (0x2564, "0313"), (0x2565, "0131"), (0x2566, "0333"), (0x2567, "1303"),
            (0x2568, "3101"), (0x2569, "3303"), (0x256A, "1313"), (0x256B, "3131"),
            (0x256C, "3333"),
            (0x2574, "0001"), (0x2575, "1000"), (0x2576, "0100"), (0x2577, "0010"),
            (0x2578, "0002"), (0x2579, "2000"), (0x257A, "0200"), (0x257B, "0020"),
            (0x257C, "0201"), (0x257D, "1020"), (0x257E, "0102"), (0x257F, "2010"),
        ]
        for (cp, s) in table {
            let d = s.map { UInt8(String($0))! }
            m[cp] = (d[0], d[1], d[2], d[3])
        }
        return m
    }()

    /// Draw `cp` into a w×h grayscale context. Returns false if not handled.
    static func draw(_ cp: UInt32, in ctx: CGContext, width w: Int, height h: Int, lineWidth: Int) -> Bool {
        let W = CGFloat(w), H = CGFloat(h)
        // Flip to y-down.
        ctx.translateBy(x: 0, y: H)
        ctx.scaleBy(x: 1, y: -1)
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.setStrokeColor(gray: 1, alpha: 1)
        ctx.setShouldAntialias(false)

        let light = CGFloat(max(1, lineWidth))
        let heavy = light * 2
        // Snap the centre so lines are crisp.
        let cx = ((W - light) / 2).rounded(.down)
        let cy = ((H - light) / 2).rounded(.down)

        func fill(_ x: CGFloat, _ y: CGFloat, _ ww: CGFloat, _ hh: CGFloat) { ctx.fill(CGRect(x: x, y: y, width: ww, height: hh)) }

        if let (u, r, d, l) = lines[cp] {
            // Geometry along each axis, in units of the light line width L, relative to the cell
            // centre line c: a light line spans [c-0.5L, c+0.5L]; double lines span
            // [c-1.5L, c-0.5L] and [c+0.5L, c+1.5L]. With cx/cy = c-0.5L these are all integers.
            let L = light
            let vx = cx, hy = cy // left/top edge of the centre light line
            let anyDoubleH = l == 3 || r == 3
            let anyDoubleV = u == 3 || d == 3

            func singleArm(_ dir: Int, _ wgt: UInt8) {
                let t = wgt == 2 ? heavy : L
                let off = ((L - t) / 2).rounded(.down)
                switch dir {
                case 0: fill(vx + off, 0, t, anyDoubleH ? hy : hy + L)                       // up
                case 2: let s0 = anyDoubleH ? hy + L : hy; fill(vx + off, s0, t, H - s0)       // down
                case 3: fill(0, hy + off, anyDoubleV ? vx : vx + L, t)                       // left
                default: let s0 = anyDoubleV ? vx + L : vx; fill(s0, hy + off, W - s0, t)    // right
                }
            }

            // A double arm is two parallel lines; each line's length at the joint depends on
            // whether the perpendicular arm on its side (inner corner) or the opposite side
            // (outer corner) is double.
            func doubleArm(_ dir: Int) {
                let vertical = dir == 0 || dir == 2
                for side in 0..<2 { // 0 = left/top line, 1 = right/bottom line
                    let sameSide: UInt8 = vertical ? (side == 0 ? l : r) : (side == 0 ? u : d)
                    let otherSide: UInt8 = vertical ? (side == 0 ? r : l) : (side == 0 ? d : u)
                    let c0 = vertical ? hy : vx          // c - 0.5L along the arm's axis
                    let pos = (vertical ? vx : hy) + (side == 0 ? -L : L)
                    let towardsStart = dir == 0 || dir == 3 // arm runs from the cell edge at 0 to the joint
                    var joint: CGFloat
                    if sameSide == 3 { joint = towardsStart ? c0 : c0 + L }
                    else if otherSide == 3 { joint = towardsStart ? c0 + 2 * L : c0 - L }
                    else { joint = towardsStart ? c0 + L : c0 }
                    let extent = vertical ? H : W
                    let a = towardsStart ? 0 : joint
                    let b = towardsStart ? joint : extent
                    if vertical { fill(pos, a, L, b - a) } else { fill(a, pos, b - a, L) }
                }
            }

            for (i, wgt) in [u, r, d, l].enumerated() where wgt != 0 {
                if wgt == 3 { doubleArm(i) } else { singleArm(i, wgt) }
            }
            return true
        }

        switch cp {
        // Dashed lines.
        case 0x2504, 0x2505, 0x2508, 0x2509, 0x254C, 0x254D:
            let n: CGFloat = (cp == 0x2504 || cp == 0x2505) ? 3 : (cp == 0x254C || cp == 0x254D) ? 2 : 4
            let t = (cp == 0x2505 || cp == 0x2509 || cp == 0x254D) ? heavy : light
            let seg = W / n
            for i in 0..<Int(n) { fill(CGFloat(i) * seg, cy + ((light - t) / 2).rounded(.down), (seg * 0.65).rounded(), t) }
        case 0x2506, 0x2507, 0x250A, 0x250B, 0x254E, 0x254F:
            let n: CGFloat = (cp == 0x2506 || cp == 0x2507) ? 3 : (cp == 0x254E || cp == 0x254F) ? 2 : 4
            let t = (cp == 0x2507 || cp == 0x250B || cp == 0x254F) ? heavy : light
            let seg = H / n
            for i in 0..<Int(n) { fill(cx + ((light - t) / 2).rounded(.down), CGFloat(i) * seg, t, (seg * 0.65).rounded()) }

        // Rounded corners.
        case 0x256D, 0x256E, 0x256F, 0x2570:
            ctx.setShouldAntialias(true)
            ctx.setLineWidth(light)
            let mx = cx + light / 2, my = cy + light / 2
            let r = min(W, H) / 2
            let p = CGMutablePath()
            switch cp {
            case 0x256D: p.move(to: CGPoint(x: mx, y: H)); p.addArc(tangent1End: CGPoint(x: mx, y: my), tangent2End: CGPoint(x: W, y: my), radius: r); p.addLine(to: CGPoint(x: W, y: my))
            case 0x256E: p.move(to: CGPoint(x: mx, y: H)); p.addArc(tangent1End: CGPoint(x: mx, y: my), tangent2End: CGPoint(x: 0, y: my), radius: r); p.addLine(to: CGPoint(x: 0, y: my))
            case 0x256F: p.move(to: CGPoint(x: mx, y: 0)); p.addArc(tangent1End: CGPoint(x: mx, y: my), tangent2End: CGPoint(x: 0, y: my), radius: r); p.addLine(to: CGPoint(x: 0, y: my))
            default:     p.move(to: CGPoint(x: mx, y: 0)); p.addArc(tangent1End: CGPoint(x: mx, y: my), tangent2End: CGPoint(x: W, y: my), radius: r); p.addLine(to: CGPoint(x: W, y: my))
            }
            ctx.addPath(p)
            ctx.strokePath()

        // Diagonals.
        case 0x2571, 0x2572, 0x2573:
            ctx.setShouldAntialias(true)
            ctx.setLineWidth(light)
            if cp != 0x2572 { ctx.move(to: CGPoint(x: W, y: 0)); ctx.addLine(to: CGPoint(x: 0, y: H)) }
            if cp != 0x2571 { ctx.move(to: CGPoint(x: 0, y: 0)); ctx.addLine(to: CGPoint(x: W, y: H)) }
            ctx.strokePath()

        // Block elements.
        case 0x2580: fill(0, 0, W, (H / 2).rounded())
        case 0x2581...0x2587:
            let eighths = CGFloat(cp - 0x2580)
            let hh = (H * eighths / 8).rounded()
            fill(0, H - hh, W, hh)
        case 0x2588: fill(0, 0, W, H)
        case 0x2589...0x258F:
            let eighths = CGFloat(8 - (cp - 0x2588))
            fill(0, 0, (W * eighths / 8).rounded(), H)
        case 0x2590: let x = (W / 2).rounded(); fill(x, 0, W - x, H)
        case 0x2591, 0x2592, 0x2593:
            let level: CGFloat = cp == 0x2591 ? 0.25 : cp == 0x2592 ? 0.5 : 0.75
            ctx.setFillColor(gray: level, alpha: 1)
            fill(0, 0, W, H)
        case 0x2594: fill(0, 0, W, (H / 8).rounded())
        case 0x2595: let ww = (W / 8).rounded(); fill(W - ww, 0, ww, H)
        case 0x2596...0x259F:
            let hw = (W / 2).rounded(), hh = (H / 2).rounded()
            // Quadrant bits: UL, UR, LL, LR
            let quads: [UInt32: (Bool, Bool, Bool, Bool)] = [
                0x2596: (false, false, true, false), 0x2597: (false, false, false, true),
                0x2598: (true, false, false, false), 0x2599: (true, false, true, true),
                0x259A: (true, false, false, true), 0x259B: (true, true, true, false),
                0x259C: (true, true, false, true), 0x259D: (false, true, false, false),
                0x259E: (false, true, true, false), 0x259F: (false, true, true, true),
            ]
            let q = quads[cp]!
            if q.0 { fill(0, 0, hw, hh) }
            if q.1 { fill(hw, 0, W - hw, hh) }
            if q.2 { fill(0, hh, hw, H - hh) }
            if q.3 { fill(hw, hh, W - hw, H - hh) }

        // Powerline.
        case 0xE0B0, 0xE0B2:
            ctx.setShouldAntialias(true)
            let p = CGMutablePath()
            // The flat side spans slightly past the cell so it's fully covered after antialiasing and
            // joins the neighboring segment without notches at the top and bottom.
            if cp == 0xE0B0 { p.addLines(between: [CGPoint(x: 0, y: -1), CGPoint(x: W, y: H / 2), CGPoint(x: 0, y: H + 1)]) }
            else { p.addLines(between: [CGPoint(x: W, y: -1), CGPoint(x: 0, y: H / 2), CGPoint(x: W, y: H + 1)]) }
            p.closeSubpath()
            ctx.addPath(p)
            ctx.fillPath()
        case 0xE0B1, 0xE0B3:
            ctx.setShouldAntialias(true)
            ctx.setLineWidth(light)
            if cp == 0xE0B1 { ctx.addLines(between: [CGPoint(x: 0, y: 0), CGPoint(x: W - light / 2, y: H / 2), CGPoint(x: 0, y: H)]) }
            else { ctx.addLines(between: [CGPoint(x: W, y: 0), CGPoint(x: light / 2, y: H / 2), CGPoint(x: W, y: H)]) }
            ctx.strokePath()
        case 0xE0B4, 0xE0B6:
            ctx.setShouldAntialias(true)
            if cp == 0xE0B4 { ctx.addEllipse(in: CGRect(x: -W, y: 0, width: W * 2, height: H)) }
            else { ctx.addEllipse(in: CGRect(x: 0, y: 0, width: W * 2, height: H)) }
            ctx.fillPath()
        default:
            return false
        }
        return true
    }
}
