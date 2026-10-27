import Foundation
import Darwin

enum CanonicalPath {
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
}
