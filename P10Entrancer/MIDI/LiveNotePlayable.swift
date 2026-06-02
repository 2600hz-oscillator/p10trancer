import Foundation

/// A pad instrument that can be played live from MIDI notes (separate from its
/// step sequencer). Mono, last-note priority. Implemented by WAVETABLE,
/// ACIDBASS, MULTIPLATES, and ACIDKICK so a MIDI channel routed to that pad
/// "just plays" it. See .myrobots/ELECTRA_ONE_MIDI_INFO for the channel map.
@MainActor
protocol LiveNotePlayable: AnyObject {
    func playNoteOn(midiNote: Int, velocity: Int)
    func playNoteOff(midiNote: Int)
}
