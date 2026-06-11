import SwiftUI
import TesseraKit

struct NewPuzzleView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var languages: Set<Lang> = [.en]
    @State private var difficulty: Generator.Difficulty = .medium
    @State private var themeSlug: String? = nil

    @State private var poolSize: Int = 0
    @State private var poolError: String?

    // Generator floor is 4 entries; require ≥6 so even the smallest themed
    // mini-puzzle (cooking × non-EN) is playable. Anything below 6 won't
    // produce a meaningfully interlocking grid.
    private let minPlayablePool = 6

    var body: some View {
        NavigationStack {
            Form {
                Section("Languages") {
                    ForEach(Lang.allCases, id: \.self) { lang in
                        Toggle(lang.displayName, isOn: binding(for: lang))
                    }
                    .toggleStyle(.switch)
                    Text("Mix up to \(LanguageMix.maxLanguages). Adding more languages enlarges the available word pool.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section("Difficulty") {
                    Picker("Difficulty", selection: $difficulty) {
                        ForEach(Generator.Difficulty.allCases, id: \.self) { d in
                            Text(d.rawValue.capitalized).tag(d)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Theme") {
                    Picker("Theme", selection: $themeSlug) {
                        Text("Any").tag(String?.none)
                        ForEach(model.themes) { t in
                            Text(themeLabel(t)).tag(Optional(t.slug))
                        }
                    }
                }

                Section("Pool") {
                    HStack {
                        Label("\(poolSize) clued words", systemImage: "books.vertical")
                        Spacer()
                        if poolSize < minPlayablePool {
                            Text("Too small")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                    .font(.subheadline)
                    if let poolError {
                        Text(poolError).font(.footnote).foregroundStyle(.red)
                    }
                    Text("Target board: \(Generator.adaptiveTarget(poolSize: poolSize)) words.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section {
                    Button {
                        let langs = orderedLanguages()
                        model.startSolo(languages: langs,
                                        difficulty: difficulty,
                                        themeSlug: themeSlug)
                        dismiss()
                    } label: {
                        HStack {
                            Spacer()
                            Text("Start")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(languages.isEmpty || poolSize < minPlayablePool)
                }
            }
            .navigationTitle("New Puzzle")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear(perform: refreshPool)
            .onChange(of: languages) { _, _ in refreshPool() }
            .onChange(of: themeSlug) { _, _ in refreshPool() }
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

    private func orderedLanguages() -> [Lang] {
        Lang.allCases.filter { languages.contains($0) }
    }

    private func themeLabel(_ t: Theme) -> String {
        let langs = orderedLanguages()
        let counts = langs.compactMap { t.counts[$0.rawValue] }
        let total = counts.reduce(0, +)
        return total > 0 ? "\(t.label) — \(total)" : t.label
    }

    private func refreshPool() {
        guard let corpus = model.corpus else { return }
        let langs = orderedLanguages()
        guard !langs.isEmpty else { poolSize = 0; return }
        do {
            poolSize = try corpus.poolCount(languages: langs, themeSlug: themeSlug,
                                            minLen: 3, maxLen: 11)
            poolError = nil
        } catch {
            poolSize = 0
            poolError = String(describing: error)
        }
    }
}
