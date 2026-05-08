import SwiftUI

struct SessionPanelView: View {
    @ObservedObject var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var showResetAlert = false
    @State private var showSaveAlert = false
    @State private var saveDraft: String = ""
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
            actionRow
            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
            presetsList
        }
        .background(.black)
        .preferredColorScheme(.dark)
        .alert("Reset everything to factory defaults? This cannot be undone.", isPresented: $showResetAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                AppState.shared.resetToFactoryDefaults()
                AppState.shared.liveRecordings.clearRecent()
                store.hasUnsavedChanges = false
            }
        }
        .alert("Save session", isPresented: $showSaveAlert) {
            TextField("Session name", text: $saveDraft)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let trimmed = saveDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                _ = AppState.shared.saveCurrentSession(as: trimmed)
                saveDraft = ""
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsPanelView(store: store)
        }
    }

    private var header: some View {
        HStack {
            Text("SESSION")
                .font(.system(size: 14, weight: .heavy, design: .monospaced))
                .tracking(2.0)
                .foregroundStyle(.white)
            if store.hasUnsavedChanges {
                Text("· UNSAVED")
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.yellow)
            }
            Spacer()
            Button("CLOSE") { dismiss() }
                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            actionButton(label: "DEFAULT", tint: .red) { showResetAlert = true }
            actionButton(label: "SAVE…", tint: .green) {
                saveDraft = ""
                showSaveAlert = true
            }
            Spacer()
            settingsButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func actionButton(label: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white)
                .frame(width: 110, height: 40)
                .background(Color.white.opacity(0.06))
                .overlay(Rectangle().strokeBorder(tint.opacity(0.8), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var settingsButton: some View {
        Button(action: { showSettings = true }) {
            HStack(spacing: 4) {
                Image(systemName: "gearshape")
                Text("SETTINGS")
                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
            }
            .foregroundStyle(.white)
            .frame(height: 40)
            .padding(.horizontal, 12)
            .background(Color.white.opacity(0.06))
            .overlay(Rectangle().strokeBorder(Color.white.opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var presetsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("PRESETS")
                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                    .tracking(2.0)
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 4)

            ScrollView {
                LazyVStack(spacing: 0) {
                    presetRow(name: SessionStore.factoryName, isFactory: true)
                    Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
                    ForEach(store.savedNames, id: \.self) { name in
                        presetRow(name: name, isFactory: false)
                        Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
                    }
                }
            }
        }
    }

    private func presetRow(name: String, isFactory: Bool) -> some View {
        let isDefault = store.defaultPresetName == name
        return HStack {
            Text(name)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.white)
            if isDefault {
                Text("DEFAULT")
                    .font(.system(size: 9, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.cyan)
            }
            Spacer()
            if isFactory {
                Button("LOAD") {
                    AppState.shared.resetToFactoryDefaults()
                }
                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white)
            } else {
                Button("LOAD") {
                    AppState.shared.loadSession(named: name)
                }
                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white)
                Button("DELETE") {
                    store.delete(name)
                }
                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

struct SettingsPanelView: View {
    @ObservedObject var store: SessionStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("SETTINGS")
                    .font(.system(size: 14, weight: .heavy, design: .monospaced))
                    .tracking(2.0)
                    .foregroundStyle(.white)
                Spacer()
                Button("CLOSE") { dismiss() }
                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("DEFAULT PRESET ON LAUNCH")
                        .font(.system(size: 11, weight: .heavy, design: .monospaced))
                        .tracking(2.0)
                        .foregroundStyle(.white.opacity(0.6))

                    VStack(spacing: 0) {
                        presetChoice(SessionStore.factoryName)
                        ForEach(store.savedNames, id: \.self) { name in
                            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
                            presetChoice(name)
                        }
                    }
                    .overlay(Rectangle().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))

                    Text("ABOUT")
                        .font(.system(size: 11, weight: .heavy, design: .monospaced))
                        .tracking(2.0)
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.top, 8)
                    Text("p10trancer · v\(appVersion) (build \(appBuild))")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white)
                }
                .padding(20)
            }
        }
        .background(.black)
        .preferredColorScheme(.dark)
    }

    private func presetChoice(_ name: String) -> some View {
        let isDefault = store.defaultPresetName == name
        return Button(action: { store.defaultPresetName = name }) {
            HStack {
                Image(systemName: isDefault ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isDefault ? .cyan : .white.opacity(0.5))
                Text(name)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.white)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    private var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }
}
