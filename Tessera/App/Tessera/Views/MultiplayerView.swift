import SwiftUI
import TesseraKit

struct MultiplayerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var languages: Set<Lang> = [.en]
    @State private var difficulty: Generator.Difficulty = .medium
    @State private var themeSlug: String? = nil
    @State private var inFlight = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Status") {
                    if model.match_service.isAuthenticated {
                        Label("Signed into Game Center", systemImage: "checkmark.seal")
                            .foregroundStyle(.green)
                    } else {
                        Label("Not signed in — open Game Center in Settings",
                              systemImage: "person.crop.circle.badge.exclamationmark")
                            .foregroundStyle(.orange)
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
                        Task { await startMatch() }
                    } label: {
                        HStack {
                            Spacer()
                            if inFlight {
                                ProgressView()
                            } else {
                                Text("Find a match").fontWeight(.semibold)
                            }
                            Spacer()
                        }
                    }
                    .disabled(inFlight || !model.match_service.isAuthenticated)
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

    private func startMatch() async {
        inFlight = true
        defer { inFlight = false }
        do {
            let langs = Lang.allCases.filter { languages.contains($0) }
            let (handle, payload) = try await model.match_service.findMatch(
                languages: langs, difficulty: difficulty, themeSlug: themeSlug)
            // Reproduce the puzzle locally from the seed.
            guard let corpus = model.corpus else { return }
            let pool = try corpus.cluedPool(languages: langs, themeSlug: themeSlug,
                                            minLen: 3, maxLen: 11)
            let generator = Generator(pool: pool)
            let puzzle = generator.generate(seed: handle.config.seed)
            let vm = MatchViewModel(service: model.match_service,
                                    handle: handle, puzzle: puzzle,
                                    me: model.localPlayerID,
                                    payload: payload)
            vm.startListening()
            model.match = vm
            dismiss()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
    }
}
