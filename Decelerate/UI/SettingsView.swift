import SwiftUI

/// The app's Settings window, presented by the SwiftUI `Settings` scene.
///
/// The system draws the window chrome and the preference-toolbar tabs, so the
/// three tabs here deliberately stay plain: grouped forms, standard controls,
/// and SF Symbols only.
struct SettingsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            DevicesSettingsTab()
                .tabItem {
                    Label("Devices", systemImage: "computermouse")
                }

            AboutSettingsTab()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        // Tall enough for the General tab (including the restore button) and
        // identical across tabs so the window never jumps when switching.
        .frame(width: 560, height: 640)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @EnvironmentObject private var state: AppState
    @State private var isConfirmingRestore = false

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $state.launchAtLogin)
                Toggle("Show Decelerate in the Dock", isOn: $state.showDockIcon)
            } header: {
                Text("Startup")
            } footer: {
                Text("Launch Decelerate automatically when you log in. The Dock icon is optional for a menu bar app.")
            }

            Section {
                LabeledContent("Status") {
                    StatusBadge(status: state.status, label: state.statusPillLabel)
                }
                LabeledContent("Mode") {
                    Text(state.activeSummary)
                }
                LabeledContent("Devices") {
                    Text(state.connectedDeviceSummary)
                }
                LabeledContent("Pointer parameters") {
                    Text(state.systemParameterSummary)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
                LabeledContent("Version") {
                    Text(state.appVersion)
                }
            } header: {
                Text("Pointer")
            } footer: {
                Text("Decelerate restores macOS acceleration when you quit.")
            }

            Section {
                Button("Restore System Defaults…", role: .destructive) {
                    isConfirmingRestore = true
                }
                .confirmationDialog(
                    "Restore macOS pointer defaults?",
                    isPresented: $isConfirmingRestore
                ) {
                    Button("Restore Defaults", role: .destructive) {
                        state.restoreSystemDefaults()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Decelerate will return pointer acceleration to the macOS default and put your Mac's pointer settings back the way they were before Decelerate started.")
                }
            } footer: {
                Text("Use this to return to the system's standard pointer acceleration.")
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
    }
}

// MARK: - Devices

private struct DevicesSettingsTab: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if state.devices.isEmpty {
                    ContentUnavailableView {
                        Label("No Pointing Devices", systemImage: "computermouse")
                    } description: {
                        Text("Connect a mouse or trackpad to see it here.")
                    } actions: {
                        Button("Refresh") {
                            state.refreshDevices()
                        }
                    }
                } else {
                    Form {
                        Section {
                            ForEach(state.devices) { device in
                                DeviceRow(device: device)
                            }
                        } header: {
                            Text("Connected Devices")
                        } footer: {
                            Text("Decelerate applies your Trackpad or Mouse settings to each device based on its class.")
                        }
                    }
                    .formStyle(.grouped)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack(spacing: 8) {
                Text(state.connectedDeviceSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 8)

                Button {
                    state.refreshDevices()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .help("Refresh the list of connected devices")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
        }
        .onAppear { state.refreshDevices() }
    }
}

// MARK: - About

private struct AboutSettingsTab: View {
    @EnvironmentObject private var state: AppState
    @State private var isShowingHowItWorks = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(spacing: 14) {
                AppGlyph(size: 72)

                VStack(spacing: 4) {
                    Text("Decelerate")
                        .font(.title2.weight(.semibold))

                    Text("Version \(state.appVersion)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Text("Decelerate removes macOS pointer acceleration so a given hand movement always moves the cursor the same distance. Trackpad and mouse movement feel direct and consistent — like Windows with “Enhance pointer precision” turned off.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
                    .fixedSize(horizontal: false, vertical: true)

                DisclosureGroup("How it works", isExpanded: $isShowingHowItWorks) {
                    Text("Decelerate tells macOS's HID event system how much pointer acceleration to apply: 0% passes raw pointer deltas straight through for exact 1:1 movement, 100% is macOS's own acceleration curve, and intermediate values are a genuine blend of the two. A separate Speed control (0.5×–2×, with 1.5× in the middle) scales 1:1 movement, since macOS's unaccelerated pointer is intentionally slower at ordinary hand speed (Windows has the same pointer-speed slider with Enhance pointer precision off). No events are intercepted, no permissions are needed, and quitting Decelerate restores the original settings.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                }
                .font(.callout)
                .frame(maxWidth: 400, alignment: .leading)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Previews

#Preview("Settings") {
    SettingsView()
        .environmentObject(AppState.shared)
}
