import Foundation
import Metal

@MainActor
final class FXChain {
    let effects: [FXEffect]
    private(set) var outputTexture: MTLTexture?

    private let context: MetalContext
    private var workA: MTLTexture?
    private var workB: MTLTexture?
    private var prevFrame: MTLTexture?
    private var lastSize: (Int, Int) = (0, 0)

    init(effects: [FXEffect], context: MetalContext = .shared) {
        self.effects = effects
        self.context = context
    }

    var isAnyEnabled: Bool {
        effects.contains { $0.isEnabled }
    }

    func process(source: MTLTexture, elapsedTime: Float) {
        let enabled = effects.filter { $0.isEnabled }
        guard !enabled.isEmpty else {
            outputTexture = source
            return
        }

        let w = source.width
        let h = source.height
        if (w, h) != lastSize {
            workA = makeIntermediate(width: w, height: h)
            workB = makeIntermediate(width: w, height: h)
            prevFrame = makeIntermediate(width: w, height: h)
            lastSize = (w, h)
        }
        guard let workA = workA, let workB = workB, let prevFrame = prevFrame else {
            outputTexture = source
            return
        }

        guard let cmd = context.commandQueue.makeCommandBuffer() else {
            outputTexture = source
            return
        }

        var read: MTLTexture = source
        var write: MTLTexture = workA
        var nextWrite: MTLTexture = workB

        for effect in enabled {
            encodePass(
                cmd: cmd,
                input: read,
                previousFrame: prevFrame,
                output: write,
                effect: effect,
                elapsedTime: elapsedTime
            )
            read = write
            (write, nextWrite) = (nextWrite, write)
        }

        if let copy = cmd.makeBlitCommandEncoder() {
            copy.copy(from: read, to: prevFrame)
            copy.endEncoding()
        }

        cmd.commit()
        outputTexture = read
    }

    private func encodePass(
        cmd: MTLCommandBuffer,
        input: MTLTexture,
        previousFrame: MTLTexture,
        output: MTLTexture,
        effect: FXEffect,
        elapsedTime: Float
    ) {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = output
        descriptor.colorAttachments[0].loadAction = .dontCare
        descriptor.colorAttachments[0].storeAction = .store
        guard let encoder = cmd.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        effect.encode(
            input: input,
            previousFrame: previousFrame,
            output: output,
            encoder: encoder,
            elapsedTime: elapsedTime
        )
        encoder.endEncoding()
    }

    private func makeIntermediate(width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .private
        return context.device.makeTexture(descriptor: descriptor)
    }
}
