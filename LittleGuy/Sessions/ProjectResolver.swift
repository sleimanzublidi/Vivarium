// LittleGuy/Sessions/ProjectResolver.swift
import Foundation
import Darwin   // for fnmatch and FNM_PATHNAME

struct ProjectResolver {
    struct Override {
        let matchGlob: String   // POSIX glob (fnmatch with FNM_PATHNAME)
        let label: String
        let petId: String
    }

    let overrides: [Override]
    var defaultPetID: String { defaultPetIDProvider() }
    private let defaultPetIDProvider: () -> String
    private let availablePetIDsProvider: () -> [String]
    private let settingsStore: GlobalSettingsStore?

    init(overrides: [Override],
         defaultPetID: String,
         availablePetIDs: [String] = [],
         settingsStore: GlobalSettingsStore? = nil)
    {
        self.overrides = overrides
        self.defaultPetIDProvider = { defaultPetID }
        self.availablePetIDsProvider = { availablePetIDs }
        self.settingsStore = settingsStore
    }

    init(overrides: [Override],
         defaultPetIDProvider: @escaping () -> String,
         availablePetIDsProvider: @escaping () -> [String],
         settingsStore: GlobalSettingsStore? = nil)
    {
        self.overrides = overrides
        self.defaultPetIDProvider = defaultPetIDProvider
        self.availablePetIDsProvider = availablePetIDsProvider
        self.settingsStore = settingsStore
    }

    func resolve(cwd: URL, agent: AgentType) -> ProjectIdentity {
        // 1. override match wins
        if let o = overrides.first(where: { o in
            fnmatch_strict(pattern: o.matchGlob, path: cwd.path)
        }) {
            return ProjectIdentity(url: cwd, label: o.label, petId: o.petId)
        }

        // 2. git root
        if let root = findGitRoot(start: cwd) {
            return ProjectIdentity(
                url: root,
                label: root.lastPathComponent,
                petId: petID(for: root, agent: agent)
            )
        }

        // 3. cwd
        return ProjectIdentity(url: cwd,
                               label: cwd.lastPathComponent,
                               petId: petID(for: cwd, agent: agent))
    }

    private func petID(for projectURL: URL, agent: AgentType) -> String {
        let fallbackPetID = defaultPetID
        guard let settingsStore else { return fallbackPetID }
        return settingsStore.petID(for: projectURL,
                                   agent: agent,
                                   availablePetIDs: availablePetIDsProvider(),
                                   fallbackPetID: fallbackPetID)
    }

    private func findGitRoot(start: URL) -> URL? {
        var dir = start.standardizedFileURL
        let fm = FileManager.default
        while dir.path != "/" {
            let git = dir.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: git.path, isDirectory: &isDir) { return dir }
            let parent = dir.deletingLastPathComponent()
            if parent == dir { break }
            dir = parent
        }
        return nil
    }
}

final class GlobalSettingsStore {
    typealias PetChooser = ([String]) -> String?

    struct Settings: Codable, Equatable {
        var version: Int
        var projectPets: [String: String]

        init(version: Int = 1, projectPets: [String: String] = [:]) {
            self.version = version
            self.projectPets = projectPets
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
            projectPets = try container.decodeIfPresent([String: String].self, forKey: .projectPets) ?? [:]
        }
    }

    static let defaultSettingsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".littleguy/settings.json")
    private static let nonPersistablePetIDs: Set<String> = ["sample-pet"]

    private let settingsURL: URL
    private let fileManager: FileManager
    private let choosePetID: PetChooser
    private let lock = NSLock()

    init(settingsURL: URL = GlobalSettingsStore.defaultSettingsURL,
         fileManager: FileManager = .default,
         choosePetID: @escaping PetChooser = { $0.randomElement() })
    {
        self.settingsURL = settingsURL
        self.fileManager = fileManager
        self.choosePetID = choosePetID
    }

    func petID(for projectURL: URL,
               agent: AgentType,
               availablePetIDs: [String],
               fallbackPetID: String) -> String
    {
        lock.lock()
        defer { lock.unlock() }

        let key = Self.projectAgentKey(for: projectURL, agent: agent)
        var settings = loadSettings()
        let removedNonPersistable = removeNonPersistablePetAssignments(from: &settings)

        let available = Self.uniquePetIDs(availablePetIDs)
        let persistableAvailable = available.filter(Self.isPersistablePetID)
        guard !persistableAvailable.isEmpty else {
            if removedNonPersistable { saveSettings(settings) }
            return fallbackPetID
        }

        if let saved = settings.projectPets[key], persistableAvailable.contains(saved) {
            if removedNonPersistable { saveSettings(settings) }
            return saved
        }

        let selected = chooseAvailablePetID(from: candidatePetIDs(in: settings, availablePetIDs: persistableAvailable))
        settings.projectPets[key] = selected
        saveSettings(settings)
        return selected
    }

    static func projectKey(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    static func projectAgentKey(for url: URL, agent: AgentType) -> String {
        "\(agent.rawValue)::\(projectKey(for: url))"
    }

    private static func uniquePetIDs(_ petIDs: [String]) -> [String] {
        var seen = Set<String>()
        return petIDs.filter { seen.insert($0).inserted }
    }

    private static func isPersistablePetID(_ petID: String) -> Bool {
        !nonPersistablePetIDs.contains(petID)
    }

    private func removeNonPersistablePetAssignments(from settings: inout Settings) -> Bool {
        let original = settings.projectPets
        settings.projectPets = settings.projectPets.filter { Self.isPersistablePetID($0.value) }
        return settings.projectPets != original
    }

    private func candidatePetIDs(in settings: Settings, availablePetIDs: [String]) -> [String] {
        let assigned = Set(settings.projectPets
            .filter { Self.isProjectAgentKey($0.key) }
            .values)
            .intersection(availablePetIDs)
        let unassigned = availablePetIDs.filter { !assigned.contains($0) }
        return unassigned.isEmpty ? availablePetIDs : unassigned
    }

    private static func isProjectAgentKey(_ key: String) -> Bool {
        key.hasPrefix("\(AgentType.claudeCode.rawValue)::")
            || key.hasPrefix("\(AgentType.copilotCli.rawValue)::")
    }

    private func chooseAvailablePetID(from availablePetIDs: [String]) -> String {
        if let selected = choosePetID(availablePetIDs), availablePetIDs.contains(selected) {
            return selected
        }
        NSLog("[WARNING] Pet chooser returned no available pet; using \(availablePetIDs[0])")
        return availablePetIDs[0]
    }

    private func loadSettings() -> Settings {
        guard fileManager.fileExists(atPath: settingsURL.path) else { return Settings() }
        do {
            let data = try Data(contentsOf: settingsURL)
            return try JSONDecoder().decode(Settings.self, from: data)
        } catch {
            NSLog("[ERROR] Failed to read LittleGuy settings at \(settingsURL.path): \(error)")
            return Settings()
        }
    }

    private func saveSettings(_ settings: Settings) {
        do {
            try fileManager.createDirectory(at: settingsURL.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(settings)
            try data.write(to: settingsURL, options: [.atomic])
        } catch {
            NSLog("[ERROR] Failed to write LittleGuy settings at \(settingsURL.path): \(error)")
        }
    }
}

private func fnmatch_strict(pattern: String, path: String) -> Bool {
    pattern.withCString { p in
        path.withCString { s in
            Darwin.fnmatch(p, s, FNM_PATHNAME) == 0
        }
    }
}
