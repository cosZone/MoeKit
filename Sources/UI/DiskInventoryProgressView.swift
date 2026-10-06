import SwiftUI

struct DiskInventoryProgressView: View {
    let progress: DirectoryScanProgress
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(progress.phase == .sizing ? "Measuring readable file sizes…" : "Checking cleanup eligibility…")
                .font(.caption)
            ProgressView(value: Double(progress.finished), total: Double(max(1, progress.total)))
            Text("\(progress.finished) of \(progress.total) items").font(.caption).monospacedDigit()
            if let path = progress.currentPath {
                Text(InstallerPathDisplay.quoted(path)).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).help(InstallerPathDisplay.quoted(path))
            }
        }.accessibilityElement(children: .combine)
    }
}
