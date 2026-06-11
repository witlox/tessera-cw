import SwiftUI

/// Custom alpha keyboard. We don't use the system keyboard because the board
/// needs to stay visible — there's no text field involved, just letter input.
struct KeyboardView: View {
    let onLetter: (Character) -> Void
    let onBackspace: () -> Void
    let onSwap: () -> Void

    private let rows: [String] = [
        "QWERTYUIOP",
        "ASDFGHJKL",
        "ZXCVBNM"
    ]

    var body: some View {
        VStack(spacing: 6) {
            ForEach(0..<rows.count, id: \.self) { idx in
                HStack(spacing: 4) {
                    if idx == 2 {
                        IconKey(systemImage: "arrow.left.arrow.right", action: onSwap)
                    }
                    ForEach(Array(rows[idx]), id: \.self) { ch in
                        LetterKey(letter: ch, action: { onLetter(ch) })
                    }
                    if idx == 2 {
                        IconKey(systemImage: "delete.left", action: onBackspace)
                    }
                }
            }
        }
    }
}

private struct LetterKey: View {
    let letter: Character
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(String(letter))
                .font(.system(size: 18, weight: .medium, design: .rounded))
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(Color(.secondarySystemFill))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

private struct IconKey: View {
    let systemImage: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 48, minHeight: 44)
                .background(Color(.secondarySystemFill))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}
