import Foundation
import Combine

/// X/Y joystick for macro-mapping. Two axes; each axis is bound to
/// any LFO-assignable parameter. Dragging the joystick writes the
/// mapped value into the assigned target via the same `setEffective`
/// channel an LFO would use. MIDI CC 70/71 round-trips X/Y so the
/// joystick is captured into automation takes.
///
/// Conflict note: if the same parameter is assigned to BOTH an LFO
/// and a joystick axis, the LFO will overwrite the joystick on every
/// tick (per-tick contribution computation). For now, pick one or the
/// other per target.
@MainActor
final class XYJoystickState: ObservableObject {
    /// Normalized X position, 0...1. 0.5 = center.
    @Published var x: Float = 0.5
    /// Normalized Y position, 0...1. 0.5 = center.
    @Published var y: Float = 0.5
    /// LFOTarget id assigned to the X axis. Empty = unassigned.
    @Published var xTargetID: String = ""
    /// LFOTarget id assigned to the Y axis. Empty = unassigned.
    @Published var yTargetID: String = ""

    private weak var engine: LFOEngine?
    private var cancellables = Set<AnyCancellable>()

    func attach(engine: LFOEngine) {
        self.engine = engine
        // Watch x / y / assignments and re-write effective values
        // whenever any of them change.
        $x.dropFirst().sink { [weak self] v in
            self?.writeAxis(targetID: self?.xTargetID ?? "", normalized: v)
        }.store(in: &cancellables)
        $y.dropFirst().sink { [weak self] v in
            self?.writeAxis(targetID: self?.yTargetID ?? "", normalized: v)
        }.store(in: &cancellables)
        $xTargetID.dropFirst().sink { [weak self] _ in
            self?.writeAxis(targetID: self?.xTargetID ?? "",
                            normalized: self?.x ?? 0.5)
        }.store(in: &cancellables)
        $yTargetID.dropFirst().sink { [weak self] _ in
            self?.writeAxis(targetID: self?.yTargetID ?? "",
                            normalized: self?.y ?? 0.5)
        }.store(in: &cancellables)
    }

    private func writeAxis(targetID: String, normalized: Float) {
        guard !targetID.isEmpty, let engine, let t = engine.target(id: targetID) else { return }
        let span = t.range.upperBound - t.range.lowerBound
        let v = t.range.lowerBound + max(0, min(1, normalized)) * span
        t.setEffective(v)
    }
}
