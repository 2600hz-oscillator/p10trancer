import Foundation
import Combine

@MainActor
final class NTSCState: ObservableObject {
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
