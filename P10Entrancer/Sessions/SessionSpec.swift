import Foundation

/// Versioned snapshot of the live state. Codable so it round-trips through
/// JSON. URLs of files inside Documents/UserVideos/ are stored as relative
/// names so they survive the iOS app sandbox UUID changing across reinstalls.
struct SessionSpec: Codable {
    static let currentVersion = 1

    var name: String
    var version: Int = SessionSpec.currentVersion
    var pads: [PadSpec]
    var keyers: [KeyerSpec]
    var mixer: MixerSpec
    var ntsc: NTSCSpec
    var liveRecordings: [String]   // basenames, relative to Documents/UserVideos/

    enum PadSourceKind: String, Codable {
        case bundled, userVideo, camera, keyer, masterFeedback, empty
    }

    struct PadSpec: Codable {
        var index: Int
        var kind: PadSourceKind
        var bundledIndex: Int?           // 0..8 → padN.mp4
        var userVideoBasename: String?   // file in Documents/UserVideos/
        var cameraID: String?            // matches CameraDevice.id
        var keyerIndex: Int?             // 0 or 1
        var fx: FXChainSpec
    }

    struct FXChainSpec: Codable {
        var effects: [FXEffectSpec]
    }

    struct FXEffectSpec: Codable {
        var name: String
        var isEnabled: Bool
        var values: [Float]
    }

    struct KeyerSpec: Codable {
        var foregroundPadIndex: Int
        var backgroundPadIndex: Int
        var kind: Int                    // KeyerKind.rawValue
        var threshold: Float
        var softness: Float
        var keyColor: [Float]            // [r, g, b]
    }

    struct MixerSpec: Codable {
        enum SourceKind: String, Codable { case pad, keyer, feedback }
        struct Source: Codable {
            var kind: SourceKind
            var index: Int
        }
        var ch1Source: Source
        var ch2Source: Source
        var activeChannel: Int           // 0 = ch1, 1 = ch2
        var transition: Int              // TransitionKind.rawValue
        var position: Float
        var masterVolume: Float
        var outputMode: Int              // OutputMode.rawValue
    }

    struct NTSCSpec: Codable {
        var chromaBoost: Float
        var lumaNoise: Float
        var chromaNoise: Float
        var hsyncWobble: Float
        var dropoutRate: Float
        var burstPhaseShift: Float
        var subcarrierDrift: Float
        var ycDelay: Float
        var combStrength: Float
        var lumaPeaking: Float
    }
}
