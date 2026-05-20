import Foundation
import Metal

@MainActor
final class MasterMixerOffscreen: FrameRenderer {
    private(set) var outputTexture: MTLTexture?

    private let context = MetalContext.shared
    private let pads: PadSystem
    private let mixer: MixerState
    let keyer: KeyerRenderer
    let feedback: FeedbackRenderer
    let xyz: XYZRenderer
    private let ntscPipeline: NTSCPipeline
    private let hdPostPipeline: HDPostPipeline
    private let pipeline: MTLRenderPipelineState
    weak var recorder: MixerRecorder?

    private var lastSize: (Int, Int) = (0, 0)
    private var renderTexture: MTLTexture?

    init(pads: PadSystem,
         mixer: MixerState,
         keyer: KeyerRenderer,
         feedback: FeedbackRenderer,
         xyz: XYZRenderer,
         ntscPipeline: NTSCPipeline,
         hdPostPipeline: HDPostPipeline) throws {
        self.pads = pads
        self.mixer = mixer
        self.keyer = keyer
        self.feedback = feedback
        self.xyz = xyz
        self.ntscPipeline = ntscPipeline
        self.hdPostPipeline = hdPostPipeline
        self.pipeline = try context.makePipeline(
            vertex: "mixerVertex",
            fragment: "mixerFragment",
            pixelFormat: .bgra8Unorm
        )
        // Wire the source resolvers AFTER all renderers exist so the
        // graph can resolve cycles (keyer → keyer, feedback → keyer,
        // xyz → keyer, etc.) by reading each unit's last-frame
        // outputTexture.
        let resolver: (SourceRef) -> MTLTexture? = { [weak self] ref in
            guard let self else { return nil }
            switch ref {
            case .pad(let i):
                guard self.pads.pads.indices.contains(i) else { return nil }
                return self.pads.pads[i].texture
            case .keyer:
                return self.keyer.outputTexture
            case .feedback:
                return self.feedback.outputTexture
            case .xyz:
                return self.xyz.outputTexture
            }
        }
        keyer.sourceResolver = resolver
        feedback.sourceResolver = resolver
        xyz.sourceResolver = resolver
    }

    var currentOutputTexture: MTLTexture? {
        switch mixer.outputMode {
        case .ntsc4_3:
            return ntscPipeline.outputTexture ?? outputTexture
        case .hd720p:
            return hdPostPipeline.outputTexture ?? outputTexture
        }
    }

    func render(frameIndex: UInt64, elapsedTime: CFTimeInterval) {
        // Fixed order: feedback first (so a keyer that sources the
        // feedback gets fresh data), then keyer, then xyz. Self-references
        // through pads still work via 1-frame feedback because each
        // renderer publishes a stable outputTexture pointer.
        feedback.render()
        keyer.render()
        xyz.render()

        let canvasSize = mixer.outputMode.canvasSize
        if (canvasSize.width, canvasSize.height) != lastSize {
            renderTexture = makeRenderTexture(width: canvasSize.width, height: canvasSize.height)
            lastSize = (canvasSize.width, canvasSize.height)
        }
        outputTexture = renderTexture
        guard let target = renderTexture else { return }

        guard let cmd = context.commandQueue.makeCommandBuffer() else { return }
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = target
        descriptor.colorAttachments[0].loadAction = .dontCare
        descriptor.colorAttachments[0].storeAction = .store
        guard let encoder = cmd.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        let blank = context.blankTexture
        let ch1Tex = textureForChannel(mixer.ch1Source) ?? blank
        let ch2Tex = textureForChannel(mixer.ch2Source) ?? blank

        let canvasAspect = Float(canvasSize.width) / Float(max(canvasSize.height, 1))
        var params = MixerParamsBuffer(
            kind: Int32(mixer.transition.rawValue),
            position: mixer.position,
            keyR: mixer.keyColor.x,
            keyG: mixer.keyColor.y,
            keyB: mixer.keyColor.z,
            keyThreshold: mixer.keyThreshold,
            keySoftness: mixer.keySoftness,
            canvasAspect: canvasAspect,
            ch1FillMode: fillModeFor(mixer.ch1Source),
            ch2FillMode: fillModeFor(mixer.ch2Source),
            _pad0: 0,
            _pad1: 0
        )

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(ch1Tex, index: 0)
        encoder.setFragmentTexture(ch2Tex, index: 1)
        encoder.setFragmentBytes(&params, length: MemoryLayout<MixerParamsBuffer>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        cmd.commit()

        switch mixer.outputMode {
        case .ntsc4_3:
            ntscPipeline.render(input: target, elapsedTime: Float(elapsedTime))
        case .hd720p:
            hdPostPipeline.render(input: target)
        }

        if let recorder, recorder.isRecording, let captureTex = currentOutputTexture {
            recorder.captureFrame(from: captureTex, elapsedTime: elapsedTime)
        }
    }

    /// Pick the fill mode that should apply when sampling this
    /// channel's source. .pad reads the pad's own `fillMode`; FX
    /// channel sources letterbox so the user always sees the FX's
    /// full output rather than a cropped slice.
    private func fillModeFor(_ source: ChannelSource) -> Int32 {
        switch source {
        case .pad(let i):
            guard pads.pads.indices.contains(i) else { return 0 }
            return pads.pads[i].fillMode == .fill ? 1 : 0
        case .keyer, .feedback, .xyz:
            return 0
        }
    }

    private func textureForChannel(_ source: ChannelSource) -> MTLTexture? {
        switch source {
        case .pad(let index):
            guard pads.pads.indices.contains(index) else { return nil }
            return pads.pads[index].texture
        case .keyer:
            return keyer.outputTexture
        case .feedback:
            return feedback.outputTexture
        case .xyz:
            return xyz.outputTexture
        }
    }

    private func makeRenderTexture(width: Int, height: Int) -> MTLTexture? {
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

private struct MixerParamsBuffer {
    var kind: Int32
    var position: Float
    var keyR: Float
    var keyG: Float
    var keyB: Float
    var keyThreshold: Float
    var keySoftness: Float
    var canvasAspect: Float
    var ch1FillMode: Int32
    var ch2FillMode: Int32
    var _pad0: Float
    var _pad1: Float
}
