import SwiftUI

/// The menu bar panel shown from the `MenuBarExtra` (`.window` style).
///
/// A compact status header, one card per pointer class, and Settings / Quit
/// actions. Everything is driven by `AppState`, so changes apply and persist
/// as soon as they are made.
struct MenuBarPanel: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let error = state.lastError, !error.isEmpty {
                InlineBanner(
                    systemImage: "xmark.octagon.fill",
                    tint: .red,
                    title: "Couldn't Apply Settings",
                    message: error,
                    actionTitle: "Try Again",
                    action: { state.reapply() }
                )
            }

            if state.devices.isEmpty {
                InlineBanner(
                    systemImage: "computermouse",
                    tint: .secondary,
                    title: "No Pointing Devices",
                    message: "Connect a mouse or trackpad, then refresh.",
                    actionTitle: "Refresh",
                    action: { state.refreshDevices() }
                )
            }

            VStack(spacing: 10) {
                ForEach(PointerClass.allCases) { pointerClass in
                    PointerClassCard(pointerClass: pointerClass)
                }
            }

            footer
        }
        .padding(14)
        .frame(width: 320)
        .onAppear { state.refreshDevices() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            AppGlyph(size: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text("Decelerate")
                    .font(.headline)

                Text(state.connectedDeviceSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)

            StatusBadge(status: state.status)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 8) {
            Text("Quitting restores macOS acceleration.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)

            Divider()

            HStack(spacing: 12) {
                Button("Settings…") {
                    openSettings()
                }
                .buttonStyle(.link)

                Spacer(minLength: 0)

                Button("Quit") {
                    state.quit()
                }
                .buttonStyle(.link)
                .keyboardShortcut("q", modifiers: .command)
            }
            .font(.callout)

            Text("Version \(state.appVersion)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
        }
    }
}
