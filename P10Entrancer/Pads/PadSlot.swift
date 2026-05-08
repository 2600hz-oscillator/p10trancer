import Metal

@MainActor
final class PadSlot {
    let index: Int
    var source: PadSource?
    let fxChain: FXChain

    init(index: Int, fxChain: FXChain) {
        self.index = index
        self.fxChain = fxChain
    }

    var texture: MTLTexture? {
        if fxChain.isAnyEnabled, let processed = fxChain.outputTexture {
            return processed
        }
        return source?.currentTexture
    }

    var aspect: Float { source?.displayAspect ?? (16.0 / 9.0) }

    var audioPlayer: PadAudioPlayer? {
        (source as? VideoFileSource)?.audioPlayer
    }

    func processFX(elapsedTime: Float) {
        guard let sourceTex = source?.currentTexture else { return }
        if fxChain.isAnyEnabled {
            fxChain.process(source: sourceTex, elapsedTime: elapsedTime)
        }
    }
}
