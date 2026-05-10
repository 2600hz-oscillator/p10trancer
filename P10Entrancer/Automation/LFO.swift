import Foundation
import Combine

/// Tempo divisions an LFO can run at relative to the master clock.
/// Indices 0...6 map to {1/16, 1/8, 1/4, 1/2, 1x, 2x, 4x}; 1x = one
/// full cycle per quarter note. The UI exposes this as a 7-position
/// slider.
enum LFORate: Int, CaseIterable, Codable, Identifiable {
    case sixteenth = 0
    case eighth = 1
    case quarter = 2
    case half = 3
    case one = 4
    case two = 5
    case four = 6

    var id: Int { rawValue }

    /// Cycles per quarter-note. Combined with ticksPerQuarter (24)
    /// gives ticksPerCycle = 24 / cyclesPerQuarter.
    var cyclesPerQuarter: Double {
        switch self {
        case .sixteenth: return 1.0 / 4
        case .eighth: return 1.0 / 2
        case .quarter: return 1.0
        case .half: return 2.0
        case .one: return 4.0     // 1x = one cycle per BAR (4 quarter notes)
        case .two: return 8.0
        case .four: return 16.0
        }
    }

    var displayLabel: String {
        switch self {
        case .sixteenth: return "1/16"
        case .eighth: return "1/8"
        case .quarter: return "1/4"
        case .half: return "1/2"
        case .one: return "1x"
        case .two: return "2x"
        case .four: return "4x"
        }
    }
}

/// Bipolar LFO output sample at the given phase (0...1) and morph
/// position (0=sine, 0.5=saw, 1=square). Crossfades between the three
/// pure shapes so the slider feels continuous. Output is in [-1, +1].
func lfoSample(phase: Double, morph: Float) -> Float {
    let p = phase - floor(phase)
    let sine = sin(p * .pi * 2.0)
    let saw = 2.0 * p - 1.0
    let square: Double = p < 0.5 ? 1.0 : -1.0
    let m = Double(max(0, min(1, morph)))
    let value: Double
    if m <= 0.5 {
        let t = m * 2.0
        value = sine * (1 - t) + saw * t
    } else {
        let t = (m - 0.5) * 2.0
        value = saw * (1 - t) + square * t
    }
    return Float(value)
}

/// Identifies one modulatable parameter on a pad / keyer / feedback.
/// `getBase` returns the user's current slider value; the LFO
/// computes `effective = base + sample * range * amount` and writes
/// it via `setEffective`. When the LFO is disabled or an assignment
/// is removed, the engine restores the base value once.
struct LFOTarget: Identifiable, Hashable {
    let id: String          // stable key for assignment persistence
    let displayName: String // shown in the assign picker
    let range: ClosedRange<Float>
    let getBase: () -> Float
    let setEffective: (Float) -> Void

    static func == (l: LFOTarget, r: LFOTarget) -> Bool { l.id == r.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// One assignment slot on an LFO. Up to 3 slots per LFO.
struct LFOAssignment: Codable, Equatable {
    /// Target id (matched against `LFOTarget.id`). Empty = unassigned.
    var targetID: String = ""
    /// 0...1 scaling factor for this slot's contribution.
    var amount: Float = 0.5
}

@MainActor
final class LFOState: ObservableObject {
    @Published var enabled: Bool = false
    /// 0=sine, 0.5=saw, 1=square (continuous crossfade between).
    @Published var morph: Float = 0
    @Published var rate: LFORate = .one
    /// Exactly 3 assignment slots. Empty `targetID` = inactive slot.
    @Published var assignments: [LFOAssignment] = [
        LFOAssignment(), LFOAssignment(), LFOAssignment()
    ]
    /// Phase accumulator, 0..1. Engine advances per tick when enabled.
    var phase: Double = 0
}

/// Owns all LFOs in the app, subscribes to the Transport's tick
/// publisher, evaluates each LFO once per tick, and writes the
/// modulated value to every active assignment's target.
///
/// Maintains its own snapshot of each target's pre-modulation "base"
/// so the LFO's contribution is additive (per the user's chosen
/// modulation model) and can be cleanly removed when the assignment
/// is cleared or the LFO is disabled.
@MainActor
final class LFOEngine: ObservableObject {
    /// One LFO per pad slot — 9 source pads + 2 keyers + 1 feedback.
    /// We key by a stable string id so future additions don't shift
    /// indices.
    @Published private(set) var lfos: [String: LFOState] = [:]

    private let transport: Transport
    private var cancellable: AnyCancellable?
    private var targetsByID: [String: LFOTarget] = [:]
    /// Targets currently being driven by ≥1 LFO assignment, with the
    /// base value snapshot so we can restore on release.
    private var liveTargets: [String: Float] = [:]

    init(transport: Transport) {
        self.transport = transport
        // No receive(on:) — both the publisher and the engine are
        // MainActor-bound and the timer hop already lands on main.
        // Synchronous delivery here is also what unit tests need.
        self.cancellable = transport.tickPublisher
            .sink { [weak self] _ in self?.tick() }
    }

    /// Re-publish the available targets for a pad/keyer/feedback. The
    /// engine indexes targets by id; assignments reference targets by
    /// id (so removing a pad's source doesn't crash an assignment, it
    /// just goes silent until a target reappears).
    func registerTargets(_ targets: [LFOTarget]) {
        for t in targets { targetsByID[t.id] = t }
    }

    func unregisterTargets(withIDs ids: [String]) {
        for id in ids { targetsByID.removeValue(forKey: id) }
    }

    /// Lookup or create the LFO state for a given slot. Slot keys:
    ///   pad-0..pad-8, keyer-0, keyer-1, feedback
    func lfo(for slotID: String) -> LFOState {
        if let existing = lfos[slotID] { return existing }
        let s = LFOState()
        lfos[slotID] = s
        return s
    }

    /// Available targets — used by the LFO sheet to populate the
    /// assign-target picker.
    var allTargets: [LFOTarget] {
        Array(targetsByID.values).sorted { $0.displayName < $1.displayName }
    }

    func target(id: String) -> LFOTarget? { targetsByID[id] }

    private func tick() {
        // First, gather the set of target ids that are currently
        // driven by any LFO assignment.
        var drivenIDs: Set<String> = []
        for (_, state) in lfos where state.enabled {
            for assign in state.assignments where !assign.targetID.isEmpty {
                drivenIDs.insert(assign.targetID)
            }
        }
        // Restore any target that's no longer driven (write the cached
        // base value back so removing an LFO returns the param to its
        // resting state).
        for id in liveTargets.keys where !drivenIDs.contains(id) {
            if let target = targetsByID[id], let base = liveTargets[id] {
                target.setEffective(base)
            }
            liveTargets.removeValue(forKey: id)
        }
        // Snapshot base for every newly-driven target so the LFO has
        // a stable centerpoint to swing around.
        for id in drivenIDs where liveTargets[id] == nil {
            if let target = targetsByID[id] {
                liveTargets[id] = target.getBase()
            }
        }
        // Advance each enabled LFO's phase by its per-tick increment,
        // sample its waveform, and accumulate the contribution from
        // every assignment into the target's effective value.
        let ticksPerQuarter: Double = 24
        var contribution: [String: Float] = [:] // sum of all LFO contribs per target
        for (_, state) in lfos where state.enabled {
            let cyclesPerTick = state.rate.cyclesPerQuarter / ticksPerQuarter
            state.phase = state.phase + cyclesPerTick
            if state.phase >= 1 { state.phase -= floor(state.phase) }
            let sample = lfoSample(phase: state.phase, morph: state.morph)
            for assign in state.assignments where !assign.targetID.isEmpty {
                guard let target = targetsByID[assign.targetID] else { continue }
                // Half the range so amount=1 swings ±50% of total
                // range from the base (full range would clip
                // immediately at base values near the ends).
                let span = (target.range.upperBound - target.range.lowerBound) * 0.5
                let delta = sample * assign.amount * span
                contribution[assign.targetID, default: 0] += delta
            }
        }
        for (id, delta) in contribution {
            guard let target = targetsByID[id], let base = liveTargets[id] else { continue }
            let effective = (base + delta).clamped(to: target.range)
            target.setEffective(effective)
        }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
