import SwiftUI

/// One row in the Devices list in Settings.
struct DeviceRow: View {
    let device: PointerDevice

    private var kindTitle: String {
        if device.isBuiltIn { return "Built-in trackpad" }
        switch device.kind {
        case .trackpad: return "Trackpad"
        case .mouse: return "Mouse"
        case .unknown: return "Pointing device"
        }
    }

    private var iconName: String {
        if device.isBuiltIn { return "laptopcomputer" }
        switch device.kind {
        case .trackpad: return "rectangle.and.hand.point.up.left"
        case .mouse: return "computermouse"
        case .unknown: return "questionmark.circle"
        }
    }

    private var identifier: String {
        String(format: "Vendor 0x%04X · Product 0x%04X", device.vendorID, device.productID)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(device.name)
                        .font(.callout)

                    if device.isBuiltIn {
                        Text("Built-in")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.primary.opacity(0.07), in: Capsule())
                    }
                }

                Text("\(kindTitle) · \(identifier)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(device.pointerClass.title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.06), in: Capsule())
                .help("Uses your \(device.pointerClass.title.lowercased()) settings")
        }
        .padding(.vertical, 3)
    }
}
