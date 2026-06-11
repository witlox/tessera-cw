import SwiftUI
import TesseraKit

struct PlayView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @Bindable var solo: SoloViewModel
    @State private var showCompletion = false

    var body: some View {
        VStack(spacing: 0) {
            CluePanel(entry: solo.currentClue(), state: solo.state)
                .padding(.horizontal)
                .padding(.top, 8)

            GeometryReader { geo in
                BoardView(puzzle: solo.puzzle,
                          state: solo.state,
                          wrongCells: solo.showErrors ? solo.state.wrongCells(solo.puzzle) : [],
                          select: { c, o in solo.select(c, orientation: o) })
                    .frame(width: min(geo.size.width, geo.size.height),
                           height: min(geo.size.width, geo.size.height))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            KeyboardView(
                onLetter: { ch in solo.place(ch, at: solo.state.selection?.origin ?? Coord(0,0)) },
                onBackspace: { solo.backspace() },
                onSwap: { solo.toggleOrientation() }
            )
            .padding(.horizontal, 4)
            .padding(.bottom, 8)
        }
        .navigationTitle(titleText)
        .navigationBarTitleDisplayModeIfAvailable(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Reveal letter") { solo.revealLetter() }
                    Button("Reveal word") { solo.revealEntry() }
                    Button("Reveal puzzle", role: .destructive) { solo.revealAll() }
                    Divider()
                    // Button with state-aware label, not Toggle — Toggle inside
                    // a Menu whose parent re-renders frequently (every keystroke
                    // here) spams "updateVisibleMenuWithBlock while no context
                    // menu is visible" warnings.
                    Button {
                        solo.showErrors.toggle()
                    } label: {
                        Label(solo.showErrors ? "Hide wrong cells" : "Mark wrong cells",
                              systemImage: solo.showErrors ? "checkmark" : "exclamationmark.triangle")
                    }
                } label: {
                    Label("Reveal", systemImage: "eye")
                }
            }
        }
        .onChange(of: solo.state) { _, _ in
            if solo.isComplete { showCompletion = true }
        }
        .alert("Puzzle complete", isPresented: $showCompletion) {
            Button("Done") { model.endSolo(); dismiss() }
        } message: {
            Text(completionMessage)
        }
    }

    private var titleText: String {
        let langs = solo.languages.map(\.displayName).joined(separator: " + ")
        return solo.themeSlug.map { "\(langs) — \($0.capitalized)" } ?? langs
    }

    private var completionMessage: String {
        let seconds = Int(solo.state.elapsedSeconds)
        let m = seconds / 60, s = seconds % 60
        let timeStr = m > 0 ? "\(m)m \(s)s" : "\(s)s"
        return "Solved in \(timeStr)."
    }
}
