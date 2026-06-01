import Foundation
import Combine

@MainActor
final class NTSCState: ObservableObject {
    /// Master enable for the analog/NTSC pass. Off by default — the NTSC
    /// encode→decode roundtrip imparts an analog look even at neutral
    /// knobs, and it's the expensive (2× oversample) stage, so it only
    /// runs when the user turns it on. Works in either output geometry.
    @Published var ntscEnabled: Bool = false
    @Published var chromaBoost: Float = 1.0
    @Published var lumaNoise: Float = 0.0
    @Published var chromaNoise: Float = 0.0
    @Published var hsyncWobble: Float = 0.0
    @Published var dropoutRate: Float = 0.0
    @Published var burstPhaseShift: Float = 0.0
    @Published var subcarrierDrift: Float = 0.0
    @Published var ycDelay: Float = 0.0
    @Published var combStrength: Float = 0.7
    @Published var lumaPeaking: Float = 0.0
}
