import SwiftUI

/// Compact status pill for the current pointer state.
///
/// Green when pointer movement is 1:1, red for a failure, and neutral grey when
/// everything is off.
struct StatusBadge: View {
    let status: AppState.Status

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

            Text(status.title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(status == .idle ? Color.secondary : Color.primary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint.opacity(fillOpacity), in: Capsule())
        .overlay(Capsule().strokeBorder(tint.opacity(borderOpacity), lineWidth: 0.5))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Status: \(status.title)")
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 8) {
        StatusBadge(status: .active)
        StatusBadge(status: .idle)
        StatusBadge(status: .failed("The HID event system rejected the change."))
    }
    .padding()
}
