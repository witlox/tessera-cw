import Foundation

/// Free-form interlocking crossword generator — a faithful port of the
/// Python prototype validated in `engine/generate.py`. Fills ONLY from clued
/// corpus words; the legality rule guarantees every maximal run is an
/// intentional, clued entry (verified: 0 incidental words across 80 test grids).
///
/// Greedy placement maximising crossings, with random restarts; keeps the best.
public struct Generator {
    public struct Options {
        public var targetWords = 28
        public var maxDim = 15
        public var restarts = 200
        public var minLen = 3
        public var maxLen = 11
        public init() {}
    }

    private let pool: [Entry]
    private let byLetter: [Character: [(Entry, Int)]]

    public init(pool: [Entry]) {
        self.pool = pool
        var idx: [Character: [(Entry, Int)]] = [:]
        for e in pool {
            for (pos, ch) in e.gridForm.enumerated() {
                idx[ch, default: []].append((e, pos))
            }
        }
        self.byLetter = idx
    }

    // MARK: - Mutable working grid

    private struct Board {
        var cells: [Coord: Character] = [:]
        var placed: [PlacedEntry] = []
        var usedGridForms: Set<String> = []

        func letter(_ r: Int, _ c: Int) -> Character? { cells[Coord(r, c)] }

        /// Returns crossing count if legal, else nil. Enforces the
        /// no-incidental-word rule (perpendicular neighbours of non-crossing
        /// cells empty; word ends clear; >=1 crossing once non-empty).
        func legality(_ gf: [Character], _ origin: Coord, _ o: Orientation, maxDim: Int) -> Int? {
            let (dr, dc) = o == .across ? (0, 1) : (1, 0)
            let (pdr, pdc) = o == .across ? (1, 0) : (0, 1)
            let n = gf.count
            // ends must be clear
            if letter(origin.r - dr, origin.c - dc) != nil { return nil }
            if letter(origin.r + dr * n, origin.c + dc * n) != nil { return nil }
            var crossings = 0
            for i in 0..<n {
                let rr = origin.r + dr * i, cc = origin.c + dc * i
                if let cur = letter(rr, cc) {
                    if cur != gf[i] { return nil }
                    crossings += 1
                } else {
                    if letter(rr + pdr, cc + pdc) != nil { return nil }
                    if letter(rr - pdr, cc - pdc) != nil { return nil }
                }
            }
            if !cells.isEmpty && crossings == 0 { return nil }
            // bounding-box guard
            var rs = [origin.r, origin.r + dr * (n - 1)]
            var cs = [origin.c, origin.c + dc * (n - 1)]
            for k in cells.keys { rs.append(k.r); cs.append(k.c) }
            if (rs.max()! - rs.min()!) >= maxDim || (cs.max()! - cs.min()!) >= maxDim { return nil }
            return crossings
        }

        mutating func place(_ e: Entry, _ origin: Coord, _ o: Orientation) {
            let gf = Array(e.gridForm)
            let (dr, dc) = o == .across ? (0, 1) : (1, 0)
            for (i, ch) in gf.enumerated() { cells[Coord(origin.r + dr * i, origin.c + dc * i)] = ch }
            placed.append(PlacedEntry(entry: e, origin: origin, orientation: o))
            usedGridForms.insert(e.gridForm)
        }
    }

    // MARK: - Build

    public func generate(_ opt: Options = Options(), seed: UInt64? = nil) -> Puzzle {
        var rng = SeededRNG(seed ?? UInt64.random(in: 0...UInt64.max))
        var best: Board?
        for _ in 0..<opt.restarts {
            let b = buildOne(opt, &rng)
            if best == nil || b.placed.count > best!.placed.count { best = b }
            if (best?.placed.count ?? 0) >= opt.targetWords { break }
        }
        let board = best ?? Board()
        return Puzzle(placed: board.placed, solution: board.cells,
                      languages: Array(Set(board.placed.map(\.entry.language))))
    }

    private func buildOne(_ opt: Options, _ rng: inout SeededRNG) -> Board {
        var b = Board()
        let seeds = pool.filter { (5...7).contains($0.length) }
        guard let seed = (seeds.isEmpty ? pool : seeds).randomElement(using: &rng) else { return b }
        b.place(seed, Coord(0, 0), .across)

        var stalls = 0
        let attemptsPerStep = 400
        while b.placed.count < opt.targetWords && stalls < 60 {
            var anchors = Array(b.cells)
            anchors.shuffle(using: &rng)
            var best: (Int, Entry, Coord, Orientation)?
            var tried = 0
            outer: for (anchor, aletter) in anchors {
                for (entry, pos) in byLetter[aletter] ?? [] {
                    if b.usedGridForms.contains(entry.gridForm) { continue }
                    tried += 1; if tried > attemptsPerStep { break outer }
                    let gf = Array(entry.gridForm)
                    for o in [Orientation.across, .down] {
                        let (dr, dc) = o == .across ? (0, 1) : (1, 0)
                        let origin = Coord(anchor.r - dr * pos, anchor.c - dc * pos)
                        if let x = b.legality(gf, origin, o, maxDim: opt.maxDim),
                           x > 0, best == nil || x > best!.0 {
                            best = (x, entry, origin, o)
                        }
                    }
                }
            }
            if let (_, e, origin, o) = best { b.place(e, origin, o); stalls = 0 }
            else { stalls += 1 }
        }
        return b
    }

    // MARK: - Correctness verifier (use in tests)

    /// Returns offending runs; empty == every maximal run is a placed entry.
    public static func incidentalWords(in puzzle: Puzzle) -> [String] {
        let placedGF = Set(puzzle.placed.map(\.entry.gridForm))
        let cells = puzzle.solution
        guard !cells.isEmpty else { return [] }
        let rs = cells.keys.map(\.r), cs = cells.keys.map(\.c)
        var bad: [String] = []
        func scan(_ outer: ClosedRange<Int>, _ inner: ClosedRange<Int>, horizontal: Bool) {
            for a in outer {
                var b = inner.lowerBound
                while b <= inner.upperBound {
                    let here = horizontal ? cells[Coord(a, b)] : cells[Coord(b, a)]
                    if here == nil { b += 1; continue }
                    let start = b; var run = ""
                    while b <= inner.upperBound,
                          let ch = horizontal ? cells[Coord(a, b)] : cells[Coord(b, a)] {
                        run.append(ch); b += 1
                    }
                    _ = start
                    if run.count >= 2 && !placedGF.contains(run) { bad.append(run) }
                }
            }
        }
        scan(rs.min()!...rs.max()!, cs.min()!...cs.max()!, horizontal: true)
        scan(cs.min()!...cs.max()!, rs.min()!...rs.max()!, horizontal: false)
        return bad
    }
}

/// Deterministic RNG so puzzles are reproducible from a seed (needed for
/// fair async multiplayer: both players get the identical board).
public struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    public init(_ seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    public mutating func next() -> UInt64 {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return state
    }
}
