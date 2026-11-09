import SwiftUI

/// One pointer-class control card inside the menu bar panel.
///
/// Removing acceleration is all-or-nothing in the HID layer: the system passes
/// raw pointer deltas through and speed follows the Mac's own tracking-speed
/// setting, so there is no separate sensitivity control.
struct PointerClassCard: View {
    let pointerClass: PointerClass

    @EnvironmentObject private var state: AppState

    private var isRemovingAcceleration: Bool {
        state.preferences(for: pointerClass).removeAcceleration
    }

    private var caption: String {
        isRemovingAcceleration
            ? "1:1 movement, uses your macOS tracking speed"
            : "macOS pointer acceleration is active"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                Image(systemName: pointerClass.systemImage)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isRemovingAcceleration ? Color.accentColor : Color.secondary)
                    .frame(width: 22, height: 22)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    Text(pointerClass.title)
                        .font(.subheadline.weight(.semibold))

                    Text(pointerClass.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                Text("Remove acceleration")
                    .font(.callout)

                Spacer(minLength: 8)

                Toggle("Remove acceleration for \(pointerClass.title.lowercased())",
                       isOn: state.binding(for: pointerClass).removeAcceleration)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("Replace macOS acceleration with 1:1 pointer movement")
            }

            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

#Preview {
    VStack(spacing: 10) {
        PointerClassCard(pointerClass: .trackpad)
        PointerClassCard(pointerClass: .mouse)
    }
    .padding()
    .frame(width: 320)
    .environmentObject(AppState.shared)
}
