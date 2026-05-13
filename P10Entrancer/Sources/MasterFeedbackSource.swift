import Foundation
import Metal
import QuartzCore

@MainActor
final class MasterFeedbackSource: PadSource {
    let displayAspect: Float = 16.0 / 9.0
    private let mixerOffscreen: MasterMixerOffscreen

    init(mixerOffscreen: MasterMixerOffscreen) {
        self.mixerOffscreen = mixerOffscreen
    }

    var currentTexture: MTLTexture? {
        mixerOffscreen.currentOutputTexture
    }

    func tick(timestamp: CFTimeInterval) {}
}
