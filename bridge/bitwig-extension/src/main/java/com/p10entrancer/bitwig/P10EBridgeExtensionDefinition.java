package com.p10entrancer.bitwig;

import com.bitwig.extension.api.PlatformType;
import com.bitwig.extension.controller.AutoDetectionMidiPortNamesList;
import com.bitwig.extension.controller.api.ControllerHost;
import com.bitwig.extension.controller.ControllerExtensionDefinition;

import java.util.UUID;

public class P10EBridgeExtensionDefinition extends ControllerExtensionDefinition {
    private static final UUID EXTENSION_ID = UUID.fromString("c0e10000-1e7e-4c01-9d10-700000000001");

    @Override public String getName() { return "P10 Entrancer Bridge"; }
    @Override public String getAuthor() { return "P10 Entrancer contributors"; }
    @Override public String getVersion() { return "0.1.0"; }
    @Override public UUID getId() { return EXTENSION_ID; }
    @Override public String getHardwareVendor() { return "P10 Entrancer"; }
    @Override public String getHardwareModel() { return "Bridge"; }
    @Override public int getRequiredAPIVersion() { return 22; }
    @Override public int getNumMidiInPorts() { return 1; }
    @Override public int getNumMidiOutPorts() { return 1; }

    @Override
    public void listAutoDetectionMidiPortNames(AutoDetectionMidiPortNamesList list, PlatformType platform) {
        // No autodetect — user picks the MIDI output port (IAC, Network Session, USB-MIDI to iPad).
    }

    @Override
    public P10EBridgeExtension createInstance(ControllerHost host) {
        return new P10EBridgeExtension(this, host);
    }
}
