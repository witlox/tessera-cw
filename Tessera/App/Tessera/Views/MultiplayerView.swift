import SwiftUI
import TesseraKit

struct MultiplayerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var languages: Set<Lang> = [.en]
    @State private var difficulty: Generator.Difficulty = .medium
    @State private var themeSlug: String? = nil
    @State private var error: String?
    @State private var signingIn = false
    @State private var showMatchmaker = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Status") {
                    if model.match_service.isAuthenticated {
                        Label("Signed into Game Center", systemImage: "checkmark.seal")
                            .foregroundStyle(.green)
                    } else {
                        Label("Not signed in to Game Center",
                              systemImage: "person.crop.circle.badge.exclamationmark")
                            .foregroundStyle(.orange)
                        Button {
                            Task { await signIn() }
                        } label: {
                            HStack {
                                Spacer()
                                if signingIn {
                                    ProgressView()
                                } else {
                                    Text("Sign in to Game Center")
                                        .fontWeight(.semibold)
                                }
                                Spacer()
                            }
                        }
                        .disabled(signingIn)
                    }
                }

                Section("Match settings") {
                    ForEach(Lang.allCases, id: \.self) { lang in
                        Toggle(lang.displayName, isOn: binding(for: lang))
                    }
                    .toggleStyle(.switch)
                    Picker("Difficulty", selection: $difficulty) {
                        ForEach(Generator.Difficulty.allCases, id: \.self) { d in
                            Text(d.rawValue.capitalized).tag(d)
                        }
                    }
                    .pickerStyle(.segmented)
                    Picker("Theme", selection: $themeSlug) {
                        Text("Any").tag(String?.none)
                        ForEach(model.themes) { t in
                            Text(t.label).tag(Optional(t.slug))
                        }
                    }
                }

                Section {
                    Button {
                        startMatchmaker()
                    } label: {
                        HStack {
                            Spacer()
                            Text("Invite a friend or auto-match")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(!model.match_service.isAuthenticated || languages.isEmpty)
                } footer: {
                    Text("Game Center's matchmaker can add specific friends (or anyone in your contacts), or auto-match you with another player.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                if let error {
                    Section("Problem") {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Multiplayer")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            #if canImport(GameKit) && canImport(UIKit)
            .sheet(isPresented: $showMatchmaker) {
                MatchmakerSheet(
                    onCancel: { showMatchmaker = false },
                    onError: { err in
                        self.error = (err as? LocalizedError)?.errorDescription
                            ?? String(describing: err)
                        showMatchmaker = false
                    }
                )
                .ignoresSafeArea()
            }
            #endif
            // When AppModel attaches the new match, dismiss the matchmaker
            // sheet and this whole MultiplayerView — we want the user to
            // land in MatchPlayView via Home's "Active match" card.
            .onChange(of: model.match != nil) { _, hasMatch in
                if hasMatch {
                    showMatchmaker = false
                    dismiss()
                }
            }
        }
    }

    private func binding(for lang: Lang) -> Binding<Bool> {
        Binding(
            get: { languages.contains(lang) },
            set: { isOn in
                if isOn {
                    guard languages.count < LanguageMix.maxLanguages else { return }
                    languages.insert(lang)
                } else {
                    languages.remove(lang)
                }
            }
        )
    }

    private func signIn() async {
        signingIn = true
        defer { signingIn = false }
        do {
            try await model.match_service.authenticate()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
    }

    private func startMatchmaker() {
        let langs = Lang.allCases.filter { languages.contains($0) }
        // Stash the player-A config for AppModel to consume when the new
        // match arrives via the player listener.
        model.pendingMatchConfig = AppModel.PendingMatchConfig(
            languages: langs, difficulty: difficulty, themeSlug: themeSlug
        )
        error = nil
        showMatchmaker = true
    }
}
