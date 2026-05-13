// VivariumTests/Sessions/ProjectResolverTests.swift
import XCTest
@testable import Vivarium

final class ProjectResolverTests: XCTestCase {
    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("litttleguy-test-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func mkdir(_ url: URL) {
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func test_resolvesGitRoot_fromSubdir() {
        let root = makeTempDir()
        mkdir(root.appendingPathComponent(".git"))
        let sub = root.appendingPathComponent("a/b/c"); mkdir(sub)
        let resolver = ProjectResolver(overrides: [], defaultPetID: "sample-pet")
        let pid = resolver.resolve(cwd: sub, agent: .claudeCode)
        XCTAssertEqual(pid.url.standardizedFileURL, root.standardizedFileURL)
        XCTAssertEqual(pid.label, root.lastPathComponent)
        XCTAssertEqual(pid.petId, "sample-pet")
    }

    func test_fallsBackToCwd_whenNoGit() {
        let dir = makeTempDir()
        let resolver = ProjectResolver(overrides: [], defaultPetID: "sample-pet")
        let pid = resolver.resolve(cwd: dir, agent: .claudeCode)
        XCTAssertEqual(pid.url.standardizedFileURL, dir.standardizedFileURL)
    }

    func test_overrideWins_overGitRoot() {
        let root = makeTempDir()
        mkdir(root.appendingPathComponent(".git"))
        let services = root.appendingPathComponent("services/auth"); mkdir(services)
        let override = ProjectResolver.Override(
            matchGlob: "\(root.path)/services/*",
            label: "auth-service",
            petId: "wizard"
        )
        let resolver = ProjectResolver(overrides: [override], defaultPetID: "sample-pet")
        let pid = resolver.resolve(cwd: services, agent: .claudeCode)
        XCTAssertEqual(pid.url.standardizedFileURL, services.standardizedFileURL)
        XCTAssertEqual(pid.label, "auth-service")
        XCTAssertEqual(pid.petId, "wizard")
    }

    func test_unmappedProjectChoosesPetAndPersistsMapping() throws {
        let settingsDir = makeTempDir()
        let settingsURL = settingsDir.appendingPathComponent("settings.json")
        let project = makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: settingsDir)
            try? FileManager.default.removeItem(at: project)
        }

        let firstStore = GlobalSettingsStore(settingsURL: settingsURL) { petIDs in
            XCTAssertEqual(petIDs, ["a", "b", "c"])
            return "b"
        }
        let firstResolver = ProjectResolver(overrides: [],
                                            defaultPetID: "sample-pet",
                                            availablePetIDs: ["a", "b", "c"],
                                            settingsStore: firstStore)

        XCTAssertEqual(firstResolver.resolve(cwd: project, agent: .claudeCode).petId, "b")

        let saved = try JSONDecoder().decode(GlobalSettingsStore.Settings.self,
                                             from: Data(contentsOf: settingsURL))
        XCTAssertEqual(saved.projectPets[GlobalSettingsStore.projectAgentKey(for: project, agent: .claudeCode)], "b")

        let secondStore = GlobalSettingsStore(settingsURL: settingsURL) { _ in "a" }
        let secondResolver = ProjectResolver(overrides: [],
                                             defaultPetID: "sample-pet",
                                             availablePetIDs: ["a", "b", "c"],
                                             settingsStore: secondStore)
        XCTAssertEqual(secondResolver.resolve(cwd: project, agent: .claudeCode).petId, "b")
    }

    func test_unavailableSavedPetChoosesAndPersistsReplacement() throws {
        let settingsDir = makeTempDir()
        let settingsURL = settingsDir.appendingPathComponent("settings.json")
        let project = makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: settingsDir)
            try? FileManager.default.removeItem(at: project)
        }

        let key = GlobalSettingsStore.projectAgentKey(for: project, agent: .claudeCode)
        let existing = GlobalSettingsStore.Settings(projectPets: [key: "missing"])
        let data = try JSONEncoder().encode(existing)
        try data.write(to: settingsURL)

        let store = GlobalSettingsStore(settingsURL: settingsURL) { _ in "c" }
        let resolver = ProjectResolver(overrides: [],
                                       defaultPetID: "sample-pet",
                                       availablePetIDs: ["a", "c"],
                                       settingsStore: store)

        XCTAssertEqual(resolver.resolve(cwd: project, agent: .claudeCode).petId, "c")

        let saved = try JSONDecoder().decode(GlobalSettingsStore.Settings.self,
                                             from: Data(contentsOf: settingsURL))
        XCTAssertEqual(saved.projectPets[key], "c")
    }

    func test_samplePetIsNeverPersistedAsProjectMapping() throws {
        let settingsDir = makeTempDir()
        let settingsURL = settingsDir.appendingPathComponent("settings.json")
        let project = makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: settingsDir)
            try? FileManager.default.removeItem(at: project)
        }

        var chooseCalled = false
        let store = GlobalSettingsStore(settingsURL: settingsURL) { petIDs in
            chooseCalled = true
            XCTAssertFalse(petIDs.contains("sample-pet"))
            return "bitboy"
        }
        let resolver = ProjectResolver(overrides: [],
                                       defaultPetID: "sample-pet",
                                       availablePetIDs: ["sample-pet", "bitboy"],
                                       settingsStore: store)

        XCTAssertEqual(resolver.resolve(cwd: project, agent: .copilotCli).petId, "bitboy")
        XCTAssertTrue(chooseCalled)

        let saved = try JSONDecoder().decode(GlobalSettingsStore.Settings.self,
                                             from: Data(contentsOf: settingsURL))
        XCTAssertEqual(saved.projectPets[GlobalSettingsStore.projectAgentKey(for: project, agent: .copilotCli)], "bitboy")
        XCTAssertFalse(saved.projectPets.values.contains("sample-pet"))
    }

    func test_existingSamplePetMappingIsReplacedAndRemovedFromSettings() throws {
        let settingsDir = makeTempDir()
        let settingsURL = settingsDir.appendingPathComponent("settings.json")
        let project = makeTempDir()
        let otherProject = makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: settingsDir)
            try? FileManager.default.removeItem(at: project)
            try? FileManager.default.removeItem(at: otherProject)
        }

        let key = GlobalSettingsStore.projectAgentKey(for: project, agent: .claudeCode)
        let otherKey = GlobalSettingsStore.projectAgentKey(for: otherProject, agent: .copilotCli)
        let existing = GlobalSettingsStore.Settings(projectPets: [
            key: "sample-pet",
            otherKey: "sample-pet"
        ])
        try JSONEncoder().encode(existing).write(to: settingsURL)

        let store = GlobalSettingsStore(settingsURL: settingsURL) { petIDs in
            XCTAssertEqual(petIDs, ["bitboy"])
            return "bitboy"
        }
        let resolver = ProjectResolver(overrides: [],
                                       defaultPetID: "sample-pet",
                                       availablePetIDs: ["sample-pet", "bitboy"],
                                       settingsStore: store)

        XCTAssertEqual(resolver.resolve(cwd: project, agent: .claudeCode).petId, "bitboy")

        let saved = try JSONDecoder().decode(GlobalSettingsStore.Settings.self,
                                             from: Data(contentsOf: settingsURL))
        XCTAssertEqual(saved.projectPets, [key: "bitboy"])
    }

    func test_onlySamplePetAvailableFallsBackWithoutWritingSettings() {
        let settingsDir = makeTempDir()
        let settingsURL = settingsDir.appendingPathComponent("settings.json")
        let project = makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: settingsDir)
            try? FileManager.default.removeItem(at: project)
        }

        let store = GlobalSettingsStore(settingsURL: settingsURL) { _ in
            XCTFail("sample-pet must not be offered as a persistable choice")
            return "sample-pet"
        }
        let resolver = ProjectResolver(overrides: [],
                                       defaultPetID: "sample-pet",
                                       availablePetIDs: ["sample-pet"],
                                       settingsStore: store)

        XCTAssertEqual(resolver.resolve(cwd: project, agent: .claudeCode).petId, "sample-pet")
        XCTAssertFalse(FileManager.default.fileExists(atPath: settingsURL.path))
    }

    func test_unmappedProjectPrefersUnassignedAvailablePet() throws {
        let settingsDir = makeTempDir()
        let settingsURL = settingsDir.appendingPathComponent("settings.json")
        let firstProject = makeTempDir()
        let secondProject = makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: settingsDir)
            try? FileManager.default.removeItem(at: firstProject)
            try? FileManager.default.removeItem(at: secondProject)
        }

        let existing = GlobalSettingsStore.Settings(projectPets: [
            GlobalSettingsStore.projectAgentKey(for: firstProject, agent: .claudeCode): "a"
        ])
        try JSONEncoder().encode(existing).write(to: settingsURL)

        let store = GlobalSettingsStore(settingsURL: settingsURL) { petIDs in
            XCTAssertEqual(petIDs, ["b", "c"])
            return "c"
        }
        let resolver = ProjectResolver(overrides: [],
                                       defaultPetID: "sample-pet",
                                       availablePetIDs: ["a", "b", "c"],
                                       settingsStore: store)

        XCTAssertEqual(resolver.resolve(cwd: secondProject, agent: .copilotCli).petId, "c")
    }

    func test_unmappedProjectAllowsDuplicatesAfterAllPetsAssigned() throws {
        let settingsDir = makeTempDir()
        let settingsURL = settingsDir.appendingPathComponent("settings.json")
        let firstProject = makeTempDir()
        let secondProject = makeTempDir()
        let thirdProject = makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: settingsDir)
            try? FileManager.default.removeItem(at: firstProject)
            try? FileManager.default.removeItem(at: secondProject)
            try? FileManager.default.removeItem(at: thirdProject)
        }

        let existing = GlobalSettingsStore.Settings(projectPets: [
            GlobalSettingsStore.projectAgentKey(for: firstProject, agent: .claudeCode): "a",
            GlobalSettingsStore.projectAgentKey(for: secondProject, agent: .copilotCli): "b"
        ])
        try JSONEncoder().encode(existing).write(to: settingsURL)

        let store = GlobalSettingsStore(settingsURL: settingsURL) { petIDs in
            XCTAssertEqual(petIDs, ["a", "b"])
            return "b"
        }
        let resolver = ProjectResolver(overrides: [],
                                       defaultPetID: "sample-pet",
                                       availablePetIDs: ["a", "b"],
                                       settingsStore: store)

        XCTAssertEqual(resolver.resolve(cwd: thirdProject, agent: .claudeCode).petId, "b")
    }

    func test_sameProjectDifferentAgentsGetSeparatePersistentPets() throws {
        let settingsDir = makeTempDir()
        let settingsURL = settingsDir.appendingPathComponent("settings.json")
        let project = makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: settingsDir)
            try? FileManager.default.removeItem(at: project)
        }

        var choices = ["claude-pet", "copilot-pet"]
        let store = GlobalSettingsStore(settingsURL: settingsURL) { petIDs in
            if choices.count == 1 {
                XCTAssertEqual(petIDs, ["copilot-pet", "other"])
            }
            return choices.removeFirst()
        }
        let resolver = ProjectResolver(overrides: [],
                                       defaultPetID: "sample-pet",
                                       availablePetIDs: ["claude-pet", "copilot-pet", "other"],
                                       settingsStore: store)

        XCTAssertEqual(resolver.resolve(cwd: project, agent: .claudeCode).petId, "claude-pet")
        XCTAssertEqual(resolver.resolve(cwd: project, agent: .copilotCli).petId, "copilot-pet")

        let saved = try JSONDecoder().decode(GlobalSettingsStore.Settings.self,
                                             from: Data(contentsOf: settingsURL))
        XCTAssertEqual(saved.projectPets[GlobalSettingsStore.projectAgentKey(for: project, agent: .claudeCode)], "claude-pet")
        XCTAssertEqual(saved.projectPets[GlobalSettingsStore.projectAgentKey(for: project, agent: .copilotCli)], "copilot-pet")
    }

    func test_sameProjectSameAgentReusesPetAcrossSessions() {
        let settingsDir = makeTempDir()
        let settingsURL = settingsDir.appendingPathComponent("settings.json")
        let project = makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: settingsDir)
            try? FileManager.default.removeItem(at: project)
        }

        var chooseCount = 0
        let store = GlobalSettingsStore(settingsURL: settingsURL) { _ in
            chooseCount += 1
            return "claude-pet"
        }
        let resolver = ProjectResolver(overrides: [],
                                       defaultPetID: "sample-pet",
                                       availablePetIDs: ["claude-pet", "other"],
                                       settingsStore: store)

        XCTAssertEqual(resolver.resolve(cwd: project, agent: .claudeCode).petId, "claude-pet")
        XCTAssertEqual(resolver.resolve(cwd: project, agent: .claudeCode).petId, "claude-pet")
        XCTAssertEqual(chooseCount, 1)
    }

    func test_setPetID_persistsExplicitChoice() throws {
        let settingsDir = makeTempDir()
        let settingsURL = settingsDir.appendingPathComponent("settings.json")
        let project = makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: settingsDir)
            try? FileManager.default.removeItem(at: project)
        }

        let store = GlobalSettingsStore(settingsURL: settingsURL) { _ in "a" }
        let resolver = ProjectResolver(overrides: [],
                                       defaultPetID: "sample-pet",
                                       availablePetIDs: ["a", "b"],
                                       settingsStore: store)
        // Seed an initial mapping by resolving once.
        XCTAssertEqual(resolver.resolve(cwd: project, agent: .claudeCode).petId, "a")

        store.setPetID("b", forProject: project, agent: .claudeCode)

        let saved = try JSONDecoder().decode(GlobalSettingsStore.Settings.self,
                                             from: Data(contentsOf: settingsURL))
        XCTAssertEqual(saved.projectPets[GlobalSettingsStore.projectAgentKey(for: project, agent: .claudeCode)], "b")

        // A fresh resolver reading from the same file must return the new pet.
        let secondResolver = ProjectResolver(overrides: [],
                                             defaultPetID: "sample-pet",
                                             availablePetIDs: ["a", "b"],
                                             settingsStore: GlobalSettingsStore(settingsURL: settingsURL) { _ in "a" })
        XCTAssertEqual(secondResolver.resolve(cwd: project, agent: .claudeCode).petId, "b")
    }

    func test_setPetID_ignoresNonPersistableSamplePet() throws {
        let settingsDir = makeTempDir()
        let settingsURL = settingsDir.appendingPathComponent("settings.json")
        let project = makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: settingsDir)
            try? FileManager.default.removeItem(at: project)
        }

        let key = GlobalSettingsStore.projectAgentKey(for: project, agent: .claudeCode)
        let existing = GlobalSettingsStore.Settings(projectPets: [key: "real-pet"])
        try JSONEncoder().encode(existing).write(to: settingsURL)

        let store = GlobalSettingsStore(settingsURL: settingsURL) { _ in "real-pet" }
        store.setPetID("sample-pet", forProject: project, agent: .claudeCode)

        let saved = try JSONDecoder().decode(GlobalSettingsStore.Settings.self,
                                             from: Data(contentsOf: settingsURL))
        XCTAssertEqual(saved.projectPets[key], "real-pet",
                       "sample-pet must never be written as a per-project mapping")
    }

    // MARK: - Label overrides (settings.json projectLabels)

    func test_labelOverride_replacesGitRootLabel() throws {
        let settingsDir = makeTempDir()
        let settingsURL = settingsDir.appendingPathComponent("settings.json")
        let root = makeTempDir()
        mkdir(root.appendingPathComponent(".git"))
        let sub = root.appendingPathComponent("a/b"); mkdir(sub)
        defer {
            try? FileManager.default.removeItem(at: settingsDir)
            try? FileManager.default.removeItem(at: root)
        }

        // Glob matches the actual cwd path (sub), not the git root.
        let existing = GlobalSettingsStore.Settings(
            projectLabels: ["\(root.path)/*/*": "Pretty Name"])
        try JSONEncoder().encode(existing).write(to: settingsURL)

        let store = GlobalSettingsStore(settingsURL: settingsURL) { _ in "sample-pet" }
        let resolver = ProjectResolver(overrides: [],
                                       defaultPetID: "sample-pet",
                                       availablePetIDs: [],
                                       settingsStore: store)

        let pid = resolver.resolve(cwd: sub, agent: .claudeCode)
        // Label overridden; url stays the git root.
        XCTAssertEqual(pid.label, "Pretty Name")
        XCTAssertEqual(pid.url.standardizedFileURL, root.standardizedFileURL)
    }

    func test_labelOverride_appliesWhenNoGitRoot() throws {
        let settingsDir = makeTempDir()
        let settingsURL = settingsDir.appendingPathComponent("settings.json")
        let project = makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: settingsDir)
            try? FileManager.default.removeItem(at: project)
        }

        let existing = GlobalSettingsStore.Settings(
            projectLabels: [project.path: "Renamed"])
        try JSONEncoder().encode(existing).write(to: settingsURL)

        let store = GlobalSettingsStore(settingsURL: settingsURL) { _ in "sample-pet" }
        let resolver = ProjectResolver(overrides: [],
                                       defaultPetID: "sample-pet",
                                       settingsStore: store)

        XCTAssertEqual(resolver.resolve(cwd: project, agent: .claudeCode).label, "Renamed")
    }

    func test_labelOverride_longestGlobWinsOnMultipleMatches() throws {
        let settingsDir = makeTempDir()
        let settingsURL = settingsDir.appendingPathComponent("settings.json")
        let root = makeTempDir()
        mkdir(root.appendingPathComponent(".git"))
        let sub = root.appendingPathComponent("services/auth"); mkdir(sub)
        defer {
            try? FileManager.default.removeItem(at: settingsDir)
            try? FileManager.default.removeItem(at: root)
        }

        // Both globs match `sub` — the more specific (longer) one should win.
        let existing = GlobalSettingsStore.Settings(projectLabels: [
            "\(root.path)/*/*":         "Generic",
            "\(root.path)/services/*":  "Specific",
        ])
        try JSONEncoder().encode(existing).write(to: settingsURL)

        let store = GlobalSettingsStore(settingsURL: settingsURL) { _ in "sample-pet" }
        let resolver = ProjectResolver(overrides: [],
                                       defaultPetID: "sample-pet",
                                       settingsStore: store)

        XCTAssertEqual(resolver.resolve(cwd: sub, agent: .claudeCode).label, "Specific")
    }

    func test_labelOverride_doesNotChangeAutoResolvedPet() throws {
        let settingsDir = makeTempDir()
        let settingsURL = settingsDir.appendingPathComponent("settings.json")
        let project = makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: settingsDir)
            try? FileManager.default.removeItem(at: project)
        }

        let existing = GlobalSettingsStore.Settings(
            projectLabels: [project.path: "Renamed"])
        try JSONEncoder().encode(existing).write(to: settingsURL)

        let store = GlobalSettingsStore(settingsURL: settingsURL) { _ in "bitboy" }
        let resolver = ProjectResolver(overrides: [],
                                       defaultPetID: "sample-pet",
                                       availablePetIDs: ["bitboy", "other"],
                                       settingsStore: store)

        let pid = resolver.resolve(cwd: project, agent: .claudeCode)
        XCTAssertEqual(pid.label, "Renamed")
        XCTAssertEqual(pid.petId, "bitboy")
    }

    func test_hardcodedOverrideStillBeatsSettingsLabel() throws {
        let settingsDir = makeTempDir()
        let settingsURL = settingsDir.appendingPathComponent("settings.json")
        let root = makeTempDir()
        mkdir(root.appendingPathComponent(".git"))
        let sub = root.appendingPathComponent("services/auth"); mkdir(sub)
        defer {
            try? FileManager.default.removeItem(at: settingsDir)
            try? FileManager.default.removeItem(at: root)
        }

        let existing = GlobalSettingsStore.Settings(
            projectLabels: ["\(root.path)/services/*": "FromSettings"])
        try JSONEncoder().encode(existing).write(to: settingsURL)

        let override = ProjectResolver.Override(
            matchGlob: "\(root.path)/services/*",
            label: "FromCodeOverride",
            petId: "wizard")
        let store = GlobalSettingsStore(settingsURL: settingsURL) { _ in "sample-pet" }
        let resolver = ProjectResolver(overrides: [override],
                                       defaultPetID: "sample-pet",
                                       settingsStore: store)

        XCTAssertEqual(resolver.resolve(cwd: sub, agent: .claudeCode).label, "FromCodeOverride")
    }

    func test_legacySettingsFileWithoutProjectLabels_decodesAndDefaultsEmpty() throws {
        let settingsDir = makeTempDir()
        let settingsURL = settingsDir.appendingPathComponent("settings.json")
        defer { try? FileManager.default.removeItem(at: settingsDir) }

        // Simulate a pre-projectLabels file: only the older keys present.
        let legacyJSON = #"""
        {"version":1,"projectPets":{},"windowOpacity":100}
        """#
        try legacyJSON.data(using: .utf8)!.write(to: settingsURL)

        let store = GlobalSettingsStore(settingsURL: settingsURL) { _ in "sample-pet" }
        XCTAssertNil(store.labelOverride(for: URL(fileURLWithPath: "/anywhere")))
    }

    func test_gitRootIsUsedAsProjectPetMappingKey() {
        let settingsDir = makeTempDir()
        let settingsURL = settingsDir.appendingPathComponent("settings.json")
        let root = makeTempDir()
        mkdir(root.appendingPathComponent(".git"))
        let subdir = root.appendingPathComponent("Sources/App"); mkdir(subdir)
        defer {
            try? FileManager.default.removeItem(at: settingsDir)
            try? FileManager.default.removeItem(at: root)
        }

        var chooseCount = 0
        let store = GlobalSettingsStore(settingsURL: settingsURL) { _ in
            chooseCount += 1
            return "project-pet"
        }
        let resolver = ProjectResolver(overrides: [],
                                       defaultPetID: "sample-pet",
                                       availablePetIDs: ["project-pet", "other"],
                                       settingsStore: store)

        XCTAssertEqual(resolver.resolve(cwd: subdir, agent: .claudeCode).petId, "project-pet")
        XCTAssertEqual(resolver.resolve(cwd: root, agent: .claudeCode).petId, "project-pet")
        XCTAssertEqual(chooseCount, 1)
    }
}
