import Foundation

/// Identifies an input source for a keyer/feedback unit. Lets those
/// "output pads" (KEYER1, KEYER2, FEEDBACK) reference each other or
/// any of the regular pads, instead of going through a regular pad
/// hosting a KeyerPadSource/FeedbackPadSource.
///
/// When a renderer reads a `.keyer` or `.feedback` reference, it sees
/// that unit's last-published output texture — naturally one frame
/// behind, which is exactly the right behavior for cycles.
enum SourceRef: Equatable, Codable {
    case pad(Int)        // 0..<PadSystem.padCount
    case keyer(Int)      // 0 (Keyer 1) or 1 (Keyer 2)
    case feedback        // single feedback unit (post-MVP refactor)

    var displayLabel: String {
        switch self {
        case .pad(let i): return "PAD \(i + 1)"
        case .keyer(let i): return "KEYER \(i + 1)"
        case .feedback: return "FEEDBACK"
        }
    }
}
