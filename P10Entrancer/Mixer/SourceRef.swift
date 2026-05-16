import Foundation

/// Identifies an input source for one of the atomic FX pads
/// (KEYER / FEEDBACK / XYZ). Lets those FX pads reference each other
/// or any of the nine source pads. Each FX type is a single instance,
/// so there is no index on .keyer/.feedback/.xyz.
///
/// When a renderer reads a `.keyer` / `.feedback` / `.xyz` reference,
/// it sees that unit's last-published output texture — naturally one
/// frame behind, which is the right behavior for cycles.
enum SourceRef: Equatable, Codable {
    case pad(Int)
    case keyer
    case feedback
    case xyz

    var displayLabel: String {
        switch self {
        case .pad(let i): return "PAD \(i + 1)"
        case .keyer: return "KEYER"
        case .feedback: return "FEEDBACK"
        case .xyz: return "XYZ"
        }
    }
}
