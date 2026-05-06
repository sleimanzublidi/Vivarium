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
    let defaultPetID: String

    func resolve(cwd: URL) -> ProjectIdentity {
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
                petId: defaultPetID
            )
        }

        // 3. cwd
        return ProjectIdentity(url: cwd, label: cwd.lastPathComponent, petId: defaultPetID)
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

private func fnmatch_strict(pattern: String, path: String) -> Bool {
    pattern.withCString { p in
        path.withCString { s in
            Darwin.fnmatch(p, s, FNM_PATHNAME) == 0
        }
    }
}
