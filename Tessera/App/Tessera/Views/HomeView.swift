import SwiftUI
import TesseraKit

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var showingNew = false
    @State private var showingMultiplayer = false
    @State private var showingLeaderboards = false
    @State private var confirmDiscardSolo = false

    var body: some View {
        List {
            if let solo = model.solo {
                Section("Solo in progress") {
                    NavigationLink {
                        PlayView(solo: solo)
                    } label: {
                        ResumeCard(solo: solo)
                    }
                    Button(role: .destructive) {
                        confirmDiscardSolo = true
                    } label: {
                        Label("Discard solo game", systemImage: "trash")
                    }
                }
            }

            if let match = model.match {
                Section("Active match") {
                    NavigationLink {
                        MatchPlayView(match: match)
                    } label: {
                        MatchCard(match: match)
                    }
                }
            }

            Section("Play") {
                Button {
                    showingNew = true
                } label: {
                    Label("New puzzle", systemImage: "plus.square")
                }

                Button {
                    showingMultiplayer = true
                } label: {
                    Label("Multiplayer", systemImage: "person.2")
                }
                .disabled(model.corpus == nil)

                Button {
                    showingLeaderboards = true
                } label: {
                    Label("Leaderboards", systemImage: "trophy")
                }
                .disabled(!model.isGameCenterAuthenticated)
            }

            Section("Your stats") {
                HStack {
                    Label("Puzzles solved", systemImage: "checkmark.seal")
                    Spacer()
                    Text("\(model.puzzlesSolved)")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                HStack {
                    Label("Multiplayer wins", systemImage: "trophy")
                    Spacer()
                    Text("\(model.multiplayerWins)")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
            }

            if let err = model.corpusError {
                Section("Problem") {
                    Text(err)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .sheet(isPresented: $showingNew) {
            NewPuzzleView()
        }
        .sheet(isPresented: $showingMultiplayer) {
            MultiplayerView()
        }
        #if canImport(GameKit) && canImport(UIKit)
        .sheet(isPresented: $showingLeaderboards) {
            LeaderboardsSheet(onDismiss: { showingLeaderboards = false })
                .ignoresSafeArea()
        }
        #endif
        .alert("Discard solo game?", isPresented: $confirmDiscardSolo) {
            Button("Discard", role: .destructive) { model.endSolo() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your in-progress puzzle will be lost.")
        }
    }
}

private struct ResumeCard: View {
    let solo: SoloViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(solo.languages.map(\.displayName).joined(separator: " + "))
                .font(.headline)
            HStack(spacing: 12) {
                Label(solo.difficulty.rawValue.capitalized, systemImage: "gauge.with.dots.needle.50percent")
                if let theme = solo.themeSlug {
                    Label(theme.capitalized, systemImage: "tag")
                }
                Label("\(solo.puzzle.placed.count) words", systemImage: "square.grid.3x3")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

private struct MatchCard: View {
    let match: MatchViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("vs \(match.handle.opponentDisplayName ?? "Opponent")")
                .font(.headline)
            Text(match.handle.config.languages.map(\.displayName).joined(separator: " + "))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Label(match.handle.config.difficulty.rawValue.capitalized,
                      systemImage: "gauge.with.dots.needle.50percent")
                if let theme = match.handle.config.themeSlug {
                    Label(theme.capitalized, systemImage: "tag")
                }
                Label(match.isMyTurn ? "Your turn" : "Waiting",
                      systemImage: match.isMyTurn ? "person.fill" : "hourglass")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

extension Lang {
    var displayName: String {
        switch self {
        case .en: return "English"
        case .nl: return "Dutch"
        case .de: return "German"
        case .fr: return "French"
        case .es: return "Spanish"
        case .it: return "Italian"
        }
    }
}
