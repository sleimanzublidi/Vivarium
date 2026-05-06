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
        let pid = resolver.resolve(cwd: sub)
        XCTAssertEqual(pid.url.standardizedFileURL, root.standardizedFileURL)
        XCTAssertEqual(pid.label, root.lastPathComponent)
        XCTAssertEqual(pid.petId, "sample-pet")
    }

    func test_fallsBackToCwd_whenNoGit() {
        let dir = makeTempDir()
        let resolver = ProjectResolver(overrides: [], defaultPetID: "sample-pet")
        let pid = resolver.resolve(cwd: dir)
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
        let pid = resolver.resolve(cwd: services)
        XCTAssertEqual(pid.url.standardizedFileURL, services.standardizedFileURL)
        XCTAssertEqual(pid.label, "auth-service")
        XCTAssertEqual(pid.petId, "wizard")
    }
}
