import SwiftUI

/// One pointer-class control card inside the menu bar panel.
///
/// Acceleration is a continuous blend between no acceleration (0%, exact 1:1
/// movement) and macOS's own curve (100%). Because an unaccelerated pointer is
/// intentionally slower at normal hand speed, a separate Speed control scales
/// the 1:1 movement — the Windows pointer-speed slider with "Enhance pointer
/// precision" off. Its 0.5×–2× range is logarithmic so 1× sits in the middle.
struct PointerClassCard: View {
    let pointerClass: PointerClass

    @EnvironmentObject private var state: AppState

    private var amount: Double {
        state.preferences(for: pointerClass).accelerationAmount
    }

    private var speed: Double {
        state.preferences(for: pointerClass).speedMultiplier
    }

    private var percent: Int {
        Int((amount * 100).rounded())
    }

    private var isReduced: Bool {
        amount < 0.995
    }

    private var speedText: String {
        String(format: "%.2f×", speed)
    }

    /// Logarithmic mapping so 1.00× is exactly the middle of the slider.
    private var speedPositionBinding: Binding<Double> {
        Binding(
            get: { SpeedScale.position(for: speed) },
            set: { position in
                state.setSpeedMultiplier(SpeedScale.speed(for: position), for: pointerClass)
            }
        )
    }

    private var accelerationCaption: String {
        switch percent {
        case 0:
            return "No acceleration — 1:1 movement"
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
                    .frame(width: 34, alignment: .leading)
                    .accessibilityHidden(true)

                Slider(value: state.binding(for: pointerClass).accelerationAmount, in: 0...1)
                    .controlSize(.small)
                    .accessibilityLabel("Acceleration for \(pointerClass.title.lowercased())")

                Text("Default")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(width: 44, alignment: .trailing)
                    .accessibilityHidden(true)
            }

            HStack(spacing: 6) {
                Text("Speed")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(width: 34, alignment: .leading)
                    .accessibilityHidden(true)

                Slider(value: speedPositionBinding, in: 0...1)
                    .controlSize(.small)
                    .accessibilityLabel("Speed for \(pointerClass.title.lowercased())")
                    .help("0.5×–2× — 1.5× in the middle; 1× is geometry-true 1:1")

                Text(speedText)
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(accelerationCaption)
                Text("Speed 0.5×–2× · 1.5× in the middle")
                    .foregroundStyle(.tertiary)
            }
            .font(.caption)
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
