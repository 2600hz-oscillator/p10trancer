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
    private var destination: MIDIEndpointRef = 0
    private var isStarted = false

    /// UniqueID for the virtual source. Persisted in UserDefaults
    /// so macOS's MIDI Studio recognises the iPad endpoint across
    /// re-launches by the same ID rather than treating each launch
    /// as a brand-new device (which is how it ends up "missing"
    /// from MIDI Studio — stale entries hide the live one).
    private static let uniqueIDKey = "p10e.midi.uniqueID"

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
            // macOS's MIDI Studio displays + caches endpoints by name
            // + uniqueID. We set every property the discovery path
            // looks at (Name, DisplayName, Manufacturer, Model) and
            // persist a per-install UniqueID so subsequent launches
            // present the SAME endpoint identity rather than churning
            // a new one each time (which is what made the device
            // disappear from MIDI Studio over time — stale entries).
            assignPersistentUniqueID(to: source)
            MIDIObjectSetStringProperty(source, kMIDIPropertyName, "P10 Entrancer" as CFString)
            MIDIObjectSetStringProperty(source, kMIDIPropertyDisplayName, "P10 Entrancer" as CFString)
            MIDIObjectSetStringProperty(source, kMIDIPropertyManufacturer, "P10 Entrancer" as CFString)
            MIDIObjectSetStringProperty(source, kMIDIPropertyModel, "P10 Entrancer" as CFString)
            createDestinationIfNeeded()
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

    /// Read (or mint + save) the per-install UniqueID and apply it to
    /// the given endpoint. macOS's MIDI Studio uses UniqueID as the
    /// identity key — same ID across launches means MIDI Studio
    /// recognises this endpoint as the same device and surfaces it
    /// in the saved configuration; a fresh ID every launch leaves
    /// orphan entries behind and can hide the live one.
    private func assignPersistentUniqueID(to endpoint: MIDIEndpointRef) {
        let defaults = UserDefaults.standard
        var id: Int32
        if defaults.object(forKey: Self.uniqueIDKey) != nil {
            id = Int32(truncatingIfNeeded: defaults.integer(forKey: Self.uniqueIDKey))
        } else {
            // Random 30-bit value to stay safely inside the signed
            // Int32 space CoreMIDI expects.
            id = Int32.random(in: 1...0x3FFF_FFFF)
            defaults.set(Int(id), forKey: Self.uniqueIDKey)
        }
        let status = MIDIObjectSetIntegerProperty(endpoint, kMIDIPropertyUniqueID, id)
        if status != noErr {
            P10Logger.log("[MIDIOutput] uniqueID set failed: \(status) (CoreMIDI may have assigned its own)")
        }
    }

    /// Create a paired virtual destination so the iPad presents both
    /// an OUT (source) and an IN (destination) to peers like macOS's
    /// MIDI Studio. Without an IN endpoint, some tools treat the
    /// device as "send-only" and omit it from device pickers entirely.
    /// We don't currently process inbound traffic on this destination
    /// — MIDIRouter handles that via its own input connections — so
    /// the readBlock is a no-op.
    private func createDestinationIfNeeded() {
        guard destination == 0 else { return }
        let status = MIDIDestinationCreateWithBlock(
            client,
            "P10 Entrancer" as CFString,
            &destination
        ) { _, _ in
            // No-op. Inbound MIDI handling lives in MIDIRouter; this
            // destination exists purely so the iPad publishes IN +
            // OUT endpoints together.
        }
        guard status == noErr else {
            P10Logger.log("[MIDIOutput] destination create failed: \(status)")
            return
        }
        MIDIObjectSetStringProperty(destination, kMIDIPropertyName, "P10 Entrancer" as CFString)
        MIDIObjectSetStringProperty(destination, kMIDIPropertyDisplayName, "P10 Entrancer" as CFString)
        MIDIObjectSetStringProperty(destination, kMIDIPropertyManufacturer, "P10 Entrancer" as CFString)
        MIDIObjectSetStringProperty(destination, kMIDIPropertyModel, "P10 Entrancer" as CFString)
        P10Logger.log("[MIDIOutput] virtual destination 'P10 Entrancer' published")
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
