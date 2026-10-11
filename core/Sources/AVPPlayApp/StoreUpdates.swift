import AVPPlayCore
import Foundation

/// Neuere Fassungen geprüfter Spiele aus dem Meta-Store: nachsehen, anbieten, wählen lassen.
extension AppModel {
    private static let checkedKey = "storeBuildsChecked"
    private static let cacheKey = "storeBuildsCache"
    /// Wann für ein Spiel zuletzt nachgesehen wurde (nur für diese Sitzung).
    private static var asked: [String: Double] = [:]

    /// Die geprüfte Fassung eines Spiels, auch wenn gerade die neueste gewählt ist.
    func testedRecipe(_ game: Game) -> Recipe? {
        guard !game.draft, let recipes = paths.recipes else { return nil }
        return try? RecipeStore(directory: recipes).load(id: game.id)
    }

    /// Der neuere Build aus dem Store, der für dieses Spiel angeboten werden kann – gemessen an der Fassung, die
    /// gerade gilt. `nil`, wenn es keinen gibt, das Spiel bei seiner Fassung bleibt oder noch nicht nachgesehen wurde.
    func storeUpdate(for game: Game) -> CatalogBuild? {
        guard !game.draft, let build = storeBuilds[game.id], StoreUpdate.isOffered(build, for: game.recipe) else { return nil }
        return build
    }

    /// Sieht nach, welchen Build der Store für die geprüften Spiele gerade führt.
    ///
    /// Für Spiele, die dem angemeldeten Meta-Konto gehören, wird Meta selbst gefragt (`MetaClient.latestBuild`,
    /// nach der Kontoprüfung; der erste unerwartete Ausgang beendet die Fragen an Meta für diese Runde). Für alle anderen, und wo Meta nichts nennt, gilt der Katalog des Projekts – der aus
    /// einer öffentlichen Versionsdatenbank schöpft und Tage bis Wochen zurückliegen kann.
    /// Von selbst höchstens alle zwanzig Stunden; für ein einzelnes Spiel, dessen Seite geöffnet wurde, höchstens
    /// alle dreißig Minuten.
    func checkStoreVersions(only game: Game? = nil) {
        guard onlineCatalog else { return }
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.cacheKey), storeBuilds.isEmpty,
           let cached = try? JSONDecoder().decode([String: CatalogBuild].self, from: data) {
            storeBuilds = cached
        }
        let now = Date().timeIntervalSince1970
        let wanted: [Game]
        if let game {
            guard now - (Self.asked[game.id] ?? 0) > 30 * 60 else { return }
            wanted = [game]
        } else if now - defaults.double(forKey: Self.checkedKey) > 20 * 3600 {
            wanted = games
        } else {
            return
        }
        let list = wanted.filter { !$0.draft && $0.recipe.store.appId != nil && $0.recipe.store.pinned != true }
            .compactMap { g in g.recipe.store.appId.map { (g.id, $0) } }
        guard !list.isEmpty else { return }
        if game == nil { defaults.set(now, forKey: Self.checkedKey) }
        for (id, _) in list { Self.asked[id] = now }
        let client = catalogClient
        let signedIn = account == .signedIn
        let owned = Set(ownership.filter { $0.value.owned }.keys)
        Task.detached(priority: .utility) {
            var meta: MetaClient?
            if signedIn, list.contains(where: { owned.contains($0.1) }), let token = try? TokenStore().read() {
                let candidate = MetaClient(token: token)
                if (try? await candidate.me()) != nil { meta = candidate }
            }
            var found: [String: CatalogBuild] = [:]
            for (id, appId) in list {
                var build: CatalogBuild?
                if let asked = meta, owned.contains(appId) {
                    do { build = try await asked.latestBuild(appId: appId) } catch { meta = nil }
                }
                if build == nil {
                    build = try? await client.game(appId: appId).build
                    try? await Task.sleep(for: .milliseconds(300))
                }
                if let build { found[id] = build }
            }
            let result = found
            await MainActor.run {
                guard !result.isEmpty else { return }
                self.storeBuilds.merge(result) { _, new in new }
                if let data = try? JSONEncoder().encode(self.storeBuilds) { defaults.set(data, forKey: Self.cacheKey) }
            }
        }
    }

    /// Wählt für ein geprüftes Spiel die neueste Fassung aus dem Store: fragt Metas Werkzeug nach ihren Dateien,
    /// legt daraus ein Rezept an, das wie das geprüfte angeordnet ist, und merkt sich die Wahl. Geladen und
    /// installiert wird erst, wenn der Nutzer es danach verlangt.
    func useNewestVersion(_ game: Game) {
        guard let build = storeUpdate(for: game), let tested = testedRecipe(game), let appId = tested.store.appId,
              !preparing.contains(game.id) else { return }
        guard !isBusy(game.id) else {
            prepareNote[game.id] = L("A job for this game is running. Switch versions when it has finished.",
                                     "Für dieses Spiel läuft gerade ein Auftrag. Wechsle die Fassung, wenn er fertig ist.")
            return
        }
        guard account == .signedIn else {
            prepareNote[game.id] = L("Sign in to Meta under “Setup” first – then the app can look up the files of the newer version.",
                                     "Melde dich zuerst unter „Einrichtung“ bei Meta an – dann kann die App die Dateien der neueren Fassung nachschlagen.")
            return
        }
        preparing.insert(game.id)
        prepareNote[game.id] = L("Asking Meta whether you own this game …", "Meta wird gefragt, ob dir das Spiel gehört …")
        let drafts = draftsDirectory
        let tool = Probe.metaToolURL
        let id = game.id
        Task.detached {
            func say(_ text: String) async { await MainActor.run { self.prepareNote[id] = text } }
            var note: String?
            do {
                let token = try TokenStore().read()
                let meta = MetaClient(token: token)
                let user = try await meta.me()
                guard try await meta.ownsApp(appId: appId, userId: user) else {
                    throw Halt(L("This game is not in your Meta account. Nothing is looked up or downloaded.",
                                 "Dieses Spiel gehört nicht zu deinem Meta-Konto. Es wird nichts nachgeschlagen oder geladen."))
                }
                try MetaTool(url: tool).verify()
                await say(L("Asking Meta's tool for the files of version \(build.version) …",
                            "Metas Werkzeug wird nach den Dateien von Fassung \(build.version) gefragt …"))
                var files = try MetaListing.list(.build, buildId: build.buildId, tool: tool, token: token)
                try await Task.sleep(for: .seconds(5))
                if let assets = try? MetaListing.list(.assets, buildId: build.buildId, tool: tool, token: token) { files += assets }
                let recipe = try StoreUpdate.make(tested: tested, build: build, files: files)
                try FileManager.default.createDirectory(at: drafts, withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
                try encoder.encode(recipe).write(to: StoreUpdate.url(drafts: drafts, recipeId: id), options: .atomic)
                var choices = StoreUpdate.Choices.load()
                choices.latest.insert(id)
                try choices.save()
            } catch let halt as Halt {
                note = halt.text
            } catch {
                note = Redaction.redact("\(error)")
            }
            let final = note
            await MainActor.run {
                self.preparing.remove(id)
                self.prepareNote[id] = final
                self.latestChoices = StoreUpdate.Choices.load()
                self.refresh()
            }
        }
    }

    /// Zurück zur geprüften Fassung. Das Rezept der neuesten bleibt liegen; es gilt nur nicht mehr.
    func useTestedVersion(_ game: Game) {
        guard !isBusy(game.id) else {
            prepareNote[game.id] = L("A job for this game is running. Switch versions when it has finished.",
                                     "Für dieses Spiel läuft gerade ein Auftrag. Wechsle die Fassung, wenn er fertig ist.")
            return
        }
        var choices = StoreUpdate.Choices.load()
        choices.latest.remove(game.id)
        try? choices.save()
        latestChoices = choices
        prepareNote[game.id] = nil
        refresh()
    }

    private struct Halt: Error { let text: String; init(_ text: String) { self.text = text } }
}
