import Foundation
import CoreMIDI

@MainActor
final class MIDIRouter: ObservableObject {
    static let shared = MIDIRouter()

    private var client: MIDIClientRef = 0
    private var inputPort: MIDIPortRef = 0
    private var connectedSources: Set<MIDIEndpointRef> = []
    private var isStarted = false

    /// Names of MIDI sources we're currently subscribed to. Driven by
    /// `connectAllSources()`; the global settings UI watches this to
    /// render a "Connected devices" list.
    @Published private(set) var connectedDeviceNames: [String] = []

    /// Ring buffer of recent MIDI event descriptions for the live
    /// traffic view in global settings. Newest at index 0.
    @Published private(set) var recentEvents: [String] = []
    private static let recentEventsCap = 60

    private(set) var lastEventDescription: String = ""
    var onNoteOn: ((Int, Int) -> Void)?
    /// Called with (cc, value, channel). `channel` is 0-15 (MIDI ch 1-16).
    /// Receivers that don't care about channel can ignore the third arg.
    var onControlChange: ((Int, Int, Int) -> Void)?
    var onProgramChange: ((Int) -> Void)?
    /// Forwarded raw bytes for any non-real-time channel-voice message (note/cc/pc).
    /// Used by AutomationEngine to capture takes regardless of routing.
    var onChannelVoiceBytes: (([UInt8]) -> Void)?
    /// Real-Time bytes (0xF8 clock, 0xFA start, 0xFB continue, 0xFC stop).
    var onRealTime: ((UInt8) -> Void)?

    private init() {}

    func startIfNeeded() {
        guard !isStarted else { return }
        isStarted = true

        let createStatus = MIDIClientCreateWithBlock("p10e.midi.client" as CFString, &client) { _ in
            Task { @MainActor in
                MIDIRouter.shared.connectAllSources()
            }
        }
        guard createStatus == noErr else {
            print("[MIDIRouter] MIDIClientCreate failed: \(createStatus)")
            return
        }

        let portStatus = MIDIInputPortCreateWithBlock(client, "p10e.midi.in" as CFString, &inputPort) { packetListPtr, _ in
            MIDIRouter.handlePacketList(packetListPtr)
        }
        guard portStatus == noErr else {
            print("[MIDIRouter] MIDIInputPortCreate failed: \(portStatus)")
            return
        }

        connectAllSources()
        print("[MIDIRouter] started; sources: \(MIDIGetNumberOfSources())")
    }

    /// Unique ID of our own published virtual source. Skipped during connect
    /// so we don't echo our own emissions back into our own router (which
    /// would cause toggle-style PCs to flip state right back).
    private static let ownSourceUniqueID: Int32 = 0x70_31_30_45 // 'p10E'

    func connectAllSources() {
        let count = MIDIGetNumberOfSources()
        for i in 0..<count {
            let source = MIDIGetSource(i)
            guard source != 0, !connectedSources.contains(source) else { continue }
            if Self.uniqueID(source) == Self.ownSourceUniqueID {
                let name = Self.endpointName(source) ?? "?"
                P10Logger.log("[MIDIRouter] skipping own virtual source: \(name)")
                continue
            }
            let status = MIDIPortConnectSource(inputPort, source, nil)
            if status == noErr {
                connectedSources.insert(source)
                let name = Self.endpointName(source) ?? "?"
                P10Logger.log("[MIDIRouter] connected source: \(name)")
            } else {
                let name = Self.endpointName(source) ?? "?"
                P10Logger.log("[MIDIRouter] connect failed (\(status)): \(name)")
            }
        }
        refreshConnectedDeviceNames()
    }

    private func refreshConnectedDeviceNames() {
        connectedDeviceNames = connectedSources
            .compactMap { Self.endpointName($0) }
            .sorted()
    }

    private static func uniqueID(_ endpoint: MIDIEndpointRef) -> Int32 {
        var value: Int32 = 0
        let status = MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &value)
        return status == noErr ? value : 0
    }

    private static func endpointName(_ endpoint: MIDIEndpointRef) -> String? {
        var unmanagedName: Unmanaged<CFString>?
        let status = MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &unmanagedName)
        if status == noErr, let cf = unmanagedName?.takeRetainedValue() {
            return cf as String
        }
        return nil
    }

    nonisolated private static func handlePacketList(_ packetListPtr: UnsafePointer<MIDIPacketList>) {
        let packetList = packetListPtr.pointee
        var packet = packetList.packet
        for _ in 0..<packetList.numPackets {
            let length = Int(packet.length)
            withUnsafeBytes(of: packet.data) { rawBuffer in
                let bytes = Array(rawBuffer.prefix(length))
                Task { @MainActor in
                    MIDIRouter.shared.dispatch(bytes: bytes)
                }
            }
            packet = MIDIPacketNext(&packet).pointee
        }
    }

    private var receiveCount: Int = 0
    private var clockTickCount: Int = 0

    /// Inject a synthetic event from playback so it flows through the same
    /// dispatch path as a wire event. Used by AutomationEngine.
    func inject(bytes: [UInt8]) {
        dispatch(bytes: bytes)
    }

    private func dispatch(bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }

        // MIDI Real-Time bytes (0xF8..0xFF) may appear anywhere in the stream,
        // including interleaved inside a channel-voice message or bundled with
        // other bytes in one packet. Pull them out first; the remainder forms
        // (at most) one channel-voice message.
        var voiceBytes: [UInt8] = []
        voiceBytes.reserveCapacity(bytes.count)
        for byte in bytes {
            if byte >= 0xF8 {
                handleRealTime(byte)
            } else {
                voiceBytes.append(byte)
            }
        }
        guard !voiceBytes.isEmpty else { return }

        let status = voiceBytes[0] & 0xF0
        let channel = Int(voiceBytes[0] & 0x0F)

        receiveCount += 1
        if receiveCount <= 30 || receiveCount % 50 == 0 {
            let hex = voiceBytes.map { String(format: "%02X", $0) }.joined(separator: " ")
            P10Logger.log("[MIDIRouter] received #\(receiveCount): \(hex)")
        }

        switch status {
        case 0x80, 0x90, 0xB0, 0xC0:
            onChannelVoiceBytes?(voiceBytes)
        default: break
        }

        switch status {
        case 0x90 where voiceBytes.count >= 3 && voiceBytes[2] > 0:
            let note = Int(voiceBytes[1])
            let velocity = Int(voiceBytes[2])
            recordEvent("ch\(channel + 1) note \(note) vel \(velocity)")
            onNoteOn?(note, velocity)
        case 0xB0 where voiceBytes.count >= 3:
            let cc = Int(voiceBytes[1])
            let value = Int(voiceBytes[2])
            recordEvent("ch\(channel + 1) cc \(cc) val \(value)")
            onControlChange?(cc, value, channel)
        case 0xC0 where voiceBytes.count >= 2:
            let program = Int(voiceBytes[1])
            recordEvent("ch\(channel + 1) pc \(program)")
            onProgramChange?(program)
        default:
            break
        }
    }

    private func recordEvent(_ description: String) {
        lastEventDescription = description
        recentEvents.insert(description, at: 0)
        if recentEvents.count > Self.recentEventsCap {
            recentEvents.removeLast(recentEvents.count - Self.recentEventsCap)
        }
    }

    private func handleRealTime(_ status: UInt8) {
        switch status {
        case 0xF8:
            clockTickCount &+= 1
            if clockTickCount <= 24 || clockTickCount % 96 == 0 {
                P10Logger.log("[MIDIRouter] clock tick #\(clockTickCount)")
            }
        case 0xFA:
            P10Logger.log("[MIDIRouter] MIDI Start")
        case 0xFB:
            P10Logger.log("[MIDIRouter] MIDI Continue")
        case 0xFC:
            P10Logger.log("[MIDIRouter] MIDI Stop")
        default: break
        }
        onRealTime?(status)
    }
}
