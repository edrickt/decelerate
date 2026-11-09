import SwiftUI

/// Placeholder implementation. The menu bar panel is owned by the UI work:
/// a compact, native-looking popover with a status header, per-class toggles,
/// speed sliders, and Settings/Quit actions.
struct MenuBarPanel: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: state.menuBarSymbol)
                Text("Decelerate").font(.headline)
                Spacer()
                Text(state.status.title).font(.caption)
            }

            ForEach(PointerClass.allCases) { pointerClass in
                Toggle(pointerClass.title, isOn: Binding(
                    get: { state.preferences(for: pointerClass).removeAcceleration },
                    set: { state.setRemoveAcceleration($0, for: pointerClass) }
                ))
                .toggleStyle(.switch)
            }

            Divider()

            HStack {
                Button("Settings…") { openSettings() }
                Spacer()
                Button("Quit") { state.quit() }
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}
