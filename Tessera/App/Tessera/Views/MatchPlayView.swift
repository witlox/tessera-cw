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
    @State private var showCompletion = false
    @State private var confirmDone = false
    @State private var confirmQuit = false

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            CluePanel(entry: currentClue(), state: match.state)
                .padding(.horizontal)
                .padding(.top, 6)

            GeometryReader { geo in
                BoardView(puzzle: match.puzzle, state: stateWithSelection(),
                          wrongCells: match.showErrors
                            ? match.state.wrongCells(match.puzzle)
                            : [],
                          select: { c, o in selection = .init(origin: c, orientation: o) })
                    .frame(width: min(geo.size.width, geo.size.height),
                           height: min(geo.size.width, geo.size.height))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            KeyboardView(
                onLetter: { ch in Task { await submit(letter: ch) } },
                // Re-typing on a cell overwrites — this is the closest thing
                // to "erase" we offer in multiplayer without inventing a
                // separate "erase" wire move. Backspace is therefore a no-op.
                onBackspace: { },
                onSwap: {
                    if var sel = selection {
                        sel.orientation = sel.orientation == .across ? .down : .across
                        selection = sel
                    }
                }
            )
            .disabled(!keyboardEnabled)
            .opacity(keyboardEnabled ? 1.0 : 0.4)
            .padding(.horizontal, 4)
            .padding(.bottom, 8)
        }
        .navigationTitle(titleText)
        .navigationBarTitleDisplayModeIfAvailable(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await checkSelected() }
                } label: {
                    Label("Check", systemImage: "checkmark.seal")
                }
                .disabled(!checkEnabled)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await passTurn() }
                } label: {
                    Label("Pass", systemImage: "forward.end")
                }
                .disabled(!match.isMyTurn || submitting || match.iSignalledDone)
            }
            ToolbarItem(placement: .secondaryAction) {
                MatchOverflowMenu(
                    match: match,
                    onIAmDone: { confirmDone = true },
                    onQuit: { confirmQuit = true }
                )
            }
        }
        .confirmationDialog(
            match.opponentSignalledDone
                ? "End the match? Your opponent has already signalled done — this finishes the game."
                : "Mark yourself as done? You won't be able to place any more letters; your opponent keeps playing until they're done too.",
            isPresented: $confirmDone, titleVisibility: .visible
        ) {
            Button("I'm done", role: .destructive) {
                Task { await signalDone() }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Quit this match? You won't be able to resume — the other player sees you as having left.",
            isPresented: $confirmQuit, titleVisibility: .visible
        ) {
            Button("Quit match", role: .destructive) {
                Task {
                    await model.quitMatch(match)
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
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
        .onChange(of: match.isMyTurn) { _, isMine in
            // Inbound event (opponent passed) flipped whose turn it is.
            isMine ? startClock() : clock.reset()
        }
        .onChange(of: match.payload.moves.count) { _, _ in
            if match.state.isComplete(match.puzzle) { showCompletion = true }
        }
        .onChange(of: match.didEnd) { _, ended in
            if ended { showCompletion = true }
        }
        .alert(match.didWin ? "You won" : "Match complete",
               isPresented: $showCompletion) {
            Button("Done") {
                // Counts as participation if the puzzle was actually solved
                // OR if both players signalled done (legitimate conclusion).
                // Quits / mid-game timeouts shouldn't credit either player.
                let bothDone = match.iSignalledDone && match.opponentSignalledDone
                if match.state.isComplete(match.puzzle) || bothDone {
                    model.recordMultiplayerCompletion(didWin: match.didWin)
                }
                model.endMatch(match)
                dismiss()
            }
        } message: {
            if match.state.isComplete(match.puzzle) {
                Text(match.didWin ? "Your move solved the puzzle." : "Your opponent solved it first.")
            } else if match.iSignalledDone && match.opponentSignalledDone {
                Text(match.didWin
                    ? "Both players called it. You placed more correct letters."
                    : "Both players called it. Your opponent placed more correct letters.")
            } else {
                Text("The other player left or the match timed out.")
            }
        }
    }

    private var keyboardEnabled: Bool {
        match.isMyTurn && !submitting && !match.iSignalledDone
    }

    /// Check needs a selection that maps to a placed entry — otherwise
    /// there's nothing to verify.
    private var checkEnabled: Bool {
        guard match.isMyTurn, !submitting, !match.iSignalledDone else { return false }
        return currentClue() != nil
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            if match.iSignalledDone {
                Image(systemName: "flag.checkered")
                Text("You're done — waiting for opponent")
                    .font(.subheadline.weight(.medium))
            } else {
                Image(systemName: match.isMyTurn ? "person.fill" : "person")
                Text(match.isMyTurn ? "Your turn" : "Opponent's turn")
                    .font(.subheadline.weight(.medium))
            }
            Spacer()
            if match.isMyTurn && !match.iSignalledDone {
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
        "vs \(match.handle.opponentDisplayName ?? "Opponent")"
    }

    private func timeString(_ t: TimeInterval) -> String {
        String(format: "%02d", max(0, Int(t.rounded(.up))))
    }

    private func startClock() {
        clock.onExpire = { @MainActor in
            Task { await timerExpired() }
        }
        clock.start()
    }

    /// Shot clock expired: auto-Check the currently selected entry. If
    /// nothing is selected (or the selection doesn't map to a placed
    /// entry) fall back to Pass so the turn still hands off.
    private func timerExpired() async {
        guard match.isMyTurn, !match.iSignalledDone else { return }
        if currentClue() != nil {
            await checkSelected()
        } else {
            await passTurn()
        }
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

    /// Centralised error handling for every multiplayer write. When the
    /// match has already ended on the server (our `matchAlreadyEnded`
    /// precheck, or the raw `GKError 5003` the server returns when the
    /// local cache hasn't yet seen the transition), flip the VM into
    /// "ended" so the completion alert appears instead of a raw
    /// GKErrorDomain message — the user shouldn't have to parse a
    /// Dutch/English mix of NSError userInfo to understand the game's
    /// over.
    private func handleActionError(_ error: Error) {
        if match.isMatchEndedError(error) {
            match.markEnded()
            return
        }
        self.error = (error as? LocalizedError)?.errorDescription
            ?? String(describing: error)
    }

    private func submit(letter: Character) async {
        guard match.isMyTurn, !submitting, let sel = selection else { return }
        let coord = sel.origin
        guard match.puzzle.solution[coord] != nil else { return }
        submitting = true
        defer { submitting = false }
        // Clock keeps ticking — placing a letter is one step of the same turn.
        do {
            try await match.submitLetter(letter, at: coord, deadline: Date().addingTimeInterval(60))
        } catch {
            handleActionError(error)
        }
    }

    private func passTurn() async {
        guard match.isMyTurn, !submitting, !match.iSignalledDone else { return }
        submitting = true
        clock.stop()
        defer { submitting = false }
        do {
            try await match.pass()
        } catch {
            handleActionError(error)
            if match.isMyTurn { startClock() }
        }
    }

    private func checkSelected() async {
        guard match.isMyTurn, !submitting, !match.iSignalledDone else { return }
        guard let entry = currentClue() else { return }
        submitting = true
        clock.stop()
        defer { submitting = false }
        do {
            _ = try await match.checkEntry(entry)
        } catch {
            handleActionError(error)
            if match.isMyTurn { startClock() }
        }
    }

    private func signalDone() async {
        guard !submitting, !match.iSignalledDone else { return }
        submitting = true
        clock.stop()
        defer { submitting = false }
        do {
            try await match.signalDone()
        } catch {
            handleActionError(error)
        }
    }
}

/// Overflow menu split into its own view so its body only re-runs when
/// `match.showErrors` (which lives on the menu) changes — keeps the menu
/// from re-rendering on every keystroke and silences the
/// `updateVisibleMenuWithBlock` warning.
private struct MatchOverflowMenu: View {
    @Bindable var match: MatchViewModel
    let onIAmDone: () -> Void
    let onQuit: () -> Void

    var body: some View {
        Menu {
            Button {
                match.showErrors.toggle()
            } label: {
                Label(match.showErrors ? "Hide wrong cells" : "Mark wrong cells",
                      systemImage: match.showErrors ? "checkmark" : "exclamationmark.triangle")
            }
            Divider()
            Button(role: .destructive, action: onIAmDone) {
                Label("I'm done", systemImage: "flag.checkered")
            }
            .disabled(match.iSignalledDone)
            Button(role: .destructive, action: onQuit) {
                Label("Quit match", systemImage: "rectangle.portrait.and.arrow.right")
            }
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
    }
}
