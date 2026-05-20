import Foundation

/// Capture/apply for `SessionSpec` against the live system. Lives outside
/// `AppState` so the encoding logic is testable in isolation.
@MainActor
enum SessionCapture {

    static func snapshot(name: String,
                         pads: PadSystem,
                         keyerSystem: KeyerSystem,
                         mixer: MixerState,
                         ntsc: NTSCState,
                         hdPost: HDPostState,
                         cameras: CameraRegistry,
                         liveRecordings: LiveRecordingsStore) -> SessionSpec {
        var padSpecs: [SessionSpec.PadSpec] = []
        for (i, pad) in pads.pads.enumerated() {
            padSpecs.append(snapshotPad(at: i, pad: pad, cameras: cameras))
        }

        let k = keyerSystem.keyer
        let keyerSpecs = [
            SessionSpec.KeyerSpec(
                foregroundPadIndex: k.foregroundPadIndex,
                backgroundPadIndex: k.backgroundPadIndex,
                kind: k.kind.rawValue,
                threshold: k.threshold,
                softness: k.softness,
                keyColor: [k.keyColor.x, k.keyColor.y, k.keyColor.z]
            )
        ]

        let mixerSpec = SessionSpec.MixerSpec(
            ch1Source: encodeChannel(mixer.ch1Source),
            ch2Source: encodeChannel(mixer.ch2Source),
            activeChannel: mixer.activeChannel.rawValue,
            transition: mixer.transition.rawValue,
            position: mixer.position,
            masterVolume: mixer.masterVolume,
            outputMode: mixer.outputMode.rawValue
        )

        let ntscSpec = SessionSpec.NTSCSpec(
            chromaBoost: ntsc.chromaBoost,
            lumaNoise: ntsc.lumaNoise,
            chromaNoise: ntsc.chromaNoise,
            hsyncWobble: ntsc.hsyncWobble,
            dropoutRate: ntsc.dropoutRate,
            burstPhaseShift: ntsc.burstPhaseShift,
            subcarrierDrift: ntsc.subcarrierDrift,
            ycDelay: ntsc.ycDelay,
            combStrength: ntsc.combStrength,
            lumaPeaking: ntsc.lumaPeaking
        )

        let hdPostSpec = SessionSpec.HDPostSpec(
            gamma: hdPost.gamma,
            contrast: hdPost.contrast,
            saturation: hdPost.saturation,
            brightness: hdPost.brightness,
            bloom: hdPost.bloom,
            bloomThresh: hdPost.bloomThresh
        )

        let reel = liveRecordings.recent.map { $0.url.lastPathComponent }

        return SessionSpec(
            name: name,
            pads: padSpecs,
            keyers: keyerSpecs,
            mixer: mixerSpec,
            ntsc: ntscSpec,
            hdPost: hdPostSpec,
            liveRecordings: reel
        )
    }

    static func apply(_ spec: SessionSpec, to appState: AppState) {
        // Pads
        for padSpec in spec.pads {
            applyPad(padSpec, appState: appState)
        }
        // Keyer — only the first KeyerSpec is applied. Legacy sessions
        // with multiple keyers fall through; their extra entries are
        // ignored since the FX surface is now atomic.
        if let keyerSpec = spec.keyers.first {
            let k = appState.keyerSystem.keyer
            k.foregroundPadIndex = keyerSpec.foregroundPadIndex
            k.backgroundPadIndex = keyerSpec.backgroundPadIndex
            k.kind = KeyerKind(rawValue: keyerSpec.kind) ?? .chroma
            k.threshold = keyerSpec.threshold
            k.softness = keyerSpec.softness
            if keyerSpec.keyColor.count >= 3 {
                k.keyColor = SIMD3(keyerSpec.keyColor[0], keyerSpec.keyColor[1], keyerSpec.keyColor[2])
            }
        }
        // Mixer
        appState.mixer.ch1Source = decodeChannel(spec.mixer.ch1Source)
        appState.mixer.ch2Source = decodeChannel(spec.mixer.ch2Source)
        appState.mixer.activeChannel = ActiveChannel(rawValue: spec.mixer.activeChannel) ?? .ch1
        appState.mixer.transition = TransitionKind(rawValue: spec.mixer.transition) ?? .crossfade
        appState.mixer.position = spec.mixer.position
        appState.mixer.masterVolume = spec.mixer.masterVolume
        appState.mixer.outputMode = OutputMode(rawValue: spec.mixer.outputMode) ?? .hd720p
        // NTSC
        appState.ntscState.chromaBoost = spec.ntsc.chromaBoost
        appState.ntscState.lumaNoise = spec.ntsc.lumaNoise
        appState.ntscState.chromaNoise = spec.ntsc.chromaNoise
        appState.ntscState.hsyncWobble = spec.ntsc.hsyncWobble
        appState.ntscState.dropoutRate = spec.ntsc.dropoutRate
        appState.ntscState.burstPhaseShift = spec.ntsc.burstPhaseShift
        appState.ntscState.subcarrierDrift = spec.ntsc.subcarrierDrift
        appState.ntscState.ycDelay = spec.ntsc.ycDelay
        appState.ntscState.combStrength = spec.ntsc.combStrength
        appState.ntscState.lumaPeaking = spec.ntsc.lumaPeaking
        // HD post — optional for legacy sessions; leave at defaults if absent.
        if let hd = spec.hdPost {
            appState.hdPostState.gamma = hd.gamma
            appState.hdPostState.contrast = hd.contrast
            appState.hdPostState.saturation = hd.saturation
            appState.hdPostState.brightness = hd.brightness
            appState.hdPostState.bloom = hd.bloom
            appState.hdPostState.bloomThresh = hd.bloomThresh
        }
    }

    // MARK: - Pad encoding/decoding

    private static func snapshotPad(at index: Int, pad: PadSlot, cameras: CameraRegistry) -> SessionSpec.PadSpec {
        let fxSpec = SessionSpec.FXChainSpec(
            effects: pad.fxChain.effects.map { fx in
                SessionSpec.FXEffectSpec(
                    name: fx.name,
                    isEnabled: fx.isEnabled,
                    values: fx.parameters.map { $0.value }
                )
            }
        )
        let kind: SessionSpec.PadSourceKind
        var bundledIndex: Int? = nil
        var userVideoBasename: String? = nil
        var cameraID: String? = nil
        if let source = pad.source {
            if let v = source as? VideoFileSource {
                if let bundleIdx = bundledPadIndex(for: v.url) {
                    kind = .bundled
                    bundledIndex = bundleIdx
                } else if isUserVideo(v.url) {
                    kind = .userVideo
                    userVideoBasename = v.url.lastPathComponent
                } else {
                    kind = .empty
                }
            } else if let id = cameras.deviceID(for: source) {
                kind = .camera
                cameraID = id
            } else if source is KeyerPadSource {
                kind = .keyer
            } else if source is MasterFeedbackSource {
                kind = .masterFeedback
            } else {
                kind = .empty
            }
        } else {
            kind = .empty
        }
        return SessionSpec.PadSpec(
            index: index,
            kind: kind,
            bundledIndex: bundledIndex,
            userVideoBasename: userVideoBasename,
            cameraID: cameraID,
            keyerIndex: nil,
            fx: fxSpec
        )
    }

    private static func applyPad(_ spec: SessionSpec.PadSpec, appState: AppState) {
        let i = spec.index
        guard appState.pads.pads.indices.contains(i) else { return }
        // Source
        switch spec.kind {
        case .bundled:
            let n = (spec.bundledIndex ?? i) + 1
            if let url = Bundle.main.url(forResource: "pad\(n)", withExtension: "mp4") {
                appState.pads.setSource(VideoFileSource(url: url), at: i)
            } else {
                appState.pads.setSource(nil, at: i)
            }
        case .userVideo:
            if let basename = spec.userVideoBasename {
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                let url = docs.appendingPathComponent("UserVideos", isDirectory: true).appendingPathComponent(basename)
                if FileManager.default.fileExists(atPath: url.path) {
                    appState.pads.setSource(VideoFileSource(url: url), at: i)
                } else {
                    appState.pads.setSource(nil, at: i)
                }
            }
        case .camera:
            if let id = spec.cameraID {
                appState.setCameraSource(deviceID: id, at: i)
            }
        case .keyer:
            appState.setKeyerSource(at: i)
        case .masterFeedback:
            appState.setMasterFeedbackSource(at: i)
        case .empty:
            appState.pads.setSource(nil, at: i)
        }
        // FX
        let chain = appState.pads.pads[i].fxChain
        for effectSpec in spec.fx.effects {
            guard let target = chain.effects.first(where: { $0.name == effectSpec.name }) else { continue }
            target.isEnabled = effectSpec.isEnabled
            for (paramIndex, value) in effectSpec.values.enumerated() {
                guard paramIndex < target.parameters.count else { break }
                target.parameters[paramIndex].value = value
            }
        }
    }

    private static func encodeChannel(_ source: ChannelSource) -> SessionSpec.MixerSpec.Source {
        // `index` is kept in the on-disk schema for back-compat with
        // existing saved sessions; for non-pad sources it's now always
        // zero and ignored on read.
        switch source {
        case .pad(let i):  return .init(kind: .pad, index: i)
        case .keyer:       return .init(kind: .keyer, index: 0)
        case .feedback:    return .init(kind: .feedback, index: 0)
        case .xyz:         return .init(kind: .xyz, index: 0)
        }
    }

    private static func decodeChannel(_ source: SessionSpec.MixerSpec.Source) -> ChannelSource {
        switch source.kind {
        case .pad:      return .pad(source.index)
        case .keyer:    return .keyer
        case .feedback: return .feedback
        case .xyz:      return .xyz
        }
    }

    private static func bundledPadIndex(for url: URL) -> Int? {
        // Bundle URLs look like .../P10Entrancer.app/padN.mp4
        guard url.pathExtension == "mp4" else { return nil }
        let name = url.deletingPathExtension().lastPathComponent
        guard name.hasPrefix("pad"), let n = Int(name.dropFirst(3)) else { return nil }
        // Confirm it actually came from the app bundle (vs. being a coincidentally
        // named user file).
        let bundleHasIt = Bundle.main.url(forResource: name, withExtension: "mp4") == url
        return bundleHasIt ? (n - 1) : nil
    }

    private static func isUserVideo(_ url: URL) -> Bool {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let userDir = docs.appendingPathComponent("UserVideos", isDirectory: true).path
        return url.path.hasPrefix(userDir)
    }
}
