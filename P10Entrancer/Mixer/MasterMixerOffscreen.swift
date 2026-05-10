import Foundation
import Metal

@MainActor
final class MasterMixerOffscreen: FrameRenderer {
    private(set) var outputTexture: MTLTexture?

    private let context = MetalContext.shared
    private let pads: PadSystem
    private let mixer: MixerState
    private let keyers: [KeyerRenderer]
    private let feedbacks: [FeedbackRenderer]
    private let ntscPipeline: NTSCPipeline
    private let pipeline: MTLRenderPipelineState
    weak var recorder: MixerRecorder?

    private var lastSize: (Int, Int) = (0, 0)
    private var renderTexture: MTLTexture?

    init(pads: PadSystem, mixer: MixerState, keyers: [KeyerRenderer], feedbacks: [FeedbackRenderer], ntscPipeline: NTSCPipeline) throws {
        self.pads = pads
        self.mixer = mixer
        self.keyers = keyers
        self.feedbacks = feedbacks
        self.ntscPipeline = ntscPipeline
        self.pipeline = try context.makePipeline(
            vertex: "mixerVertex",
            fragment: "mixerFragment",
            pixelFormat: .bgra8Unorm
        )
        // Wire the source resolvers AFTER all renderers exist so the
        // graph can resolve cycles (keyer → keyer, feedback → keyer)
        // by reading each unit's last-frame outputTexture.
        let resolver: (SourceRef) -> MTLTexture? = { [weak self] ref in
            guard let self else { return nil }
            switch ref {
            case .pad(let i):
                guard self.pads.pads.indices.contains(i) else { return nil }
                return self.pads.pads[i].texture
            case .keyer(let i):
                guard self.keyers.indices.contains(i) else { return nil }
                return self.keyers[i].outputTexture
            case .feedback:
                return self.feedbacks.first?.outputTexture
            }
        }
        for k in keyers { k.sourceResolver = resolver }
        for f in feedbacks { f.sourceResolver = resolver }
    }

    var currentOutputTexture: MTLTexture? {
        if mixer.outputMode == .ntsc4_3, let ntsc = ntscPipeline.outputTexture {
            return ntsc
        }
        return outputTexture
    }

    func render(frameIndex: UInt64, elapsedTime: CFTimeInterval) {
        // Fixed order: feedbacks first (so a keyer pad that sources a feedback
        // gets fresh data), then keyers. Self-references through pads still
        // work via 1-frame feedback because each renderer publishes a stable
        // outputTexture pointer that's read on subsequent frames.
        for feedback in feedbacks { feedback.render() }
        for keyer in keyers { keyer.render() }

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

        var params = MixerParamsBuffer(
            kind: Int32(mixer.transition.rawValue),
            position: mixer.position,
            keyR: mixer.keyColor.x,
            keyG: mixer.keyColor.y,
            keyB: mixer.keyColor.z,
            keyThreshold: mixer.keyThreshold,
            keySoftness: mixer.keySoftness,
            _pad: 0
        )

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(ch1Tex, index: 0)
        encoder.setFragmentTexture(ch2Tex, index: 1)
        encoder.setFragmentBytes(&params, length: MemoryLayout<MixerParamsBuffer>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        cmd.commit()

        if mixer.outputMode == .ntsc4_3 {
            ntscPipeline.render(input: target, elapsedTime: Float(elapsedTime))
        }

        if let recorder, recorder.isRecording, let captureTex = currentOutputTexture {
            recorder.captureFrame(from: captureTex, elapsedTime: elapsedTime)
        }
    }

    private func textureForChannel(_ source: ChannelSource) -> MTLTexture? {
        switch source {
        case .pad(let index):
            guard pads.pads.indices.contains(index) else { return nil }
            return pads.pads[index].texture
        case .keyer(let i):
            guard keyers.indices.contains(i) else { return nil }
            return keyers[i].outputTexture
        case .feedback(let i):
            guard feedbacks.indices.contains(i) else { return nil }
            return feedbacks[i].outputTexture
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
    var _pad: Float
}
