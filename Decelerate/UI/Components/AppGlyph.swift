import SwiftUI

/// The app's visual mark: a pointer glyph on a tinted, continuous-corner tile.
///
/// Used in the menu bar panel header and in the About tab. It is drawn from
/// system colors so it matches the accent color, appearance and
/// accessibility settings of the Mac.
struct AppGlyph: View {
    var size: CGFloat = 34

    private var cornerRadius: CGFloat { size * 0.28 }

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color.accentColor.opacity(0.92),
                        Color.accentColor.opacity(0.68)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: "cursorarrow.motionlines")
                    .font(.system(size: size * 0.48, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.16), radius: size * 0.08, y: 1)
            .accessibilityHidden(true)
    }
}

#Preview {
    HStack(spacing: 16) {
        AppGlyph(size: 34)
        AppGlyph(size: 72)
    }
    .padding()
    .environmentObject(AppState.shared)
}
