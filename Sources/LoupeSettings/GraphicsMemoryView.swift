import LoupeCore
import SwiftUI

/// Settings › Performance › Graphics memory (a discrete card only): how much of the card's memory Loupe keeps pictures
/// in. Read-only, since the amount follows the card (no key); laid out as a `RowView`: symbol, title, a line below.
struct GraphicsMemoryView: View {
    let profile: MachineProfile

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Image(systemName: "cpu")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 16)
                .padding(.horizontal, 6)
            VStack(alignment: .leading, spacing: 6) {
                Text("Graphics memory")
                    .font(.system(size: 13))
                    .frame(minHeight: 16)
                Text(Self.text(for: profile))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
        }
        .padding(.vertical, 12)
        .padding(.trailing, 8)
    }

    /// «4.3 GB of 8.6 GB on AMD Radeon Pro 5500 XT, set by Loupe for this card»: the tier, the card's working set
    /// (what Metal reports for it) and the card.
    static func text(for p: MachineProfile) -> String {
        "\(bytes(HardwareAdvice.graphicsMemory(p) ?? 0)) of \(bytes(p.gpu.workingSetBytes)) on \(p.gpu.name), "
            + "set by Loupe for this card"
    }

    /// Decimal gigabytes with one decimal, as the notes spell them (`ByteCountFormatter` gives 4.29 GB here).
    static func bytes(_ n: Int) -> String { HardwareAdvice.decimalGB(n) }
}
