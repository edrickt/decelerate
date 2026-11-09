import SwiftUI

/// Placeholder implementation. The settings window is owned by the UI work:
/// a native macOS preferences window (TabView tabs drawn by the system).
struct SettingsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        TabView {
            Form {
                Toggle("Launch at login", isOn: $state.launchAtLogin)
                Toggle("Show icon in Dock", isOn: $state.showDockIcon)
                Button("Restore system defaults") { state.restoreSystemDefaults() }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }

            Text("Devices")
                .tabItem { Label("Devices", systemImage: "computermouse") }

            Text("About Decelerate \(state.appVersion)")
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 480, height: 300)
    }
}
