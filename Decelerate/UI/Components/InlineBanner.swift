import SwiftUI

/// Small inline notice used for permission, error, and empty states.
///
/// Kept deliberately lightweight so it reads like a system alert inside the
/// menu bar panel instead of custom-drawn chrome.
struct InlineBanner: View {
    let systemImage: String
    let tint: Color
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .buttonStyle(.link)
                        .font(.caption)
                        .padding(.top, 2)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(tint.opacity(0.18), lineWidth: 1)
        )
    }
}

#Preview {
    VStack(spacing: 10) {
        InlineBanner(
            systemImage: "xmark.octagon.fill",
            tint: .red,
            title: "Couldn't Apply Settings",
            message: "macOS rejected a pointer acceleration setting.",
            actionTitle: "Try Again",
            action: {}
        )
        InlineBanner(
            systemImage: "computermouse",
            tint: .secondary,
            title: "No Pointing Devices",
            message: "Connect a mouse or trackpad, then refresh.",
            actionTitle: "Refresh",
            action: {}
        )
    }
    .padding()
    .frame(width: 320)
}
