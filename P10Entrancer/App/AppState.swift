import Foundation
import AVFoundation
import Combine

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    /// Tracks in-flight transcodes so the pad cells can show a
    /// THINKING overlay + progress bar and the file picker can
    /// reject new transcodes while one is running.
    let transcodeManager = TranscodeManager()

    /// Render-quality knob for the per-pad preview thumbnails. Wired
    /// up via the Inspector panel; users on older iPads / heavy
    /// patches can drop to `.medium` or `.low` to keep transport
    /// ticks firing on cadence. Doesn't affect audio playback,
    /// sequencer timing, or the master output — only the on-screen
    /// pad visualizers.
    @Published var thumbnailQuality: ThumbnailQuality = .high

    let pads = PadSystem()
    let mixer = MixerState()
    let keyerSystem = KeyerSystem()
    let keyerRenderers: [KeyerRenderer]
    let feedbackSystem = FeedbackSystem()
    let feedbackRenderers: [FeedbackRenderer]
    let xyzSystem = XYZSystem()
    let xyzRenderers: [XYZRenderer]
    let fxPadSystem = FXPadSystem()
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
    let performances = PerformanceStore()
    /// Master clock + transport for LFOs (and any future tempo-synced
    /// feature). Driven by internal pulse or external MIDI Clock.
    let transport = Transport()
    /// All per-pad LFOs (9 source pads + 2 keyers + 1 feedback).
    /// Subscribes to `transport.tickPublisher` for evaluation.
    let lfoEngine: LFOEngine

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
        self.lfoEngine = LFOEngine(transport: self.transport)

        self.keyerRenderers = keyerSystem.keyers.map {
            try! KeyerRenderer(pads: pads, keyer: $0)
        }
        self.feedbackRenderers = feedbackSystem.units.map {
            try! FeedbackRenderer(pads: pads, state: $0)
        }
        self.xyzRenderers = xyzSystem.units.map {
            try! XYZRenderer(state: $0)
        }
        self.ntscPipeline = try! NTSCPipeline(state: ntscState)
        self.masterMixerOffscreen = try! MasterMixerOffscreen(
            pads: pads,
            mixer: mixer,
            keyers: self.keyerRenderers,
            feedbacks: self.feedbackRenderers,
            xyzs: self.xyzRenderers,
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
        // Walk routed camera pads at REC time and take the max of their
        // volume sliders as the mic gain. Sidesteps the stale-gain bug
        // where moving only a camera-pad's volume doesn't fire
        // applyAudioRouting.
        self.recorder.micGainProvider = { [weak self] in
            guard let self else { return 0 }
            let routed = self.routedPadIndices()
            var gain: Float = 0
            for i in routed {
                guard self.pads.pads.indices.contains(i) else { continue }
                let pad = self.pads.pads[i]
                if pad.source is CameraSource || pad.source is BuiltInCameraSource,
                   let v = pad.audioPlayer?.volume {
                    gain = max(gain, v)
                }
            }
            return gain
        }

        RenderEngine.shared.register(self.masterMixerOffscreen)
    }

    func startIfNeeded() {
        guard !started else { return }
        started = true
        P10Logger.log("[AppState] startIfNeeded — Phase 10b")
        AudioEngine.shared.startIfNeeded()
        AudioEngine.shared.masterVolume = mixer.masterVolume
        performances.bootstrapFactoryIfNeeded()
        // Pre-install both audio taps. The persistent recorder tap on
        // mainMixer means REC doesn't need a graph reconfigure. The mic
        // tap on inputNode also runs for the app's lifetime; the queue
        // it feeds is only drained while a recording is active.
        recorder.installPersistentTap()
        Task { @MainActor in
            await MicCapture.shared.ensureRunning()
            AudioEngine.shared.logSessionState(tag: "after mic tap")
        }
        midiBindings.attach(to: MIDIRouter.shared)
        // Forward MIDI real-time bytes (0xF8 clock, 0xFA start, etc.)
        // to the transport so it can derive BPM + isRunning from an
        // external source. Chained off any existing handler.
        let previousRealTime = MIDIRouter.shared.onRealTime
        MIDIRouter.shared.onRealTime = { [weak self] byte in
            previousRealTime?(byte)
            self?.transport.handleRealTimeByte(byte)
        }
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
        wireMasterVolume()
        wireAudioRouting()
        registerLFOTargets()
        // Always start silent. Without this, a saved session with a
        // non-zero masterVolume would blast audio on launch — which is
        // exactly the regression the user hit when wireMasterVolume
        // started propagating session-loaded values into the engine.
        // Run AFTER wireMasterVolume so the Combine sink also flips
        // the engine to 0.
        mixer.masterVolume = 0
        AudioEngine.shared.masterVolume = 0
        // Per-pad mute belt-and-braces: even with master volume at 0,
        // pads start with their mute flag flipped so when the user
        // raises master they don't blast everything at once.
        muteAllPads()
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
        muteAllPads()
        P10Logger.log("[AppState] loaded session '\(name)'")
    }

    /// Mute every pad's audio player via the per-pad mute toggle.
    /// Used after session load + app launch so audio never blasts
    /// without the user explicitly un-muting. Mixer levels (per-pad
    /// volume sliders) are NOT touched — the user's mix stays put;
    /// they just have to tap mute to bring each pad in.
    func muteAllPads() {
        for pad in pads.pads {
            pad.audioPlayer?.isMuted = true
        }
    }

    /// Keep AudioEngine.mainMixerNode.outputVolume synced with
    /// mixer.masterVolume from any source (UI slider, MIDI CC, session
    /// load). Without this, session loads silently muted the engine
    /// because they bypass the slider's setter.
    /// Register every modulatable param with the LFOEngine. Called at
    /// startup and re-called when a pad's source changes (since the
    /// new source's FXChain has a different parameter list).
    private func registerLFOTargets() {
        // Source pads: rebuild on every source change so FX param
        // ids point at the current chain.
        let initial = pads.onSourceChanged
        let refreshPads: () -> Void = { [weak self] in
            guard let self else { return }
            initial?()
            // Unregister all existing pad targets — cheap, just drops
            // ids from a dictionary. Then re-register the current ones.
            var stale: [String] = []
            for i in 0..<PadSystem.padCount { stale.append("pad-\(i)-stale-marker") }
            _ = stale
            // Simplest: just re-register; LFOTarget ids are stable
            // across re-registrations of the same param. Old entries
            // for FX that are no longer present get overwritten or
            // remain (and become inert because no assignment refers
            // to them).
            for i in 0..<PadSystem.padCount {
                let targets = LFOTargets.forSourcePad(index: i, pad: self.pads.pads[i])
                self.lfoEngine.registerTargets(targets)
            }
        }
        pads.onSourceChanged = refreshPads
        refreshPads()

        // Keyers + feedback: static state objects, register once.
        for (i, k) in keyerSystem.keyers.enumerated() {
            lfoEngine.registerTargets(LFOTargets.forKeyer(index: i, state: k))
        }
        if let fb = feedbackSystem.unit(at: 0) {
            lfoEngine.registerTargets(LFOTargets.forFeedback(state: fb))
        }
        // XYZ units: register targets for each, scoped via the
        // `xyz.N.` id prefix.
        for (i, x) in xyzSystem.units.enumerated() {
            lfoEngine.registerTargets(LFOTargets.forXYZ(index: i, state: x))
        }
        // Global / macro-only: mixer position. Only macros see this
        // (LFOEngine.availableTargets(forSlot:) filters per slot).
        lfoEngine.registerTargets(LFOTargets.forMixer(mixer))

        // FX slot LFO plumbing: the engine's slot resolver maps each
        // fxslot-N to the underlying FX unit's slot ID so the slot's
        // LFO sees the right param surface even after the user
        // changes the slot's FX type.
        lfoEngine.fxSlotResolver = { [weak self] index in
            guard let self,
                  self.fxPadSystem.slots.indices.contains(index) else { return nil }
            return self.fxPadSystem.slots[index].kind.underlyingLFOSlotID
        }
        // FX-type per slot is now immutable, so there's no kind-change
        // hook to install. Per-slot LFO assignment targets stay valid
        // for the lifetime of the app.
    }

    private func wireMasterVolume() {
        mixer.$masterVolume
            .receive(on: DispatchQueue.main)
            .sink { v in AudioEngine.shared.masterVolume = v }
            .store(in: &cancellables)
    }

    private func wireAudioRouting() {
        // `.receive(on: .main)` defers the sink to the next runloop tick.
        // Required because @Published emits in willSet, so reading
        // mixer.ch1Source synchronously inside the sink returns the OLD
        // value — that bug made tap-to-route lag by one tap.
        Publishers.CombineLatest(mixer.$ch1Source, mixer.$ch2Source)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in
                self?.applyAudioRouting()
            }
            .store(in: &cancellables)
        for keyer in keyerSystem.keyers {
            keyer.$foregroundSource
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.applyAudioRouting() }
                .store(in: &cancellables)
        }
        // Re-apply routing whenever a pad's source changes (drag-drop,
        // session load, etc.) so the new audioPlayer's isRouted state
        // matches the current channel assignments.
        pads.onSourceChanged = { [weak self] in self?.applyAudioRouting() }
        applyAudioRouting()
    }

    /// Pad indices currently feeding either output channel. Used by
    /// applyAudioRouting and by the recorder's mic-gain provider so
    /// both stay in sync.
    func routedPadIndices() -> Set<Int> {
        var routed = Set<Int>()
        for source in [mixer.ch1Source, mixer.ch2Source] {
            switch source {
            case .pad(let i):
                routed.insert(i)
            case .keyer(let i):
                if let k = keyerSystem.keyer(at: i) {
                    routed.insert(k.foregroundPadIndex)
                }
            case .feedback(let i):
                if let fb = feedbackSystem.unit(at: i) {
                    routed.insert(fb.sourcePadIndex)
                }
            case .xyz(let i):
                if let x = xyzSystem.unit(at: i),
                   case .pad(let p) = x.inputSource {
                    routed.insert(p)
                }
            }
        }
        return routed
    }

    func applyAudioRouting() {
        // Audio is no longer gated by channel routing. Every pad is
        // permanently "routed" from the audio engine's perspective;
        // the per-pad volume slider + per-pad mute + master volume
        // are the only controls over audibility. CH1/CH2 selection
        // continues to drive the VIDEO mix only — audio always plays
        // and the recorder captures the full pad mix.
        var micGain: Float = 0
        for pad in pads.pads {
            pad.audioPlayer?.setRouted(true)
            if pad.source is CameraSource || pad.source is BuiltInCameraSource,
               let v = pad.audioPlayer?.volume {
                micGain = max(micGain, v)
            }
        }
        MicCapture.shared.recordGain = micGain
        if recorder.isRecording {
            recorder.audioAppender.setMicMix(queue: MicCapture.shared.queue, gain: micGain)
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

    /// Snapshot current state + every pad's video URL, ask the
    /// PerformanceStore to write the package, return success.
    @discardableResult
    func savePerformance(named name: String) -> Bool {
        let (spec, urls) = PerformanceCapture.snapshotForPackage(name: name, appState: self)
        return performances.savePackage(name: name, spec: spec, videoFilesByPad: urls) != nil
    }

    func loadPerformance(named name: String) {
        PerformanceCapture.apply(packageName: name, store: performances, to: self)
    }

    func setMasterFeedbackSource(at index: Int) {
        pads.setSource(MasterFeedbackSource(mixerOffscreen: masterMixerOffscreen), at: index)
        P10Logger.log("[AppState] pad \(index + 1) source → MasterFeedback")
    }

    /// Replace a pad's source with a fresh wavetable instrument. Each
    /// pad gets its own instance so step grids / ADSR / wavePosition
    /// don't share state across pads.
    func setInstrumentSource(at index: Int) {
        let inst = InstrumentSource(transport: transport)
        pads.setSource(inst, at: index)
        P10Logger.log("[AppState] pad \(index + 1) source → Instrument (wavetable)")
    }

    /// Replace a pad's source with a fresh ACIDKICK drum machine.
    /// Each pad gets its own 4-track sequencer + voices so patterns
    /// don't share state across pads.
    func setACIDKICKSource(at index: Int) {
        let drums = ACIDKICKSource(transport: transport)
        pads.setSource(drums, at: index)
        P10Logger.log("[AppState] pad \(index + 1) source → Instrument (ACIDKICK)")
    }

    /// Set pad `targetIndex`'s source to forward another pad's
    /// processed texture. Refuses self-references (pad N can't chain
    /// from pad N — that's an infinite read on the same property).
    /// Longer cycles (A→B→A) are allowed; they resolve to 1-frame
    /// lag at the render pass.
    func setPadChainSource(at targetIndex: Int, sourcePadIndex: Int) {
        guard targetIndex != sourcePadIndex else {
            P10Logger.log("[AppState] refusing self-chain on pad \(targetIndex + 1)")
            return
        }
        guard pads.pads.indices.contains(targetIndex),
              pads.pads.indices.contains(sourcePadIndex) else { return }
        pads.setSource(PadChainSource(sourcePadIndex: sourcePadIndex, pads: pads),
                       at: targetIndex)
        P10Logger.log("[AppState] pad \(targetIndex + 1) source → pad \(sourcePadIndex + 1) (chain)")
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

    func setFeedbackSource(feedbackIndex: Int, at padIndex: Int) {
        guard feedbackRenderers.indices.contains(feedbackIndex) else { return }
        let source = FeedbackPadSource(feedbackIndex: feedbackIndex, renderer: feedbackRenderers[feedbackIndex])
        pads.setSource(source, at: padIndex)
        P10Logger.log("[AppState] pad \(padIndex + 1) source → Feedback \(feedbackIndex + 1)")
    }

    func loadUserVideo(from sourceURL: URL, at index: Int) {
        P10Logger.log("[AppState] loadUserVideo called: \(sourceURL.path) → pad \(index + 1)")
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let userDir = docs.appendingPathComponent("UserVideos", isDirectory: true)
        try? FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)

        // Security-scoped access on the originating Files.app URL has
        // to bracket the copy itself. We do that synchronously here,
        // then hand off any heavy transcode work to a Task — at that
        // point we already own the file in our sandbox so the scope
        // can be released.
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

        // AVFoundation-native container → load synchronously, same
        // path as before. Anything else (.mkv/.webm/.avi/…) is
        // handed to the in-app transcoder.
        if !TranscodeService.needsTranscoding(dest) {
            pads.setSource(VideoFileSource(url: dest), at: index)
            P10Logger.log("[AppState] pad \(index + 1) source → user file \(fileName)")
            return
        }

        // Single-transcode-at-a-time policy. Refuse new jobs while
        // one is running so the user can't pile up parallel ffmpeg
        // sessions (each is CPU-bound — parallel just stalls all
        // of them). The UI also blocks the Files importer when
        // isAnyActive is true, so we should only hit this path on
        // session-restore races.
        guard !transcodeManager.isAnyActive else {
            P10Logger.log("[AppState] pad \(index + 1) transcode refused: another transcode in flight")
            try? FileManager.default.removeItem(at: dest)
            return
        }

        P10Logger.log("[AppState] pad \(index + 1): \(fileName) needs transcode → mp4")
        let outputURL = dest.deletingPathExtension().appendingPathExtension("mp4")

        // Register the job so the pad cell can show its THINKING
        // overlay + progress bar. The TranscodeManager publishes to
        // SwiftUI on the main actor.
        transcodeManager.start(padIndex: index, inputName: fileName)

        // FFmpegKit runs on its own thread pool; the statistics
        // callback fires off-actor. Hop to MainActor inside the
        // closure to push the progress fraction into the manager.
        Task.detached { [weak self] in
            do {
                _ = try await TranscodeService.transcodeToMP4(
                    input: dest,
                    output: outputURL,
                    onProgress: { frac in
                        Task { @MainActor [weak self] in
                            self?.transcodeManager.update(padIndex: index, progress: frac)
                        }
                    }
                )
                try? FileManager.default.removeItem(at: dest)
                await MainActor.run {
                    guard let self else { return }
                    self.transcodeManager.finish(padIndex: index)
                    self.pads.setSource(VideoFileSource(url: outputURL), at: index)
                    P10Logger.log("[AppState] pad \(index + 1) source → transcoded \(outputURL.lastPathComponent)")
                }
            } catch {
                P10Logger.log("[AppState] pad \(index + 1) transcode failed: \(error)")
                await MainActor.run { [weak self] in
                    self?.transcodeManager.finish(padIndex: index)
                }
            }
        }
    }
}
