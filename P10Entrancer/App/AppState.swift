import Foundation
import AVFoundation
import Combine

@MainActor
final class AppState {
    static let shared = AppState()

    let pads = PadSystem()
    let mixer = MixerState()
    let keyerState = KeyerState()
    let keyerRenderer: KeyerRenderer
    let ntscState = NTSCState()
    let ntscPipeline: NTSCPipeline
    let masterMixerOffscreen: MasterMixerOffscreen
    let midiBindings: MIDIBindings
    let midiOutputBindings: MIDIOutputBindings
    let automation: AutomationEngine
    let thermalMonitor: ThermalMonitor
    let screenshotCapturer: ScreenshotCapturer
    let recorder: MixerRecorder
    let liveRecordings: LiveRecordingsStore

    private let deviceManager = CameraDeviceManager()
    private var builtInSystem: BuiltInCameraSystem?
    private var savedVideoSourceForPad3: PadSource?
    private var started = false
    private var cancellables = Set<AnyCancellable>()

    private init() {
        let pads = self.pads
        let mixer = self.mixer
        let keyerState = self.keyerState
        let ntscState = self.ntscState

        self.keyerRenderer = try! KeyerRenderer(pads: pads, keyer: keyerState)
        self.ntscPipeline = try! NTSCPipeline(state: ntscState)
        self.masterMixerOffscreen = try! MasterMixerOffscreen(
            pads: pads,
            mixer: mixer,
            keyer: self.keyerRenderer,
            ntscPipeline: self.ntscPipeline
        )

        let recorder = MixerRecorder()
        self.midiBindings = MIDIBindings(
            mixer: mixer,
            pads: pads,
            keyer: keyerState,
            ntsc: ntscState,
            recorder: recorder
        )
        self.midiOutputBindings = MIDIOutputBindings(
            mixer: mixer,
            pads: pads,
            keyer: keyerState,
            ntsc: ntscState
        )
        self.midiBindings.output = self.midiOutputBindings
        self.automation = AutomationEngine()
        self.thermalMonitor = ThermalMonitor(pads: pads)
        self.screenshotCapturer = ScreenshotCapturer()
        self.recorder = recorder
        self.liveRecordings = LiveRecordingsStore(pads: pads, mixer: mixer)
        self.masterMixerOffscreen.recorder = self.recorder
        self.recorder.onFinish = { [weak self] url in
            guard let self else { return }
            self.liveRecordings.insert(url: url)
        }

        RenderEngine.shared.register(self.masterMixerOffscreen)
    }

    func startIfNeeded() {
        guard !started else { return }
        started = true
        P10Logger.log("[AppState] startIfNeeded — Phase 10a")
        AudioEngine.shared.startIfNeeded()
        midiBindings.attach(to: MIDIRouter.shared)
        MIDIRouter.shared.startIfNeeded()
        MIDIOutput.shared.startIfNeeded()
        midiOutputBindings.attach(sink: MIDIOutput.shared)
        automation.attach(router: MIDIRouter.shared, output: MIDIOutput.shared)
        let existingSent = MIDIOutput.shared.onSent
        MIDIOutput.shared.onSent = { [weak self] bytes in
            existingSent?(bytes)
            self?.automation.captureOutbound(bytes)
        }
        // Self-test: have our own input router subscribe to our newly-published
        // virtual source, so when MIDIOutput emits we'll see the events log
        // through MIDIRouter (proving the source is broadcasting). The
        // mute-during-inbound guard prevents echo loops.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            Task { @MainActor in
                MIDIRouter.shared.connectAllSources()
            }
        }
        loadVideoAssets()
        Task { await self.attachCamerasIfPermitted() }
        deviceManager.onExternalDevicesChange = { [weak self] devices in
            self?.applyExternalDevice(devices.first)
        }
        applyExternalDevice(deviceManager.externalDevices.first)
        RenderEngine.shared.start()
        screenshotCapturer.start()
        wireAudioRouting()
    }

    private func wireAudioRouting() {
        Publishers.CombineLatest(mixer.$ch1Source, mixer.$ch2Source)
            .sink { [weak self] _, _ in
                self?.applyAudioRouting()
            }
            .store(in: &cancellables)
        keyerState.$foregroundPadIndex
            .combineLatest(keyerState.$isEnabled)
            .sink { [weak self] _, _ in
                self?.applyAudioRouting()
            }
            .store(in: &cancellables)
        applyAudioRouting()
    }

    func applyAudioRouting() {
        var routed = Set<Int>()
        for source in [mixer.ch1Source, mixer.ch2Source] {
            switch source {
            case .pad(let i): routed.insert(i)
            case .keyer:
                if keyerState.isEnabled {
                    routed.insert(keyerState.foregroundPadIndex)
                }
            }
        }
        for (i, pad) in pads.pads.enumerated() {
            pad.audioPlayer?.setRouted(routed.contains(i))
        }
    }

    private func loadVideoAssets() {
        var found = 0
        for i in 0..<PadSystem.padCount {
            let resource = "pad\(i + 1)"
            if let url = Bundle.main.url(forResource: resource, withExtension: "mp4") {
                pads.setSource(VideoFileSource(url: url), at: i)
                found += 1
            } else {
                print("[loadVideoAssets] missing bundled resource: \(resource).mp4")
            }
        }
        print("[loadVideoAssets] loaded \(found)/\(PadSystem.padCount) pad sources")
    }

    private func attachCamerasIfPermitted() async {
        let granted = await CameraDeviceManager.requestCameraAccess()
        guard granted else {
            print("[AppState] camera access denied")
            return
        }
        if let system = BuiltInCameraSystem() {
            builtInSystem = system
            if let back = system.backSource {
                pads.setSource(back, at: 0)
            }
            if let front = system.frontSource {
                pads.setSource(front, at: 1)
            }
        } else if let back = CameraDeviceManager.backCameraDevice(),
                  let cam = CameraSource(device: back, label: "back-fallback") {
            pads.setSource(cam, at: 0)
        }
    }

    func setMasterFeedbackSource(at index: Int) {
        pads.setSource(MasterFeedbackSource(mixerOffscreen: masterMixerOffscreen), at: index)
        P10Logger.log("[AppState] pad \(index + 1) source → MasterFeedback")
    }

    func reloadVideoSource(at index: Int) {
        let resource = "pad\(index + 1)"
        if let url = Bundle.main.url(forResource: resource, withExtension: "mp4") {
            pads.setSource(VideoFileSource(url: url), at: index)
            P10Logger.log("[AppState] pad \(index + 1) source → \(resource).mp4")
        }
    }

    func loadUserVideo(from sourceURL: URL, at index: Int) {
        P10Logger.log("[AppState] loadUserVideo called: \(sourceURL.path) → pad \(index + 1)")
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let userDir = docs.appendingPathComponent("UserVideos", isDirectory: true)
        try? FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)

        let needsScopedAccess = sourceURL.startAccessingSecurityScopedResource()
        defer { if needsScopedAccess { sourceURL.stopAccessingSecurityScopedResource() } }
        P10Logger.log("[AppState] scoped access: \(needsScopedAccess)")

        let fileName = sourceURL.lastPathComponent
        let dest = userDir.appendingPathComponent(fileName)
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: sourceURL, to: dest)
            let attrs = try FileManager.default.attributesOfItem(atPath: dest.path)
            P10Logger.log("[AppState] copied OK, size=\(attrs[.size] ?? 0)")
        } catch {
            P10Logger.log("[AppState] copy user video failed: \(error)")
            return
        }
        pads.setSource(VideoFileSource(url: dest), at: index)
        P10Logger.log("[AppState] pad \(index + 1) source → user file \(fileName)")
    }

    private func applyExternalDevice(_ device: AVCaptureDevice?) {
        if let device = device {
            if savedVideoSourceForPad3 == nil {
                savedVideoSourceForPad3 = pads.pads[2].source
            }
            if let cam = CameraSource(device: device, label: "uvc") {
                pads.setSource(cam, at: 2)
            }
        } else {
            if let restored = savedVideoSourceForPad3 {
                pads.setSource(restored, at: 2)
                savedVideoSourceForPad3 = nil
            }
        }
    }
}
