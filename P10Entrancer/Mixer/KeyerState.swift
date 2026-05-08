import Foundation
import Combine

enum KeyerKind: Int, CaseIterable, Identifiable {
    case chroma = 0
    case luma = 1

    var id: Int { rawValue }
    var displayName: String {
        switch self {
        case .chroma: return "Chroma"
        case .luma: return "Luma"
        }
    }
}

@MainActor
final class KeyerState: ObservableObject {
    @Published var isEnabled: Bool = false
    @Published var foregroundPadIndex: Int = 7
    @Published var backgroundPadIndex: Int = 8
    @Published var kind: KeyerKind = .chroma
    @Published var threshold: Float = 0.35
    @Published var softness: Float = 0.1
    @Published var keyColor: SIMD3<Float> = .init(0, 1, 0)
}
