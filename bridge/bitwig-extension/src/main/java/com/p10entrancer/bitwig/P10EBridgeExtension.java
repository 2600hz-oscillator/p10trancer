package com.p10entrancer.bitwig;

import com.bitwig.extension.controller.ControllerExtension;
import com.bitwig.extension.controller.api.AbsoluteHardwareKnob;
import com.bitwig.extension.controller.api.Application;
import com.bitwig.extension.controller.api.ControllerHost;
import com.bitwig.extension.controller.api.CursorRemoteControlsPage;
import com.bitwig.extension.controller.api.CursorTrack;
import com.bitwig.extension.controller.api.HardwareButton;
import com.bitwig.extension.controller.api.HardwareSurface;
import com.bitwig.extension.controller.api.MidiIn;
import com.bitwig.extension.controller.api.MidiOut;
import com.bitwig.extension.controller.api.RemoteControl;
import com.bitwig.extension.controller.api.Transport;

/**
 * Bidirectional bridge between Bitwig and the iPad-side P10 Entrancer app.
 *
 * Auto-binding: 8 of the most-used Bridge knobs (Position, Master Vol,
 * NTSC Chroma/HSync/Drift, FX Feedback Mix, FX Blur, FX Edge) are bound
 * automatically to the **cursor track's 8 macros**. Any time the user
 * selects a track in Bitwig, those 8 macros become driven by the iPad's
 * outbound CCs. Recording: arm the track + enable Write Automation
 * (transport `W` button) + hit record + perform on iPad. Bitwig captures
 * gestures as automation on the macro lanes.
 *
 * Playback: macro automation drives macro values → parameter value
 * observer emits CC out to iPad → iPad UI re-performs.
 *
 * For the rest of the iPad's MIDI scheme (other CCs, all 128 notes, all
 * PCs) the extension still exposes them as raw hardware controls/buttons
 * but they're un-bound — the user maps any of them to additional
 * parameters as needed.
 */
public class P10EBridgeExtension extends ControllerExtension {
    private MidiOut midiOut;
    private MidiIn midiIn;
    private HardwareSurface surface;
    private Application application;
    private CursorTrack cursorTrack;
    private CursorRemoteControlsPage cursorMacros;
    private Transport transport;

    public P10EBridgeExtension(P10EBridgeExtensionDefinition definition, ControllerHost host) {
        super(definition, host);
    }

    @Override
    public void init() {
        ControllerHost host = getHost();
        midiOut = host.getMidiOutPort(0);
        midiIn = host.getMidiInPort(0);
        surface = host.createHardwareSurface();
        application = host.createApplication();
        transport = host.createTransport();
        cursorTrack = host.createCursorTrack("p10e-bridge", "P10E Bridge", 0, 0, true);
        cursorMacros = cursorTrack.createCursorRemoteControlsPage(8);

        createSetupAction();
        createPadTriggers();
        createTransitionButtons();
        createChannelButtons();
        createSystemButtons();
        createInspectButtons();
        createPrimaryKnobsBoundToMacros();
        createSecondaryNamedCCKnobs();
        createPerPadFXKnobs();
        createAllCCKnobs();
        createAllNoteButtons();

        host.showPopupNotification("P10 Entrancer Bridge ready (auto-bind)");
    }

    @Override
    public void exit() {}

    @Override
    public void flush() {
        surface.updateHardware();
    }

    // ---- One-click setup action -------------------------------------------

    private void createSetupAction() {
        button("p10e_setup_track", "Setup P10E Capture Track", () -> {
            try {
                application.createInstrumentTrack(-1);
                transport.isArrangerAutomationWriteEnabled().set(true);
                getHost().showPopupNotification(
                    "P10E capture track created. Automation write ON. " +
                    "Select the new track, arm it, hit record, and perform on iPad."
                );
            } catch (Throwable t) {
                getHost().showPopupNotification("Track creation failed: " + t.getMessage());
            }
        });
    }

    // ---- Pad triggers (PC 1-9) --------------------------------------------

    private void createPadTriggers() {
        for (int i = 0; i < 9; i++) {
            int padIndex = i;
            HardwareButton btn = surface.createHardwareButton("p10e_pad_" + (i + 1));
            btn.setLabel("Pad " + (i + 1));
            btn.pressedAction().setBinding(getHost().createAction(() -> {
                sendMidi(0xC0, padIndex + 1, 0);
            }, () -> "Trigger pad " + (padIndex + 1)));
        }
    }

    // ---- Transition kind (PC 12-16) ---------------------------------------

    private void createTransitionButtons() {
        String[] names = {"Blur", "Swipe", "Star", "Chroma", "Luma"};
        for (int i = 0; i < names.length; i++) {
            int program = 12 + i;
            HardwareButton btn = surface.createHardwareButton("p10e_trans_" + names[i]);
            btn.setLabel("Transition: " + names[i]);
            btn.pressedAction().setBinding(getHost().createAction(() -> {
                sendMidi(0xC0, program, 0);
            }, () -> "Set transition " + program));
        }
    }

    private void createChannelButtons() {
        button("p10e_ch1", "Active CH1", () -> sendMidi(0xC0, 10, 0));
        button("p10e_ch2", "Active CH2", () -> sendMidi(0xC0, 11, 0));
    }

    private void createSystemButtons() {
        button("p10e_hdmi_toggle", "Toggle HDMI HD/NTSC", () -> sendMidi(0xC0, 17, 0));
        button("p10e_keyer_toggle", "Toggle Keyer", () -> sendMidi(0xC0, 18, 0));
        button("p10e_keyer_to_ch1", "Keyer → CH1", () -> sendMidi(0xC0, 19, 0));
        button("p10e_keyer_to_ch2", "Keyer → CH2", () -> sendMidi(0xC0, 20, 0));
        button("p10e_record_toggle", "Toggle Record", () -> sendMidi(0xC0, 21, 0));
    }

    private void createInspectButtons() {
        for (int i = 0; i < 9; i++) {
            int program = 22 + i;
            button("p10e_inspect_" + (i + 1), "Inspect Pad " + (i + 1) + " for FX", () -> {
                sendMidi(0xC0, program, 0);
            });
        }
    }

    // ---- Primary knobs auto-bound to cursor track's 8 macros --------------

    private static final int[] PRIMARY_CCS = {1, 2, 14, 15, 16, 32, 23, 31};
    private static final String[] PRIMARY_LABELS = {
        "Mixer Position (Ch1↔Ch2)",
        "Master Volume",
        "NTSC Chroma Boost",
        "NTSC HSync Wobble",
        "NTSC Subcarrier Drift",
        "FX: Feedback Mix",
        "FX: Blur Radius",
        "FX: Edge Enhance"
    };

    private void createPrimaryKnobsBoundToMacros() {
        for (int i = 0; i < PRIMARY_CCS.length && i < 8; i++) {
            int cc = PRIMARY_CCS[i];
            String label = PRIMARY_LABELS[i] + " (Macro " + (i + 1) + ")";
            AbsoluteHardwareKnob knob = surface.createAbsoluteHardwareKnob("p10e_primary_" + cc);
            knob.setLabel(label);
            knob.setAdjustValueMatcher(midiIn.createAbsoluteCCValueMatcher(0, cc));

            // Bind hardware knob to the i-th macro on the currently selected
            // track. When the user selects ANY track, these 8 macros now
            // receive iPad CCs. Recording with Automation Write captures
            // the gestures as macro automation.
            RemoteControl macro = cursorMacros.getParameter(i);
            knob.setBinding(macro);

            // Outbound: emit MIDI when macro value changes (from any source —
            // automation playback, user dragging, modulator, OR our own
            // hardware knob driving it via the binding). The iPad's
            // muted-on-inbound guard prevents echo.
            macro.value().addValueObserver(128, midiValue -> {
                int v = Math.max(0, Math.min(127, midiValue));
                sendMidi(0xB0, cc, v);
            });
        }
    }

    // ---- Secondary named knobs (un-bound, manually mappable) --------------

    private void createSecondaryNamedCCKnobs() {
        for (int i = 0; i < 9; i++) {
            ccKnob("p10e_pad_vol_" + (i + 1), "Pad " + (i + 1) + " Volume", 5 + i);
        }
        ccKnob("p10e_key_threshold", "Keyer Threshold", 3);
        ccKnob("p10e_key_softness", "Keyer Softness", 4);
        ccKnob("p10e_ntsc_burst", "NTSC Burst Phase", 17);
        ccKnob("p10e_ntsc_yc", "NTSC Y/C Delay", 18);
        ccKnob("p10e_ntsc_dropout", "NTSC Dropout", 19);
        ccKnob("p10e_ntsc_lnoise", "NTSC Luma Noise", 20);
        ccKnob("p10e_ntsc_cnoise", "NTSC Chroma Noise", 21);
        ccKnob("p10e_ntsc_peak", "NTSC Luma Peaking", 22);
    }

    private void createPerPadFXKnobs() {
        ccKnob("p10e_fx_chroma_hue", "FX: Chroma Hue", 24);
        ccKnob("p10e_fx_chroma_sat", "FX: Chroma Saturation", 25);
        ccKnob("p10e_fx_chroma_split", "FX: Chroma RGB Split", 26);
        ccKnob("p10e_fx_yuv_phase", "FX: YUV Phaser Phase", 27);
        ccKnob("p10e_fx_yuv_depth", "FX: YUV Phaser Depth", 28);
        ccKnob("p10e_fx_luma_strength", "FX: Luma Phaser Strength", 29);
        ccKnob("p10e_fx_luma_curve", "FX: Luma Phaser Curve", 30);
        ccKnob("p10e_fx_feedback_zoom", "FX: Feedback Zoom", 33);
        ccKnob("p10e_fx_feedback_decay", "FX: Feedback Decay", 34);
    }

    // ---- Catch-all: every CC and every note as raw mappable controls ------

    private void createAllCCKnobs() {
        // Skip CC numbers already handled by primary-bound + secondary-named.
        // Primary CCs: 1, 2, 14, 15, 16, 32, 23, 31
        // Secondary CCs: 3, 4, 5-13, 17-22, 24-30, 33, 34
        for (int cc = 35; cc < 128; cc++) {
            ccKnob("p10e_cc_" + cc, "CC " + cc, cc);
        }
    }

    private void createAllNoteButtons() {
        for (int note = 0; note < 128; note++) {
            int n = note;
            HardwareButton btn = surface.createHardwareButton("p10e_note_" + n);
            btn.setLabel("Note " + noteName(n));
            btn.pressedAction().setBinding(getHost().createAction(() -> {
                sendMidi(0x90, n, 100);
            }, () -> "Send Note " + n));
            btn.releasedAction().setBinding(getHost().createAction(() -> {
                sendMidi(0x80, n, 0);
            }, () -> "Release Note " + n));
        }
    }

    // ---- helpers ----------------------------------------------------------

    private static final String[] NOTE_NAMES = {"C","C#","D","D#","E","F","F#","G","G#","A","A#","B"};

    private static String noteName(int midiNote) {
        int octave = (midiNote / 12) - 1;
        return NOTE_NAMES[midiNote % 12] + octave;
    }

    private HardwareButton button(String id, String label, Runnable action) {
        HardwareButton btn = surface.createHardwareButton(id);
        btn.setLabel(label);
        btn.pressedAction().setBinding(getHost().createAction(action, () -> label));
        return btn;
    }

    private AbsoluteHardwareKnob ccKnob(String id, String label, int cc) {
        AbsoluteHardwareKnob knob = surface.createAbsoluteHardwareKnob(id);
        knob.setLabel(label);
        knob.setAdjustValueMatcher(midiIn.createAbsoluteCCValueMatcher(0, cc));
        knob.value().addValueObserver(value -> {
            int midiValue = (int) Math.round(value * 127.0);
            midiValue = Math.max(0, Math.min(127, midiValue));
            sendMidi(0xB0, cc, midiValue);
        });
        return knob;
    }

    private void sendMidi(int status, int data1, int data2) {
        midiOut.sendMidi(status, data1, data2);
    }
}
