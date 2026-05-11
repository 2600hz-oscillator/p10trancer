import XCTest
@testable import P10Entrancer

/// Behavioral tests for the keyer math. The actual production
/// pipeline runs in Metal; this test file ports the same algorithm
/// to Swift so we can rapidly evaluate edge cases under unit-test
/// conditions without paying GPU readback cost. The reference here
/// MUST stay byte-identical to `P10Entrancer/Shaders/Keyer.metal` —
/// if the shader changes, mirror it.
@MainActor
final class KeyerTests: XCTestCase {

    // MARK: - Reference implementation (mirrors Keyer.metal)

    struct RGB { var r: Float; var g: Float; var b: Float }
    struct HSV { var h: Float; var s: Float; var v: Float }

    static func rgbToHsv(_ c: RGB) -> HSV {
        let maxc = max(c.r, max(c.g, c.b))
        let minc = min(c.r, min(c.g, c.b))
        let v = maxc
        let d = maxc - minc
        let s: Float = maxc > 0.0001 ? d / maxc : 0
        var h: Float = 0
        if d > 0.0001 {
            if maxc == c.r {
                h = (c.g - c.b) / d
                if h < 0 { h += 6 }
            } else if maxc == c.g {
                h = (c.b - c.r) / d + 2
            } else {
                h = (c.r - c.g) / d + 4
            }
            h /= 6
        }
        return HSV(h: h, s: s, v: v)
    }

    static func hsvToRgb(_ hsv: HSV) -> RGB {
        let h6 = hsv.h * 6
        let c2 = hsv.v * hsv.s
        let x2 = c2 * (1 - abs(h6.truncatingRemainder(dividingBy: 2) - 1))
        var rgb: (Float, Float, Float)
        if h6 < 1      { rgb = (c2, x2, 0) }
        else if h6 < 2 { rgb = (x2, c2, 0) }
        else if h6 < 3 { rgb = (0, c2, x2) }
        else if h6 < 4 { rgb = (0, x2, c2) }
        else if h6 < 5 { rgb = (x2, 0, c2) }
        else           { rgb = (c2, 0, x2) }
        let m = hsv.v - c2
        return RGB(r: rgb.0 + m, g: rgb.1 + m, b: rgb.2 + m)
    }

    static func hueDistance(_ a: Float, _ b: Float) -> Float {
        let d = abs(a - b)
        return min(d, 1 - d)
    }

    static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = max(0, min(1, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    static func luma(_ c: RGB) -> Float {
        0.299 * c.r + 0.587 * c.g + 0.114 * c.b
    }

    /// Run the keyer fragment for one pixel pair. Returns the
    /// composited RGB result.
    static func key(fg: RGB, bg: RGB, keyer: KeyerState) -> RGB {
        let tol = max(keyer.threshold, 0)
        let soft = max(keyer.softness, 0.001)
        var fgOut = fg
        var alpha: Float = 1

        if keyer.kind == .chroma {
            let fgHSV = rgbToHsv(fg)
            let keyHSV = rgbToHsv(RGB(r: keyer.keyColor.x,
                                       g: keyer.keyColor.y,
                                       b: keyer.keyColor.z))
            let hd = hueDistance(fgHSV.h, keyHSV.h)
            let satGate = smoothstep(0.04, 0.18, fgHSV.s)
            let tolH = tol * 0.5
            let softH = max(soft * 0.5, 0.001)
            let hueAlpha = smoothstep(tolH, tolH + softH, hd)
            alpha = (1 - satGate) * 1 + satGate * hueAlpha
            if keyer.spill > 0.001 {
                let pull = (1 - alpha) * keyer.spill
                let s2 = fgHSV.s * (1 - pull)
                let despilled = hsvToRgb(HSV(h: fgHSV.h, s: s2, v: fgHSV.v))
                fgOut = RGB(r: max(0, min(1, despilled.r)),
                            g: max(0, min(1, despilled.g)),
                            b: max(0, min(1, despilled.b)))
            }
        } else {
            let l = luma(fg)
            alpha = smoothstep(tol - soft, tol + soft, l)
        }

        if keyer.invert { alpha = 1 - alpha }

        return RGB(r: bg.r * (1 - alpha) + fgOut.r * alpha,
                   g: bg.g * (1 - alpha) + fgOut.g * alpha,
                   b: bg.b * (1 - alpha) + fgOut.b * alpha)
    }

    // MARK: - Chroma key tests

    func test_chroma_pure_key_replaced_by_background() {
        let keyer = KeyerState()
        keyer.kind = .chroma
        keyer.keyColor = SIMD3(0, 1, 0)
        keyer.threshold = 0.1
        keyer.softness = 0.05
        keyer.spill = 0
        let out = Self.key(fg: RGB(r: 0, g: 1, b: 0),
                           bg: RGB(r: 1, g: 0, b: 0),
                           keyer: keyer)
        XCTAssertEqual(out.r, 1.0, accuracy: 0.01)
        XCTAssertEqual(out.g, 0.0, accuracy: 0.01)
        XCTAssertEqual(out.b, 0.0, accuracy: 0.01)
    }

    func test_chroma_unrelated_color_passes_through() {
        let keyer = KeyerState()
        keyer.kind = .chroma
        keyer.keyColor = SIMD3(0, 1, 0)
        keyer.threshold = 0.1
        keyer.softness = 0.05
        keyer.spill = 0
        // Flesh tone is far enough in chrominance from green.
        let out = Self.key(fg: RGB(r: 1.0, g: 0.85, b: 0.7),
                           bg: RGB(r: 1, g: 0, b: 0),
                           keyer: keyer)
        XCTAssertEqual(out.r, 1.0, accuracy: 0.02)
        XCTAssertEqual(out.g, 0.85, accuracy: 0.02)
        XCTAssertEqual(out.b, 0.70, accuracy: 0.02)
    }

    /// HSV hue is brightness-invariant — a dim green and a bright
    /// green sit at the same hue (1/3 of the wheel). So both should
    /// key out cleanly against the SAME key color setting, no luma
    /// gate fiddling required. This is the major win over both
    /// RGB-Euclidean and YCbCr keying.
    func test_chroma_dark_green_keys_out_same_as_bright() {
        let keyer = KeyerState()
        keyer.kind = .chroma
        keyer.keyColor = SIMD3(0, 1, 0)
        keyer.threshold = 0.1
        keyer.softness = 0.1
        keyer.spill = 0
        let outBright = Self.key(fg: RGB(r: 0, g: 1.0, b: 0),
                                  bg: RGB(r: 1, g: 0, b: 0),
                                  keyer: keyer)
        let outDim = Self.key(fg: RGB(r: 0, g: 0.4, b: 0),
                               bg: RGB(r: 1, g: 0, b: 0),
                               keyer: keyer)
        XCTAssertGreaterThan(outBright.r, 0.9, "bright green keys out")
        XCTAssertGreaterThan(outDim.r,    0.9, "dim green keys out at same setting")
    }

    /// Gray pixels (no hue) should NOT be keyed out by chroma even
    /// if their hue happens to compute to the key's hue (which can
    /// happen at H=0 since gray defaults to red hue). The saturation
    /// gate handles this.
    func test_chroma_gray_pixel_is_not_keyed() {
        let keyer = KeyerState()
        keyer.kind = .chroma
        keyer.keyColor = SIMD3(1, 0, 0)  // red key
        keyer.threshold = 0.1
        keyer.softness = 0.1
        keyer.spill = 0
        let grayPixel = RGB(r: 0.5, g: 0.5, b: 0.5)
        let out = Self.key(fg: grayPixel,
                           bg: RGB(r: 0, g: 0, b: 1),
                           keyer: keyer)
        XCTAssertEqual(out.r, 0.5, accuracy: 0.05,
            "saturation gate should keep gray pixels as foreground")
        XCTAssertEqual(out.b, 0.5, accuracy: 0.05,
            "blue from BG should NOT show — gray FG passes through")
    }

    func test_chroma_spill_pulls_edge_pixel_toward_neutral() {
        let keyer = KeyerState()
        keyer.kind = .chroma
        keyer.keyColor = SIMD3(0, 1, 0)
        // Make the alpha land mid-ramp so spill kicks in noticeably.
        keyer.threshold = 0.10
        keyer.softness = 0.20
        keyer.spill = 1.0
        // A pixel that's a green-tinted face. Without spill it would
        // composite over BG with a green halo. With spill=1 the
        // chroma should be pulled toward neutral.
        let tintedFace = RGB(r: 0.7, g: 1.0, b: 0.5)
        let bg = RGB(r: 0.2, g: 0.2, b: 0.2)
        let withSpill = Self.key(fg: tintedFace, bg: bg, keyer: keyer)
        keyer.spill = 0
        let withoutSpill = Self.key(fg: tintedFace, bg: bg, keyer: keyer)
        // The green channel should be CLOSER to the other channels
        // with spill on than off (because chroma was pulled neutral).
        let gapWith = withSpill.g - (withSpill.r + withSpill.b) / 2
        let gapWithout = withoutSpill.g - (withoutSpill.r + withoutSpill.b) / 2
        XCTAssertLessThan(gapWith, gapWithout,
            "spill should narrow the green-vs-other-channels gap; got with=\(gapWith) without=\(gapWithout)")
    }

    // MARK: - Luma key tests

    func test_luma_dark_pixel_replaced_by_background() {
        let keyer = KeyerState()
        keyer.kind = .luma
        keyer.threshold = 0.5
        keyer.softness = 0.05
        let out = Self.key(fg: RGB(r: 0, g: 0, b: 0),
                           bg: RGB(r: 0, g: 0, b: 1),
                           keyer: keyer)
        XCTAssertEqual(out.b, 1.0, accuracy: 0.01,
            "dark pixel should let background through")
    }

    func test_luma_bright_pixel_passes_through() {
        let keyer = KeyerState()
        keyer.kind = .luma
        keyer.threshold = 0.5
        keyer.softness = 0.05
        let out = Self.key(fg: RGB(r: 1, g: 1, b: 1),
                           bg: RGB(r: 0, g: 0, b: 1),
                           keyer: keyer)
        XCTAssertEqual(out.r, 1.0, accuracy: 0.01)
        XCTAssertEqual(out.g, 1.0, accuracy: 0.01)
        XCTAssertEqual(out.b, 1.0, accuracy: 0.01)
    }

    func test_luma_invert_flips_alpha() {
        let keyer = KeyerState()
        keyer.kind = .luma
        keyer.threshold = 0.5
        keyer.softness = 0.05
        keyer.invert = true
        // With invert: dark pixel now keeps FG (black), bright pixel
        // shows BG.
        let dark = Self.key(fg: RGB(r: 0, g: 0, b: 0),
                            bg: RGB(r: 0, g: 0, b: 1),
                            keyer: keyer)
        let bright = Self.key(fg: RGB(r: 1, g: 1, b: 1),
                              bg: RGB(r: 0, g: 0, b: 1),
                              keyer: keyer)
        XCTAssertEqual(dark.b, 0.0, accuracy: 0.01)
        XCTAssertEqual(bright.b, 1.0, accuracy: 0.01)
    }

    func test_luma_smooth_band_mid_alpha_at_threshold() {
        let keyer = KeyerState()
        keyer.kind = .luma
        keyer.threshold = 0.5
        keyer.softness = 0.05
        // Pixel at exactly the threshold should be midway between FG
        // and BG (alpha ≈ 0.5).
        let midGray = RGB(r: 0.5, g: 0.5, b: 0.5)
        let bg = RGB(r: 0, g: 0, b: 0)
        let out = Self.key(fg: midGray, bg: bg, keyer: keyer)
        XCTAssertEqual(out.r, 0.25, accuracy: 0.05,
            "mid-luma pixel through luma key should land near 50% mix")
    }

    // MARK: - HSV round-trip

    func test_hsv_round_trip_preserves_saturated_colors() {
        // The HSV gray case isn't perfectly reversible (gray loses
        // hue info), so only test saturated colors.
        for (r, g, b) in [(0.2, 0.4, 0.7), (1.0, 0.0, 0.0), (0.0, 1.0, 0.4), (1.0, 0.5, 0.0)] {
            let original = RGB(r: Float(r), g: Float(g), b: Float(b))
            let hsv = Self.rgbToHsv(original)
            let back = Self.hsvToRgb(hsv)
            XCTAssertEqual(back.r, original.r, accuracy: 0.01)
            XCTAssertEqual(back.g, original.g, accuracy: 0.01)
            XCTAssertEqual(back.b, original.b, accuracy: 0.01)
        }
    }
}
