// LittleGuyTests/Sessions/ProjectResolverTests.swift
import XCTest
@testable import LittleGuy

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
