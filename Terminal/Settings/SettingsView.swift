import SwiftUI

/// Settings sheet. Grouped form on a dark surface, accent chips
/// for glyphs — no explanatory copy anywhere.
struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var keepAlive: KeepAliveEngine

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(selection: $settings.settings.appearance) {
                        Text("Dark").tag(AppSettings.Appearance.dark)
                        Text("Light").tag(AppSettings.Appearance.light)
                        Text("System").tag(AppSettings.Appearance.system)
                    } label: {
                        rowLabel("Appearance", icon: "circle.lefthalf.filled")
                    }

                    NavigationLink {
                        ThemePickerView()
                    } label: {
                        HStack {
                            rowLabel("Theme", icon: "paintpalette")
                            Spacer()
                            Text(TerminalTheme.theme(id: settings.settings.themeID).displayName)
                                .foregroundStyle(.secondary)
                        }
                    }

                    HStack(spacing: 12) {
                        Text("Aa")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                        Slider(value: $settings.settings.fontSize, in: 10...18, step: 1)
                        Text("Aa")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    .onChange(of: settings.settings.fontSize) { _, _ in
                        Haptics.select()
                    }
                }

                Section {
                    Toggle(isOn: $settings.settings.keepAlive) {
                        rowLabel("Background sessions", icon: "antenna.radiowaves.left.and.right")
                    }
                    .onChange(of: settings.settings.keepAlive) { _, on in
                        keepAlive.setEnabled(on)
                    }

                    Toggle(isOn: $settings.settings.remoteClipboard) {
                        rowLabel("Remote clipboard", icon: "doc.on.clipboard")
                    }

                    if BiometricGate.available {
                        Toggle(isOn: $settings.settings.requireBiometry) {
                            rowLabel("Passcode or Face ID", icon: "faceid")
                        }
                    }

                    Toggle(isOn: $settings.settings.haptics) {
                        rowLabel("Haptics", icon: "iphone.radiowaves.left.and.right")
                    }
                    .onChange(of: settings.settings.haptics) { _, on in
                        Haptics.setEnabled(on)
                    }

                    Toggle(isOn: $settings.settings.autoReconnect) {
                        rowLabel("Auto-reconnect", icon: "arrow.triangle.2.circlepath")
                    }

                    Toggle(isOn: $settings.settings.autoTmux) {
                        rowLabel("Sessions persist", icon: "clock.arrow.circlepath")
                    }

                    Toggle(isOn: $settings.settings.showKeyboardBar) {
                        rowLabel("Extra keys", icon: "keyboard")
                    }

                    LabeledContent {
                        TextField("/bin/zsh", text: $settings.settings.shellOverride)
                            .multilineTextAlignment(.trailing)
                            .font(.system(.body, design: .monospaced))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } label: {
                        rowLabel("Shell", icon: "terminal")
                    }
                }

                Section {
                    NavigationLink {
                        KeysListView()
                    } label: {
                        rowLabel("Keys", icon: "key.fill")
                    }

                    NavigationLink {
                        SnippetsListView()
                    } label: {
                        rowLabel("Snippets", icon: "chevron.left.forwardslash.chevron.right")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.terminalSurface.ignoresSafeArea())
            .tint(.terminalAccent)
            .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        }
    }

    /// Settings-style row: accent rounded square with a white glyph + title.
    private func rowLabel(_ title: String, icon: String) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(
                    Color.terminalAccent,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
        }
    }
}
