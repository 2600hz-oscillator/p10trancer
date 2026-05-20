import Foundation
import Combine

/// Output post-processing applied when the user is in HD 720p mode.
/// Mirror of NTSCState but for clean digital output — no analog video
/// artifacts, just color grading + bloom. Every knob's default is the
/// identity transform: with these values the output is byte-identical
/// to the master mixer's raw image.
@MainActor
final class HDPostState: ObservableObject {
    @Published var gamma: Float = 1.0           // 0.5 … 2.5
    @Published var contrast: Float = 1.0        // 0.5 … 2.0
    @Published var saturation: Float = 1.0      // 0 … 2
    @Published var brightness: Float = 0.0      // -0.5 … +0.5
    @Published var bloom: Float = 0.0           // 0 … 1
    @Published var bloomThresh: Float = 0.75    // 0 … 1
}
