import SwiftUI

/// One pointer-class control card inside the menu bar panel.
///
/// Acceleration is a continuous blend between no acceleration (0%, exact 1:1
/// movement) and macOS's own curve (100%). Because an unaccelerated pointer is
/// slower at normal hand speed, a separate Speed control scales
/// the 1:1 movement, like the Windows pointer-speed slider with "Enhance pointer
/// precision" off. Its 0.5×–2× range is logarithmic so 1.5× sits in the middle.
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

    /// Logarithmic mapping so 1.50× is exactly the middle of the slider.
    private var speedPositionBinding: Binding<Double> {
        Binding(
            get: { SpeedScale.position(for: speed) },
            set: { position in
                state.setSpeedMultiplier(SpeedScale.speed(for: position), for: pointerClass)
            }
        )
    }

    private var scrollAmount: Double {
        state.preferences(for: pointerClass).scrollAccelerationAmount
    }

    private var scrollSpeed: Double {
        state.preferences(for: pointerClass).scrollSpeedMultiplier
    }

    private var scrollPercent: Int {
        Int((scrollAmount * 100).rounded())
    }

    private var scrollSpeedText: String {
        String(format: "%.2f×", scrollSpeed)
    }

    private var isInvertedScroll: Bool {
        state.preferences(for: pointerClass).invertScroll
    }

    /// Coalesces the applies of a slider drag: the model applies at a much lower
    /// rate while the thumb is held, then once more when it is released.
    private var editHandler: (Bool) -> Void {
        { editing in
            if editing {
                state.beginInteractiveChange()
            } else {
                state.endInteractiveChange()
            }
        }
    }

    private var scrollSpeedPositionBinding: Binding<Double> {
        Binding(
            get: { SpeedScale.position(for: scrollSpeed) },
            set: { position in
                state.setScrollSpeedMultiplier(SpeedScale.speed(for: position), for: pointerClass)
            }
        )
    }

    private var scrollCaption: String {
        let category = state.preferences(for: pointerClass)
        if category.isScrollNative {
            return "macOS default scrolling"
        }
        var parts: [String] = []
        if category.invertScroll {
            // Inverted scrolling installs a constant negative-gain curve: a
            // negated blend cannot stay negative (see AccelerationController),
            // so the installed curve has no acceleration sharing and the amount
            // slider does not apply.
            parts.append("Linear scroll")
        } else {
            switch scrollPercent {
            case 0:
                parts.append("Linear scroll")
            case 100:
                parts.append("macOS scroll curve")
            default:
                parts.append("Blended scroll \(scrollPercent)%")
            }
        }
        if abs(scrollSpeed - 1.0) >= 0.01 {
            parts.append(scrollSpeedText)
        }
        if category.invertScroll {
            parts.append("inverted")
        }
        return parts.joined(separator: " · ")
    }

    private var accelerationCaption: String {
        switch percent {
        case 0:
            return abs(speed - 1.0) < 0.01
                ? "No acceleration: 1:1 movement"
                : "No acceleration: linear movement"
        case 100:
            // At 100% the macOS curve is still scaled by Speed when it is not
            // 1x, so claiming "macOS default acceleration" would be wrong.
            return abs(speed - 1.0) < 0.01
                ? "macOS default acceleration"
                : "macOS curve at \(speedText) speed"
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

                Slider(
                    value: state.binding(for: pointerClass).accelerationAmount,
                    in: 0...1,
                    onEditingChanged: editHandler
                )
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

                Slider(value: speedPositionBinding, in: 0...1, onEditingChanged: editHandler)
                    .controlSize(.small)
                    .accessibilityLabel("Speed for \(pointerClass.title.lowercased())")
                    .help("0.5×–2×, with 1.5× in the middle; 1× is geometry-true 1:1")

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

            Divider()

            // Scroll shaping for this device class. The invert toggle is
            // mouse-only: it installs a negative-gain curve on the mouse wheel
            // only, so the trackpad keeps macOS's direction.
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("Scroll")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 8)

                    // While inverted the installed curve is a constant negative
                    // gain, so the amount has nothing to shape. Showing a
                    // percentage would claim a blend that is not applied.
                    Text(isInvertedScroll ? "—" : "\(scrollPercent)%")
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                        .accessibilityHidden(true)
                }

                HStack(spacing: 6) {
                    Text("Linear")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(width: 34, alignment: .leading)
                        .accessibilityHidden(true)

                    Slider(
                        value: state.binding(for: pointerClass).scrollAccelerationAmount,
                        in: 0...1,
                        onEditingChanged: editHandler
                    )
                    .controlSize(.small)
                    .disabled(isInvertedScroll)
                    .accessibilityLabel("Scroll acceleration for \(pointerClass.title.lowercased())")
                    .help(isInvertedScroll
                        ? "Inverted scroll uses a linear curve; the amount is not applied"
                        : "0% is linear scrolling, 100% is macOS's own scroll curve")

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

                    Slider(value: scrollSpeedPositionBinding, in: 0...1, onEditingChanged: editHandler)
                        .controlSize(.small)
                        .accessibilityLabel("Scroll speed for \(pointerClass.title.lowercased())")
                        .help("0.5×–2×, with 1.5× in the middle; 1× is macOS's own scroll distance")

                    Text(scrollSpeedText)
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                        .accessibilityHidden(true)
                }

                if pointerClass == .mouse {
                    Toggle("Invert scroll direction", isOn: state.binding(for: pointerClass).invertScroll)
                        .font(.caption)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .accessibilityLabel("Invert mouse scroll direction")
                        .help("Flips the mouse wheel only; the trackpad keeps its direction. "
                            + "Inverted scrolling is linear, so the Scroll amount does not apply.")
                }

                Text(scrollCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
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
