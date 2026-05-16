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
    /// Resolver for `fxslot-N` slot IDs → the underlying FX-unit
    /// slot ID (`keyer-N` / `feedback` / `xyz-N`). Set once by
    /// AppState; lets the slot LFO follow whichever FX type is
    /// currently in that slot.
    var fxSlotResolver: ((Int) -> String?)?

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
    ///   pad-0..pad-8, keyer, feedback, xyz, macro-0, macro-1
    func lfo(for slotID: String) -> LFOState {
        if let existing = lfos[slotID] { return existing }
        let s = LFOState()
        lfos[slotID] = s
        return s
    }

    /// Targets a given LFO slot is allowed to modulate:
    ///   - pad-N → only that pad's targets (volume + its FX params)
    ///   - keyer-N → only that keyer's params
    ///   - feedback → only the feedback unit's params
    ///   - macro-N → everything, including the master mixer position
    ///   - any other → empty
    /// Per-pad LFOs are scoped so the user can't accidentally hook a
    /// pad LFO into a different pad's params; macros are the single
    /// place position-style global modulation lives.
    func availableTargets(forSlot slotID: String) -> [LFOTarget] {
        if slotID.hasPrefix("macro-") {
            return Array(targetsByID.values).sorted { $0.displayName < $1.displayName }
        }
        // FX-slot LFOs delegate to whatever FX unit is currently
        // assigned to that slot. The fxSlotResolver hands back a
        // keyer-N / feedback / xyz-N slot ID; we recurse to resolve.
        if slotID.hasPrefix("fxslot-"),
           let i = Int(slotID.dropFirst("fxslot-".count)) {
            guard let underlying = fxSlotResolver?(i) else { return [] }
            return availableTargets(forSlot: underlying)
        }
        let prefix: String
        if slotID == "feedback" {
            prefix = "feedback."
        } else if slotID == "keyer" {
            prefix = "keyer."
        } else if slotID == "xyz" {
            prefix = "xyz."
        } else if slotID.hasPrefix("pad-") {
            // Pad slot IDs come in two shapes:
            //   pad-N             — LFO 1 (legacy/default)
            //   pad-N-lfo-K       — LFO K+1 on the same pad
            // Both should resolve to the same `pad.N.*` target set
            // so all three LFOs on an instrument pad can sweep the
            // same params.
            let suffix = String(slotID.dropFirst("pad-".count))
            let idxToken = suffix.split(separator: "-").first.map(String.init) ?? suffix
            guard let i = Int(idxToken) else { return [] }
            prefix = "pad.\(i)."
        } else {
            return []
        }
        return targetsByID.values
            .filter { $0.id.hasPrefix(prefix) }
            .sorted { $0.displayName < $1.displayName }
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
        //
        // Contribution uses a blend model rather than ±half-range
        // additive: at amount=1 the param is fully driven across its
        // full range by the LFO regardless of the base value (so a
        // base near 0 still produces a full 0→1→0 sweep instead of
        // clipping at the floor). amount=0 leaves the base alone;
        // intermediate values smoothly blend between base and the
        // LFO's full-range output.
        //
        //   unipolar  = (sample + 1) / 2                  ∈ [0,1]
        //   lfoFull   = lerp(range.lower, range.upper, unipolar)
        //   delta     = amount × (lfoFull - base)
        //   effective = base + Σ delta  (clamped to range)
        let ticksPerQuarter: Double = 24
        var contribution: [String: Float] = [:] // sum of all LFO contribs per target
        for (_, state) in lfos where state.enabled {
            let cyclesPerTick = state.rate.cyclesPerQuarter / ticksPerQuarter
            state.phase = state.phase + cyclesPerTick
            if state.phase >= 1 { state.phase -= floor(state.phase) }
            let sample = lfoSample(phase: state.phase, morph: state.morph)
            let unipolar = (sample + 1) * 0.5
            for assign in state.assignments where !assign.targetID.isEmpty {
                guard let target = targetsByID[assign.targetID],
                      let base = liveTargets[assign.targetID] else { continue }
                let span = target.range.upperBound - target.range.lowerBound
                let lfoFull = target.range.lowerBound + unipolar * span
                let delta = assign.amount * (lfoFull - base)
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
