import SwiftUI
import TesseraKit

/// Multiplayer board view. Inputs are gated by `isMyTurn`; the shot clock
/// runs only on your turn and triggers auto-pass on expiry.
struct MatchPlayView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @Bindable var match: MatchViewModel
    @StateObject private var clock = ShotClock()

    @State private var selection: GameState.Selection?
    @State private var error: String?
    @State private var submitting = false

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            CluePanel(entry: currentClue(), state: match.state)
                .padding(.horizontal)
                .padding(.top, 6)

            GeometryReader { geo in
                BoardView(puzzle: match.puzzle, state: stateWithSelection(),
                          select: { c, o in selection = .init(origin: c, orientation: o) })
                    .frame(width: min(geo.size.width, geo.size.height),
                           height: min(geo.size.width, geo.size.height))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            KeyboardView(
                onLetter: { ch in Task { await submit(letter: ch) } },
                onBackspace: { /* multiplayer is single-letter-per-turn */ },
                onSwap: {
                    if var sel = selection {
                        sel.orientation = sel.orientation == .across ? .down : .across
                        selection = sel
                    }
                }
            )
            .disabled(!match.isMyTurn || submitting)
            .opacity((match.isMyTurn && !submitting) ? 1.0 : 0.4)
            .padding(.horizontal, 4)
            .padding(.bottom, 8)
        }
        .navigationTitle(titleText)
        .navigationBarTitleDisplayModeIfAvailable(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await passTurn() }
                } label: {
                    Label("Pass", systemImage: "forward.end")
                }
                .disabled(!match.isMyTurn || submitting)
            }
        }
        .alert("Multiplayer error", isPresented: Binding(
            get: { error != nil }, set: { if !$0 { error = nil } }
        )) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
        .onAppear {
            if match.isMyTurn { startClock() }
            if selection == nil, let first = match.puzzle.placed.first {
                selection = .init(origin: first.origin, orientation: first.orientation)
            }
        }
        .onChange(of: match.payload.moves.count) { _, _ in
            // Inbound event flipped whose turn it is.
            match.isMyTurn ? startClock() : clock.reset()
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Image(systemName: match.isMyTurn ? "person.fill" : "person")
            Text(match.isMyTurn ? "Your turn" : "Opponent's turn")
                .font(.subheadline.weight(.medium))
            Spacer()
            if match.isMyTurn {
                Label(timeString(clock.remaining), systemImage: "timer")
                    .monospacedDigit()
                    .font(.subheadline)
                    .foregroundStyle(clock.remaining < 10 ? .red : .secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
    }

    private var titleText: String {
        let langs = match.handle.config.languages.map(\.displayName).joined(separator: " + ")
        return match.handle.config.themeSlug.map { "\(langs) — \($0.capitalized)" } ?? langs
    }

    private func timeString(_ t: TimeInterval) -> String {
        String(format: "%02d", max(0, Int(t.rounded(.up))))
    }

    private func startClock() {
        clock.onExpire = { @MainActor in
            Task { await passTurn(auto: true) }
        }
        clock.start()
    }

    private func currentClue() -> PlacedEntry? {
        guard let sel = selection else { return nil }
        return match.currentClue(for: sel)
            ?? match.currentClue(for: .init(origin: sel.origin,
                                            orientation: sel.orientation == .across ? .down : .across))
    }

    private func stateWithSelection() -> GameState {
        var s = match.state
        s.selection = selection
        return s
    }

    // MARK: - Actions

    private func submit(letter: Character) async {
        guard match.isMyTurn, !submitting, let sel = selection else { return }
        let coord = sel.origin
        guard match.puzzle.solution[coord] != nil else { return }
        submitting = true
        clock.stop()
        defer { submitting = false }
        do {
            try await match.submitLetter(letter, at: coord, deadline: Date().addingTimeInterval(60))
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            if match.isMyTurn { startClock() }   // restore if submit failed
        }
    }

    private func passTurn(auto: Bool = false) async {
        guard match.isMyTurn, !submitting else { return }
        submitting = true
        clock.stop()
        defer { submitting = false }
        do {
            try await match.pass()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            if match.isMyTurn { startClock() }
        }
    }
}
