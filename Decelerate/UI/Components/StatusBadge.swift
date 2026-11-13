import SwiftUI

/// Compact status pill for the current pointer state.
///
/// Green when Decelerate is shaping the pointer (reduced acceleration or a
/// non-1× Speed), red for a failure, and neutral grey when macOS's own
/// acceleration and 1× speed are fully in effect.
struct StatusBadge: View {
    let status: AppState.Status

    /// Optional display text. The model's `Status.title` describes the fully
    /// linear case; partial acceleration amounts get a qualified label.
    var label: String?

    private var displayLabel: String {
        label ?? status.title
    }

    private var tint: Color {
        switch status {
        case .active: return .green
        case .failed: return .red
        case .idle: return .secondary
        }
    }

    private var fillOpacity: Double {
        status == .idle ? 0.08 : 0.14
    }

    private var borderOpacity: Double {
        status == .idle ? 0.14 : 0.24
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)

            Text(displayLabel)
                .font(.caption2.weight(.medium))
                .foregroundStyle(status == .idle ? Color.secondary : Color.primary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint.opacity(fillOpacity), in: Capsule())
        .overlay(Capsule().strokeBorder(tint.opacity(borderOpacity), lineWidth: 0.5))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Status: \(displayLabel)")
    }
}

extension AppState {
    /// Display text for the status pill.
    ///
    /// `Status.active` only says that Decelerate is shaping the pointer. With a
    /// continuous amount plus a separate Speed control, "1:1 Pointer" is only
    /// right when every class is fully linear at 1× speed; partial amounts and
    /// speed-only overrides are presented as "Custom".
    var statusPillLabel: String {
        guard status == .active else { return status.title }
        let isIdentity = PointerClass.allCases.allSatisfy {
            let category = preferences(for: $0)
            return category.accelerationAmount <= 0.005
                && abs(category.speedMultiplier - 1.0) < 0.01
        }
        return isIdentity ? status.title : "Custom"
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 8) {
        StatusBadge(status: .active)
        StatusBadge(status: .active, label: "Custom")
        StatusBadge(status: .idle)
        StatusBadge(status: .failed("The HID event system rejected the change."))
    }
    .padding()
}
