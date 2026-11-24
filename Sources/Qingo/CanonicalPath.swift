import Foundation
import Darwin

enum CanonicalPath {
    /// Accept the standard macOS aliases used by Foundation, but reject linked cleanup targets and parents.
    static func isDirect(_ input: URL) -> Bool {
        let path = input.path
        guard input.isFileURL, path.hasPrefix("/"),
              !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { return false }
        let aliases = ["/var", "/tmp", "/etc"]
        let expected = aliases.contains { path == $0 || path.hasPrefix($0 + "/") } ? "/private" + path : path
        guard let resolved = realpath(path, nil) else { return false }
        defer { free(resolved) }
        return String(cString: resolved) == expected
    }

    static func url(_ input: URL) -> URL {
        guard let pointer = realpath(input.path, nil) else { return input.standardizedFileURL }
        defer { free(pointer) }
        return URL(fileURLWithPath: String(cString: pointer), isDirectory: input.hasDirectoryPath)
    }
}

/// The home folder the app scans. `QINGO_HOME` points it at a prepared folder for demos and screenshots,
/// so recordings never show anyone's real files.
enum AppHome {
    static let url: URL = ProcessInfo.processInfo.environment["QINGO_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.homeDirectoryForCurrentUser
    static var isDemo: Bool { ProcessInfo.processInfo.environment["QINGO_HOME"] != nil }

    /// Saved scan results and the free-space history. Tests point it at a temporary folder (`QINGO_RESULTS_DIR`).
    static var resultsDirectory: URL {
        let directory = ProcessInfo.processInfo.environment["QINGO_RESULTS_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Qingo/results")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
