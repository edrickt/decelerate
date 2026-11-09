import SwiftUI

/// One pointer-class control card inside the menu bar panel.
///
/// The slider maps to a real, continuous acceleration amount: 0% is exact 1:1
/// movement (macOS applies no acceleration curve), 100% is macOS's own curve,
/// and intermediate values are a genuine blend.
struct PointerClassCard: View {
    let pointerClass: PointerClass

    @EnvironmentObject private var state: AppState

    private var amount: Double {
        state.preferences(for: pointerClass).accelerationAmount
    }

    private var percent: Int {
        Int((amount * 100).rounded())
    }

    private var isReduced: Bool {
        amount < 0.995
    }

    private var caption: String {
        switch percent {
        case 0:
            return "No acceleration — 1:1 movement, uses your macOS tracking speed"
        case 100:
            return "macOS default acceleration"
        default:
            return "Blended acceleration (\(percent)%)"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                Image(systemName: pointerClass.systemImage)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isReduced ? Color.accentColor : Color.secondary)
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

                Spacer(minLength: 8)

                Text("\(percent)%")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
                    .accessibilityHidden(true)
            }

            HStack(spacing: 6) {
                Text("None")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)

                Slider(value: state.binding(for: pointerClass).accelerationAmount, in: 0...1)
                    .controlSize(.small)
                    .accessibilityLabel("Acceleration for \(pointerClass.title.lowercased())")

                Text("Default")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }

            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .topLeading)
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
