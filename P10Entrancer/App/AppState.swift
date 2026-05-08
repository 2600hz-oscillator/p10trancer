import Foundation
import AVFoundation
import Combine

@MainActor
final class AppState {
    static let shared = AppState()

    let pads = PadSystem()
    let mixer = MixerState()
    let keyerSystem = KeyerSystem()
    let keyerRenderers: [KeyerRenderer]
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
    let cameras = CameraRegistry()
    let sessions = SessionStore()

    /// Back-compat shim for code that still references a single keyer (MIDI
    /// bindings, audio routing). Points at Keyer 1.
    var keyerState: KeyerState { keyerSystem.keyers[0] }

    private var started = false
    private var cancellables = Set<AnyCancellable>()

    private init() {
        let pads = self.pads
        let mixer = self.mixer
        let keyerSystem = self.keyerSystem
        let ntscState = self.ntscState

        self.keyerRenderers = keyerSystem.keyers.map {
            try! KeyerRenderer(pads: pads, keyer: $0)
        }
        self.ntscPipeline = try! NTSCPipeline(state: ntscState)
        self.masterMixerOffscreen = try! MasterMixerOffscreen(
            pads: pads,
            mixer: mixer,
            keyers: self.keyerRenderers,
            ntscPipeline: self.ntscPipeline
        )

        let recorder = MixerRecorder()
        self.midiBindings = MIDIBindings(
            mixer: mixer,
            pads: pads,
            keyer: keyerSystem.keyers[0],
            ntsc: ntscState,
            recorder: recorder
        )
        self.midiOutputBindings = MIDIOutputBindings(
            mixer: mixer,
            pads: pads,
            keyer: keyerSystem.keyers[0],
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
        P10Logger.log("[AppState] startIfNeeded — Phase 10b")
        AudioEngine.shared.startIfNeeded()
        AudioEngine.shared.masterVolume = mixer.masterVolume
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
        // MIDIRouter.connectAllSources skips our own published source by
        // unique ID, so this no longer creates an echo loop. Run it so we
        // pick up any external MIDI sources that appear after startup.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            Task { @MainActor in
                MIDIRouter.shared.connectAllSources()
            }
        }
        loadVideoAssets()
        Task { await self.cameras.startIfNeeded() }
        applyDefaultPresetIfAny()
        RenderEngine.shared.start()
        screenshotCapturer.start()
        wireAudioRouting()
    }

    /// On launch, after factory bundled clips are loaded, replay the user's
    /// chosen default preset on top (if any). Falls back silently if the
    /// preset file is missing or corrupt.
    private func applyDefaultPresetIfAny() {
        let name = sessions.defaultPresetName
        guard name != SessionStore.factoryName,
              let spec = sessions.load(name) else { return }
        SessionCapture.apply(spec, to: self)
        P10Logger.log("[AppState] applied default preset '\(name)' on launch")
    }

    /// Reset everything to factory defaults: bundled clips on the 9 pads,
    /// no FX, default keyer params, default mixer/NTSC. Called by the
    /// SESSION sheet's "Default" button.
    func resetToFactoryDefaults() {
        for i in 0..<PadSystem.padCount {
            // Re-bundle pad source
            if let url = Bundle.main.url(forResource: "pad\(i + 1)", withExtension: "mp4") {
                pads.setSource(VideoFileSource(url: url), at: i)
            } else {
                pads.setSource(nil, at: i)
            }
            // Disable all FX, restore param defaults (range.lowerBound is the
            // safe baseline for "off")
            for fx in pads.pads[i].fxChain.effects {
                fx.isEnabled = false
                for p in fx.parameters { p.value = p.range.lowerBound }
            }
        }
        for k in keyerSystem.keyers {
            k.kind = .chroma
            k.threshold = 0.35
            k.softness = 0.1
            k.keyColor = SIMD3(0, 1, 0)
        }
        keyerSystem.keyers[0].foregroundPadIndex = 6
        keyerSystem.keyers[0].backgroundPadIndex = 7
        keyerSystem.keyers[1].foregroundPadIndex = 7
        keyerSystem.keyers[1].backgroundPadIndex = 8
        mixer.ch1Source = .pad(0)
        mixer.ch2Source = .pad(1)
        mixer.activeChannel = .ch1
        mixer.transition = .crossfade
        mixer.position = 0
        mixer.masterVolume = 0
        AudioEngine.shared.masterVolume = 0
        mixer.outputMode = .hd720p
        ntscState.chromaBoost = 1.0
        ntscState.lumaNoise = 0
        ntscState.chromaNoise = 0
        ntscState.hsyncWobble = 0
        ntscState.dropoutRate = 0
        ntscState.burstPhaseShift = 0
        ntscState.subcarrierDrift = 0
        ntscState.ycDelay = 0
        ntscState.combStrength = 0.7
        ntscState.lumaPeaking = 0
        sessions.hasUnsavedChanges = false
        P10Logger.log("[AppState] reset to factory defaults")
    }

    func saveCurrentSession(as name: String) -> Bool {
        let spec = SessionCapture.snapshot(
            name: name,
            pads: pads,
            keyerSystem: keyerSystem,
            mixer: mixer,
            ntsc: ntscState,
            cameras: cameras,
            liveRecordings: liveRecordings
        )
        return sessions.save(spec, as: name)
    }

    func loadSession(named name: String) {
        guard let spec = sessions.load(name) else { return }
        SessionCapture.apply(spec, to: self)
        sessions.hasUnsavedChanges = false
        P10Logger.log("[AppState] loaded session '\(name)'")
    }

    private func wireAudioRouting() {
        Publishers.CombineLatest(mixer.$ch1Source, mixer.$ch2Source)
            .sink { [weak self] _, _ in
                self?.applyAudioRouting()
            }
            .store(in: &cancellables)
        for keyer in keyerSystem.keyers {
            keyer.$foregroundPadIndex
                .sink { [weak self] _ in self?.applyAudioRouting() }
                .store(in: &cancellables)
        }
        applyAudioRouting()
    }

    func applyAudioRouting() {
        var routed = Set<Int>()
        for source in [mixer.ch1Source, mixer.ch2Source] {
            switch source {
            case .pad(let i):
                routed.insert(i)
            case .keyer(let i):
                if let k = keyerSystem.keyer(at: i) {
                    routed.insert(k.foregroundPadIndex)
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

    func setCameraSource(deviceID: String, at index: Int) {
        guard let source = cameras.source(for: deviceID) else {
            P10Logger.log("[AppState] no camera with id=\(deviceID)")
            return
        }
        pads.setSource(source, at: index)
        P10Logger.log("[AppState] pad \(index + 1) source → camera \(deviceID)")
    }

    func setKeyerSource(keyerIndex: Int, at padIndex: Int) {
        guard keyerRenderers.indices.contains(keyerIndex) else { return }
        let source = KeyerPadSource(keyerIndex: keyerIndex, renderer: keyerRenderers[keyerIndex])
        pads.setSource(source, at: padIndex)
        P10Logger.log("[AppState] pad \(padIndex + 1) source → Keyer \(keyerIndex + 1)")
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
}
