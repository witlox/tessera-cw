import SwiftUI
import TesseraKit

struct CluePanel: View {
    let entry: PlacedEntry?
    let state: GameState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if let entry {
                    Text(directionLabel(for: entry))
                        .font(.caption).foregroundStyle(.secondary)
                    Text("\(entry.entry.length)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                    Text(entry.entry.language.displayName)
                        .font(.caption).foregroundStyle(.tertiary)
                }
                Spacer()
            }
            Text(entry?.entry.clue ?? "Tap a cell to start.")
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(3)
        }
        .padding(10)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func directionLabel(for entry: PlacedEntry) -> String {
        entry.orientation == .across ? "ACROSS" : "DOWN"
    }
}
