import XCTest
import Metal
@testable import P10Entrancer

/// Visual-regression tests for the Metal render passes. Renders deterministic
/// synthetic inputs through a SINGLE shader pass into an offscreen .shared
/// texture (readable via getBytes on both simulator and Apple-GPU devices),
/// then asserts sampled pixels against computed expectations within a small
/// tolerance (the shaders use half/fp16 + linear sampling, so exact equality
/// would be flaky). This locks in the per-pad normalization geometry (the
/// step-5 headline) + the composite endpoint/crossfade behavior.
///
/// Scope: only single passes with explicit params. Does NOT cover the full
/// MasterMixerOffscreen.render (live pad textures, feedback history, post FX)
/// or anything time-driven (visualizers, NTSC).
@MainActor
final class MetalVRTTests: XCTestCase {

    private let ctx = MetalContext.shared

    // Mirror structs — MUST stay byte-identical to the shader-side structs.
    private struct NormalizeParams { var canvasAspect: Float; var fillMode: Int32; var _p0: Float = 0; var _p1: Float = 0 }
    private struct MixerParams {
        var kind: Int32; var position: Float
        var keyR: Float; var keyG: Float; var keyB: Float
        var keyThreshold: Float; var keySoftness: Float
        var canvasAspect: Float; var ch1FillMode: Int32; var ch2FillMode: Int32
        var _p0: Float = 0; var _p1: Float = 0
    }

    func test_param_struct_layouts_match_shaders() {
        // Guard: if a shader struct gains a field, this fails loudly instead of
        // silently feeding mis-aligned setFragmentBytes.
        XCTAssertEqual(MemoryLayout<NormalizeParams>.size, 16)
        XCTAssertEqual(MemoryLayout<MixerParams>.size, 48)
    }

    // MARK: - Harness

    private func makeInput(width w: Int, height h: Int, pixels: [UInt32]) -> MTLTexture {
        precondition(pixels.count == w * h)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.shaderRead]; d.storageMode = .shared
        let tex = ctx.device.makeTexture(descriptor: d)!
        pixels.withUnsafeBytes { tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                                             withBytes: $0.baseAddress!, bytesPerRow: w * 4) }
        return tex
    }

    private func makeSolid(width w: Int, height h: Int, _ argb: UInt32) -> MTLTexture {
        makeInput(width: w, height: h, pixels: [UInt32](repeating: argb, count: w * h))
    }

    private func makeTarget(width w: Int, height h: Int) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.shaderRead, .renderTarget]; d.storageMode = .shared
        return ctx.device.makeTexture(descriptor: d)!
    }

    private func runPass<P>(_ pipeline: MTLRenderPipelineState, inputs: [MTLTexture],
                            params: P, into target: MTLTexture) {
        let cmd = ctx.commandQueue.makeCommandBuffer()!
        let desc = MTLRenderPassDescriptor()
        desc.colorAttachments[0].texture = target
        desc.colorAttachments[0].loadAction = .clear
        desc.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        desc.colorAttachments[0].storeAction = .store
        let e = cmd.makeRenderCommandEncoder(descriptor: desc)!
        e.setRenderPipelineState(pipeline)
        for (i, t) in inputs.enumerated() { e.setFragmentTexture(t, index: i) }
        var p = params
        e.setFragmentBytes(&p, length: MemoryLayout<P>.size, index: 0)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        e.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()   // MUST wait before reading a .shared target.
    }

    /// (r,g,b) 0..255 at a pixel. Texture is bgra8Unorm so bytes are B,G,R,A.
    private func rgb(_ tex: MTLTexture, _ x: Int, _ y: Int) -> (Int, Int, Int) {
        let w = tex.width, h = tex.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes {
            tex.getBytes($0.baseAddress!, bytesPerRow: w * 4,
                         from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        let i = (y * w + x) * 4
        return (Int(bytes[i + 2]), Int(bytes[i + 1]), Int(bytes[i]))
    }

    private func assertColor(_ tex: MTLTexture, _ x: Int, _ y: Int,
                             _ r: Int, _ g: Int, _ b: Int, tol: Int = 4,
                             _ msg: String = "", file: StaticString = #filePath, line: UInt = #line) {
        let (pr, pg, pb) = rgb(tex, x, y)
        XCTAssertEqual(pr, r, accuracy: tol, "R @\(x),\(y) \(msg)", file: file, line: line)
        XCTAssertEqual(pg, g, accuracy: tol, "G @\(x),\(y) \(msg)", file: file, line: line)
        XCTAssertEqual(pb, b, accuracy: tol, "B @\(x),\(y) \(msg)", file: file, line: line)
    }

    private func normalizePipeline() throws -> MTLRenderPipelineState {
        try ctx.makePipeline(vertex: "mixerVertex", fragment: "normalizeFragment", pixelFormat: .bgra8Unorm)
    }
    private func mixerPipeline() throws -> MTLRenderPipelineState {
        try ctx.makePipeline(vertex: "mixerVertex", fragment: "mixerFragment", pixelFormat: .bgra8Unorm)
    }

    // MARK: - Normalization (step-5 headline)

    func test_normalize_fill_covers_whole_canvas() throws {
        let red: UInt32 = 0xFFFF0000
        let src = makeSolid(width: 64, height: 64, red)         // 1:1 source
        let target = makeTarget(width: 160, height: 90)          // 16:9 canvas
        runPass(try normalizePipeline(), inputs: [src],
                params: NormalizeParams(canvasAspect: 16.0 / 9.0, fillMode: 1), into: target)
        // Fill (cover-crop) a solid source → entire frame is the source color.
        assertColor(target, 80, 45, 255, 0, 0, "center fill")
        assertColor(target, 4, 45, 255, 0, 0, "left edge fill")
        assertColor(target, 156, 45, 255, 0, 0, "right edge fill")
    }

    func test_normalize_letterbox_pillarboxes_a_square_into_16x9() throws {
        let red: UInt32 = 0xFFFF0000
        let src = makeSolid(width: 64, height: 64, red)
        let target = makeTarget(width: 160, height: 90)
        runPass(try normalizePipeline(), inputs: [src],
                params: NormalizeParams(canvasAspect: 16.0 / 9.0, fillMode: 0), into: target)
        // Letterbox a 1:1 into 16:9 → red center column, black pillars L/R.
        assertColor(target, 80, 45, 255, 0, 0, "center content")
        assertColor(target, 2, 45, 0, 0, 0, "left pillar is real black")
        assertColor(target, 158, 45, 0, 0, 0, "right pillar is real black")
    }

    func test_normalize_letterbox_into_4x3() throws {
        let green: UInt32 = 0xFF00FF00
        let src = makeSolid(width: 64, height: 64, green)
        let target = makeTarget(width: 120, height: 90)          // 4:3 canvas
        runPass(try normalizePipeline(), inputs: [src],
                params: NormalizeParams(canvasAspect: 4.0 / 3.0, fillMode: 0), into: target)
        assertColor(target, 60, 45, 0, 255, 0, "center content")
        assertColor(target, 2, 45, 0, 0, 0, "left pillar black")
    }

    // MARK: - Composite

    func test_mixer_endpoints_are_pure_channels() throws {
        let red = makeSolid(width: 160, height: 90, 0xFFFF0000)
        let blue = makeSolid(width: 160, height: 90, 0xFF0000FF)
        let target = makeTarget(width: 160, height: 90)
        let base = MixerParams(kind: 0, position: 0, keyR: 0, keyG: 1, keyB: 0,
                               keyThreshold: 0.35, keySoftness: 0.1,
                               canvasAspect: 16.0 / 9.0, ch1FillMode: 1, ch2FillMode: 1)
        // position 0 → pure CH1 (red)
        var p0 = base; p0.position = 0
        runPass(try mixerPipeline(), inputs: [red, blue], params: p0, into: target)
        assertColor(target, 80, 45, 255, 0, 0, "p=0 is pure CH1")
        // position 1 → pure CH2 (blue)
        var p1 = base; p1.position = 1
        runPass(try mixerPipeline(), inputs: [red, blue], params: p1, into: target)
        assertColor(target, 80, 45, 0, 0, 255, "p=1 is pure CH2")
    }

    func test_mixer_crossfade_midpoint_blends() throws {
        let red = makeSolid(width: 160, height: 90, 0xFFFF0000)
        let blue = makeSolid(width: 160, height: 90, 0xFF0000FF)
        let target = makeTarget(width: 160, height: 90)
        let p = MixerParams(kind: 0, position: 0.5, keyR: 0, keyG: 1, keyB: 0,
                            keyThreshold: 0.35, keySoftness: 0.1,
                            canvasAspect: 16.0 / 9.0, ch1FillMode: 1, ch2FillMode: 1)
        runPass(try mixerPipeline(), inputs: [red, blue], params: p, into: target)
        // Crossfade of solid red + solid blue at 0.5 → ~half red, ~half blue,
        // no green. Blur of a constant field stays constant. Loose tolerance.
        let (r, g, b) = rgb(target, 80, 45)
        XCTAssertGreaterThan(r, 90); XCTAssertLessThan(r, 165)
        XCTAssertGreaterThan(b, 90); XCTAssertLessThan(b, 165)
        XCTAssertLessThan(g, 20, "no green should appear in a red/blue crossfade")
    }
}
