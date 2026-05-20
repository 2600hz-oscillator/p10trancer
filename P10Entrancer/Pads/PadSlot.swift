import Metal

/// How a pad's source is mapped onto the master output canvas when
/// the pad is routed to a channel.
///
/// - letterbox: preserve the source's aspect ratio; pad with black
///   bars on the axis that doesn't match the canvas.
/// - fill: preserve the source's aspect ratio; crop the axis that
///   doesn't fit so the source covers the entire canvas.
///
/// The setting is per-pad and persists across mode flips (HD ↔ NTSC).
enum PadFillMode: String, Codable {
    case letterbox
    case fill
}

@MainActor
final class PadSlot: ObservableObject {
    let index: Int
    /// Published so SwiftUI views that observe the PadSlot re-render
    /// when the source kind changes — critical because `audioPlayer`
    /// is a computed property reading off `source`. Without this, the
    /// per-pad volume slider / mute icon / VU meter keep their
    /// @ObservedObject binding to the OLD audioPlayer when the user
    /// reassigns the pad (e.g. switching a video pad to an instrument),
    /// so mute / volume / VU stop responding to the new sound.
    @Published var source: PadSource?
    let fxChain: FXChain
    /// Aspect-handling mode used when this pad is routed to CH1/CH2.
    /// Defaults to letterbox so users never see distorted content
    /// the first time a non-canvas-aspect source is routed.
    @Published var fillMode: PadFillMode = .letterbox

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
        if let v = source as? VideoFileSource     { return v.audioPlayer }
        if let c = source as? CameraSource        { return c.audioPlayer }
        if let b = source as? BuiltInCameraSource { return b.audioPlayer }
        if let i = source as? InstrumentSource    { return i.audioPlayer }
        if let e = source as? ACIDKICKSource       { return e.audioPlayer }
        return nil
    }

    func processFX(elapsedTime: Float) {
        guard let sourceTex = source?.currentTexture else { return }
        if fxChain.isAnyEnabled {
            fxChain.process(source: sourceTex, elapsedTime: elapsedTime)
        }
    }
}
