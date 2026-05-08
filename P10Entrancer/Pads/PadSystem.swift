import Foundation
import QuartzCore

@MainActor
final class PadSystem {
    static let padCount = 9
    let pads: [PadSlot]

    init() {
        var slots: [PadSlot] = []
        for i in 0..<Self.padCount {
            let chain = PadSystem.makeFXChain()
            slots.append(PadSlot(index: i, fxChain: chain))
        }
        self.pads = slots
    }

    func tick(timestamp: CFTimeInterval) {
        let elapsed = Float(timestamp)
        for pad in pads {
            pad.source?.tick(timestamp: timestamp)
            pad.processFX(elapsedTime: elapsed)
        }
    }

    func setSource(_ source: PadSource?, at index: Int) {
        guard pads.indices.contains(index) else { return }
        pads[index].source = source
    }

    private static func makeFXChain() -> FXChain {
        var effects: [FXEffect] = []
        if let blur = try? BlurEffect() { effects.append(blur) }
        if let chroma = try? ChromaDistortEffect() { effects.append(chroma) }
        if let yuv = try? YUVPhaserEffect() { effects.append(yuv) }
        if let luma = try? LumaPhaserEffect() { effects.append(luma) }
        if let edge = try? EdgeEnhanceEffect() { effects.append(edge) }
        if let feedback = try? FeedbackEffect() { effects.append(feedback) }
        return FXChain(effects: effects)
    }
}
