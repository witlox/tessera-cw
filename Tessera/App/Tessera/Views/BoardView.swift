import SwiftUI
import TesseraKit

/// Square grid view. Cells outside the puzzle bounds are drawn as blanks
/// (background-coloured); placed cells are bordered and accept taps to select.
struct BoardView: View {
    let puzzle: Puzzle
    let state: GameState
    /// Tap → set selection. Orientation is inferred from the entry the cell sits on.
    let select: (Coord, Orientation) -> Void

    private var bounds: (rMin: Int, rMax: Int, cMin: Int, cMax: Int) {
        let rs = puzzle.solution.keys.map(\.r)
        let cs = puzzle.solution.keys.map(\.c)
        return (rs.min() ?? 0, rs.max() ?? 0, cs.min() ?? 0, cs.max() ?? 0)
    }

    var body: some View {
        let b = bounds
        let rows = b.rMax - b.rMin + 1
        let cols = b.cMax - b.cMin + 1
        let dim = max(rows, cols)

        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let cell = size / CGFloat(dim)
            ZStack(alignment: .topLeading) {
                Color.clear
                ForEach(0..<rows, id: \.self) { r in
                    ForEach(0..<cols, id: \.self) { c in
                        let coord = Coord(b.rMin + r, b.cMin + c)
                        if puzzle.solution[coord] != nil {
                            cellView(coord: coord, dim: cell)
                                .offset(x: CGFloat(c) * cell, y: CGFloat(r) * cell)
                                .onTapGesture { handleTap(coord) }
                        }
                    }
                }
            }
            .frame(width: size, height: size)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    @ViewBuilder
    private func cellView(coord: Coord, dim: CGFloat) -> some View {
        let letter = state.effectiveLetter(coord, in: puzzle)
        let isSelected = state.selection?.origin == coord
        let inEntry = isInCurrentEntry(coord)
        let isRevealed = state.revealed.contains(coord) || state.revealedByOpponent.contains(coord)
        ZStack {
            Rectangle()
                .fill(background(isSelected: isSelected, inEntry: inEntry))
            Rectangle()
                .stroke(Color.primary.opacity(0.4), lineWidth: 0.5)
            if let letter {
                Text(String(letter))
                    .font(.system(size: dim * 0.55, weight: .semibold, design: .rounded))
                    .foregroundStyle(isRevealed ? Color.accentColor : Color.primary)
            }
            if let cluePos = clueNumber(at: coord) {
                Text("\(cluePos)")
                    .font(.system(size: dim * 0.22))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.leading, 2)
                    .padding(.top, 1)
            }
        }
        .frame(width: dim, height: dim)
    }

    private func background(isSelected: Bool, inEntry: Bool) -> Color {
        if isSelected { return Color.accentColor.opacity(0.35) }
        if inEntry { return Color.accentColor.opacity(0.12) }
        return Color(.systemBackground)
    }

    private func isInCurrentEntry(_ coord: Coord) -> Bool {
        guard let sel = state.selection else { return false }
        guard let entry = puzzle.placed.first(where: {
            $0.orientation == sel.orientation && $0.cells.contains(sel.origin)
        }) else { return false }
        return entry.cells.contains(coord)
    }

    private func handleTap(_ coord: Coord) {
        // If tapping the already-selected cell, swap orientation.
        if state.selection?.origin == coord {
            let other: Orientation = state.selection?.orientation == .across ? .down : .across
            select(coord, other)
            return
        }
        // Prefer the existing orientation if the new cell is on such an entry.
        let preferred: Orientation = state.selection?.orientation ?? .across
        if puzzle.placed.contains(where: { $0.orientation == preferred && $0.cells.contains(coord) }) {
            select(coord, preferred)
        } else {
            let other: Orientation = preferred == .across ? .down : .across
            select(coord, other)
        }
    }

    /// Clue numbers are assigned by reading order to placed-entry origins.
    private func clueNumber(at coord: Coord) -> Int? {
        Self.numbering(puzzle)[coord]
    }

    private static var numberingCache: [ObjectIdentifier: [Coord: Int]] = [:]

    static func numbering(_ puzzle: Puzzle) -> [Coord: Int] {
        // Sort origins reading-order; same origin can host both across and down.
        let origins = Set(puzzle.placed.map(\.origin))
        let sorted = origins.sorted { a, b in
            a.r == b.r ? a.c < b.c : a.r < b.r
        }
        var map: [Coord: Int] = [:]
        for (i, o) in sorted.enumerated() { map[o] = i + 1 }
        return map
    }
}
