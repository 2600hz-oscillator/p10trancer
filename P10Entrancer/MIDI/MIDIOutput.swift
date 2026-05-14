import Foundation
import CoreMIDI

@MainActor
protocol MIDISink: AnyObject {
    func send(_ bytes: [UInt8])
}

@MainActor
final class MIDIOutput: MIDISink {
    static let shared = MIDIOutput()

    private var client: MIDIClientRef = 0
    private var source: MIDIEndpointRef = 0
    private var isStarted = false

    private init() {}

    func startIfNeeded() {
        guard !isStarted else { return }
        // Wake the CoreMIDI server before any client/source creation. Without
        // this, MIDISourceCreate can return -10844 (kMIDIServerStartErr) on a
        // cold start.
        _ = MIDIGetNumberOfDestinations()
        _ = MIDIGetNumberOfSources()

        // Enable Network MIDI Session so the iPad publishes itself via Bonjour
        // and shows up in macOS's MIDI Network Setup → Directory. Without
        // this, the iPad is invisible to the Mac's network MIDI peer
        // discovery; only the local USB-MIDI port is exposed (and that
        // doesn't carry the iPad's app-published virtual sources).
        let session = MIDINetworkSession.default()
        session.isEnabled = true
        session.connectionPolicy = .anyone
        P10Logger.log("[MIDIOutput] MIDINetworkSession enabled, policy = anyone, networkName = \(session.networkName)")

        attemptStart(retriesRemaining: 5)
    }

    private func attemptStart(retriesRemaining: Int) {
        if client == 0 {
            let clientStatus = MIDIClientCreate("p10e.midi.out.client" as CFString, nil, nil, &client)
            guard clientStatus == noErr else {
                P10Logger.log("[MIDIOutput] MIDIClientCreate failed: \(clientStatus)")
                return
            }
        }
        let sourceStatus = MIDISourceCreate(client, "P10 Entrancer" as CFString, &source)
        if sourceStatus == noErr {
            // Set explicit metadata. Some hosts only enumerate virtual sources
            // that have the standard properties populated.
            MIDIObjectSetIntegerProperty(source, kMIDIPropertyUniqueID, 0x70_31_30_45) // 'p10E'
            MIDIObjectSetStringProperty(source, kMIDIPropertyManufacturer, "P10 Entrancer" as CFString)
            MIDIObjectSetStringProperty(source, kMIDIPropertyModel, "P10 Entrancer Source" as CFString)
            isStarted = true
            P10Logger.log("[MIDIOutput] virtual source 'P10 Entrancer' published")
            return
        }
        P10Logger.log("[MIDIOutput] MIDISourceCreate failed: \(sourceStatus) (retries left: \(retriesRemaining))")
        guard retriesRemaining > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            Task { @MainActor in
                self?.attemptStart(retriesRemaining: retriesRemaining - 1)
            }
        }
    }

    private var sendCount: Int = 0

    /// Tap invoked on every outbound byte stream, before transmission.
    /// AutomationEngine uses this to capture user gestures during recording.
    var onSent: (([UInt8]) -> Void)?

    func send(_ bytes: [UInt8]) {
        onSent?(bytes)
        guard isStarted, source != 0, !bytes.isEmpty else { return }
        // Generously-sized backing buffer for MIDIPacketList.
        // The struct's inline `packet[1]` only formally holds 1 packet of up to
        // 256 bytes; we allocate 1KB to avoid any boundary edge cases.
        let bufferSize = 1024
        let storage = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 4)
        defer { storage.deallocate() }
        let listPtr = storage.assumingMemoryBound(to: MIDIPacketList.self)
        var packet = MIDIPacketListInit(listPtr)
        bytes.withUnsafeBufferPointer { buffer in
            packet = MIDIPacketListAdd(
                listPtr,
                bufferSize,
                packet,
                0, // immediate dispatch
                buffer.count,
                buffer.baseAddress!
            )
        }
        let status = MIDIReceived(source, listPtr)
        if status != noErr {
            P10Logger.log("[MIDIOutput] MIDIReceived failed: \(status)")
            return
        }
        sendCount += 1
        if sendCount <= 30 || sendCount % 50 == 0 {
            let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
            P10Logger.log("[MIDIOutput] sent #\(sendCount): \(hex)")
        }
    }
}
