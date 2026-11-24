import Foundation

enum CloudDownloads {
    static var folder: URL { AppHome.url.appending(path: "Library/Mobile Documents/com~apple~CloudDocs") }

    private static let keys: Set<URLResourceKey> = [
        .isRegularFileKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
        .ubiquitousItemIsUploadedKey, .ubiquitousItemIsUploadingKey, .ubiquitousItemHasUnresolvedConflictsKey,
        .ubiquitousItemIsDownloadingKey, .ubiquitousItemUploadingErrorKey, .ubiquitousItemDownloadingErrorKey
    ]

    static func canEvict(_ values: URLResourceValues) -> Bool {
        canEvict(regular: values.isRegularFile, ubiquitous: values.isUbiquitousItem,
                 status: values.ubiquitousItemDownloadingStatus, uploaded: values.ubiquitousItemIsUploaded,
                 uploading: values.ubiquitousItemIsUploading, downloading: values.ubiquitousItemIsDownloading,
                 conflicts: values.ubiquitousItemHasUnresolvedConflicts,
                 syncError: values.ubiquitousItemUploadingError != nil || values.ubiquitousItemDownloadingError != nil)
    }

    static func canEvict(regular: Bool?, ubiquitous: Bool?, status: URLUbiquitousItemDownloadingStatus?,
                         uploaded: Bool?, uploading: Bool?, downloading: Bool?, conflicts: Bool?, syncError: Bool) -> Bool {
        regular == true && ubiquitous == true && status == .current && uploaded == true &&
            uploading == false && downloading == false && conflicts == false && !syncError
    }

    static func candidate(_ input: URL) throws -> FileIdentity {
        let url = input.standardizedFileURL
        guard !AppHome.isDemo, url.path.hasPrefix(folder.path + "/"), CanonicalPath.url(url).path == url.path else {
            throw ScanError.invalidRoot
        }
        let fresh = URL(fileURLWithPath: url.path)
        guard let values = try? fresh.resourceValues(forKeys: keys), canEvict(values),
              let identity = TrashService.currentIdentity(url) else {
            throw CloudDownloadError.notReady
        }
        return identity
    }

    static func evict(_ url: URL, identity: FileIdentity) throws -> Bool {
        guard try candidate(url) == identity else { throw TrashError.changed }
        try TrashService.ensureUnused(url, isDirectory: false)
        guard try candidate(url) == identity else { throw TrashError.changed }
        try FileManager.default.evictUbiquitousItem(at: url)
        let fresh = URL(fileURLWithPath: url.path)
        return (try? fresh.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus) == .notDownloaded
    }

    struct LocalItem: Identifiable, Equatable, Sendable {
        let url: URL
        let bytes: Int64
        let modified: Date?
        let identity: FileIdentity
        var id: URL { url }
        var name: String { url.lastPathComponent }
    }

    /// Scans synced iCloud Drive files that occupy significant local disk space and can be safely evicted
    /// (`evictUbiquitousItem`) while keeping the cloud copy intact.
    static func scanLocalCopies(home: URL = AppHome.url, minBytes: Int64 = 20_000_000, limit: Int = 100) -> [LocalItem] {
        guard !AppHome.isDemo else { return [] }
        let root = home.appending(path: "Library/Mobile Documents/com~apple~CloudDocs")
        guard CanonicalPath.isDirect(root), FileManager.default.fileExists(atPath: root.path) else { return [] }
        let queryKeys = keys.union([.totalFileAllocatedSizeKey, .contentModificationDateKey])
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: Array(queryKeys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in true }
        ) else { return [] }

        var results: [LocalItem] = []
        var visited = 0
        for case let file as URL in enumerator {
            if Task.isCancelled { break }
            visited += 1
            if visited > 20_000 { break }
            guard let values = try? file.resourceValues(forKeys: queryKeys), canEvict(values) else { continue }
            let size = Int64(values.totalFileAllocatedSize ?? 0)
            guard size >= minBytes, let identity = TrashService.currentIdentity(file) else { continue }
            results.append(LocalItem(url: file, bytes: size, modified: values.contentModificationDate, identity: identity))
        }
        results.sort { $0.bytes > $1.bytes }
        return Array(results.prefix(limit))
    }

    enum CloudDownloadError: LocalizedError {
        case notReady
        var errorDescription: String? { "请选择已下载、已同步且无冲突的 iCloud 云盘文件。" }
    }
}

struct TimeMachineSnapshots: Sendable {
    var run: @Sendable ([String]) throws -> String = Self.runTMUtil

    func list() throws -> Set<String> {
        Self.parse(try run(["listlocalsnapshots", "/"]))
    }

    static func parse(_ output: String) -> Set<String> {
        Set(output.split(whereSeparator: \.isNewline).map(String.init).filter {
            $0.range(of: #"^com\.apple\.TimeMachine\.[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}\.local$"#,
                     options: .regularExpression) != nil
        })
    }

    /// Ask macOS to reclaim up to the requested target (default 10 GB). The target is not a promise of bytes freed.
    func thin(confirmed: Set<String>, targetBytes: Int64 = 10_000_000_000) throws -> (removed: Int, remaining: Set<String>) {
        let before = try list()
        guard !before.isEmpty, before.isSubset(of: confirmed) else { throw TrashError.changed }
        let bytesArg = String(max(targetBytes, 1_000_000_000))
        _ = try run(["thinlocalsnapshots", "/", bytesArg, "1"])
        let after = try list()
        return (before.subtracting(after).count, after)
    }

    static func runTMUtil(_ arguments: [String]) throws -> String {
        guard !AppHome.isDemo else { throw CommandError.unavailable }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        try process.run()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 20, execute: timeout)
        defer { timeout.cancel() }
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CommandError.unavailable }
        return String(decoding: bytes, as: UTF8.self)
    }

    enum CommandError: LocalizedError {
        case unavailable
        var errorDescription: String? { "系统未完成快照操作。请在 Time Machine 设置中管理本地快照。" }
    }
}
