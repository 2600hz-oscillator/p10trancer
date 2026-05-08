import Foundation
import Metal

@MainActor
final class NTSCPipeline {
    private(set) var outputTexture: MTLTexture?

    private let context: MetalContext
    private let state: NTSCState

    private let encodePipeline: MTLRenderPipelineState
    private let glitchPipeline: MTLRenderPipelineState
    private let decodePipeline: MTLRenderPipelineState

    private var compositeA: MTLTexture?
    private var compositeB: MTLTexture?
    private var lastInputSize: (Int, Int) = (0, 0)
    private let oversample = 2

    init(state: NTSCState, context: MetalContext = .shared) throws {
        self.context = context
        self.state = state

        let encodeDesc = MTLRenderPipelineDescriptor()
        encodeDesc.vertexFunction = context.library.makeFunction(name: "ntscVertex")
        encodeDesc.fragmentFunction = context.library.makeFunction(name: "ntscEncodeFragment")
        encodeDesc.colorAttachments[0].pixelFormat = .rgba16Float
        self.encodePipeline = try context.device.makeRenderPipelineState(descriptor: encodeDesc)

        let glitchDesc = MTLRenderPipelineDescriptor()
        glitchDesc.vertexFunction = context.library.makeFunction(name: "ntscVertex")
        glitchDesc.fragmentFunction = context.library.makeFunction(name: "ntscGlitchFragment")
        glitchDesc.colorAttachments[0].pixelFormat = .rgba16Float
        self.glitchPipeline = try context.device.makeRenderPipelineState(descriptor: glitchDesc)

        let decodeDesc = MTLRenderPipelineDescriptor()
        decodeDesc.vertexFunction = context.library.makeFunction(name: "ntscVertex")
        decodeDesc.fragmentFunction = context.library.makeFunction(name: "ntscDecodeFragment")
        decodeDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        self.decodePipeline = try context.device.makeRenderPipelineState(descriptor: decodeDesc)
    }

    func render(input: MTLTexture, elapsedTime: Float) {
        let outW = input.width
        let outH = input.height
        let compW = outW * oversample
        let compH = outH

        if (compW, compH) != lastInputSize {
            compositeA = makeComposite(width: compW, height: compH)
            compositeB = makeComposite(width: compW, height: compH)
            outputTexture = makeOutput(width: outW, height: outH)
            lastInputSize = (compW, compH)
        }
        guard let compositeA = compositeA, let compositeB = compositeB, let outputTexture = outputTexture else {
            return
        }

        guard let cmd = context.commandQueue.makeCommandBuffer() else { return }

        encodePass(cmd: cmd, input: input, output: compositeA, elapsedTime: elapsedTime, compositeWidth: Float(compW))
        glitchPass(cmd: cmd, input: compositeA, output: compositeB, elapsedTime: elapsedTime, compositeSize: (compW, compH))
        decodePass(cmd: cmd, input: compositeB, output: outputTexture, compositeWidth: Float(compW))

        cmd.commit()
    }

    private func encodePass(cmd: MTLCommandBuffer, input: MTLTexture, output: MTLTexture, elapsedTime: Float, compositeWidth: Float) {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = output
        descriptor.colorAttachments[0].loadAction = .dontCare
        descriptor.colorAttachments[0].storeAction = .store
        guard let encoder = cmd.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        var params = NTSCEncodeParamsBuffer(
            compositeWidth: compositeWidth,
            burstPhaseShift: state.burstPhaseShift,
            subcarrierDrift: state.subcarrierDrift,
            time: elapsedTime,
            ycDelay: state.ycDelay,
            _pad0: 0, _pad1: 0, _pad2: 0
        )

        encoder.setRenderPipelineState(encodePipeline)
        encoder.setFragmentTexture(input, index: 0)
        encoder.setFragmentBytes(&params, length: MemoryLayout<NTSCEncodeParamsBuffer>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    private func glitchPass(cmd: MTLCommandBuffer, input: MTLTexture, output: MTLTexture, elapsedTime: Float, compositeSize: (Int, Int)) {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = output
        descriptor.colorAttachments[0].loadAction = .dontCare
        descriptor.colorAttachments[0].storeAction = .store
        guard let encoder = cmd.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        var params = NTSCGlitchParamsBuffer(
            chromaBoost: state.chromaBoost,
            lumaNoise: state.lumaNoise,
            chromaNoise: state.chromaNoise,
            hsyncWobble: state.hsyncWobble,
            dropoutRate: state.dropoutRate,
            dropoutSeed: elapsedTime,
            compositeWidth: Float(compositeSize.0),
            compositeHeight: Float(compositeSize.1)
        )

        encoder.setRenderPipelineState(glitchPipeline)
        encoder.setFragmentTexture(input, index: 0)
        encoder.setFragmentBytes(&params, length: MemoryLayout<NTSCGlitchParamsBuffer>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    private func decodePass(cmd: MTLCommandBuffer, input: MTLTexture, output: MTLTexture, compositeWidth: Float) {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = output
        descriptor.colorAttachments[0].loadAction = .dontCare
        descriptor.colorAttachments[0].storeAction = .store
        guard let encoder = cmd.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        var params = NTSCDecodeParamsBuffer(
            compositeWidth: compositeWidth,
            combStrength: state.combStrength,
            lumaPeaking: state.lumaPeaking,
            _pad0: 0
        )

        encoder.setRenderPipelineState(decodePipeline)
        encoder.setFragmentTexture(input, index: 0)
        encoder.setFragmentBytes(&params, length: MemoryLayout<NTSCDecodeParamsBuffer>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    private func makeComposite(width: Int, height: Int) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .renderTarget]
        desc.storageMode = .private
        return context.device.makeTexture(descriptor: desc)
    }

    private func makeOutput(width: Int, height: Int) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .renderTarget]
        desc.storageMode = .private
        return context.device.makeTexture(descriptor: desc)
    }
}

private struct NTSCEncodeParamsBuffer {
    var compositeWidth: Float
    var burstPhaseShift: Float
    var subcarrierDrift: Float
    var time: Float
    var ycDelay: Float
    var _pad0: Float
    var _pad1: Float
    var _pad2: Float
}

private struct NTSCGlitchParamsBuffer {
    var chromaBoost: Float
    var lumaNoise: Float
    var chromaNoise: Float
    var hsyncWobble: Float
    var dropoutRate: Float
    var dropoutSeed: Float
    var compositeWidth: Float
    var compositeHeight: Float
}

private struct NTSCDecodeParamsBuffer {
    var compositeWidth: Float
    var combStrength: Float
    var lumaPeaking: Float
    var _pad0: Float
}
