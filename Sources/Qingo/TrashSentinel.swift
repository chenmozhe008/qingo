import AppKit
import Foundation

/// Lightweight zero-polling watcher on `~/.Trash` (inspired by Pearcleaner Sentinel / AppCleaner SmartDelete).
/// When the user drags a `.app` bundle into the Trash, detects its bundle ID and calculates leftover traces
/// so Qingo can offer one-click leftover cleanup.
final class TrashSentinel: @unchecked Sendable {
    struct TrashedAppAlert: Identifiable, Equatable, Sendable {
        let id: String
        let appName: String
        let bundleID: String
        let traceCount: Int
        let traceBytes: Int64
    }

    static let enabledKey = "trashSentinelEnabled"

    private let trashURL: URL
    private let onDetected: @Sendable (TrashedAppAlert) -> Void
    private var fileDescriptor: Int32 = -1
    private var source: DispatchSourceFileSystemObject?
    private var knownApps: Set<String> = []
    private let queue = DispatchQueue(label: "io.github.chenmozhe008.qingo.trash-sentinel", qos: .utility)

    init(trashURL: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".Trash"),
         onDetected: @escaping @Sendable (TrashedAppAlert) -> Void) {
        self.trashURL = trashURL
        self.onDetected = onDetected
    }

    deinit {
        stop()
    }

    func start() {
        guard !AppHome.isDemo else { return }
        queue.async { [weak self] in
            self?.startOnQueue()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.source?.cancel()
            self?.source = nil
            if let fd = self?.fileDescriptor, fd >= 0 {
                close(fd)
                self?.fileDescriptor = -1
            }
        }
    }

    private func startOnQueue() {
        guard source == nil else { return }
        knownApps = Self.currentAppNames(in: trashURL)
        let fd = open(trashURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        fileDescriptor = fd
        let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: queue)
        watcher.setEventHandler { [weak self] in
            self?.inspectChanges()
        }
        watcher.setCancelHandler {
            close(fd)
        }
        source = watcher
        watcher.resume()
    }

    private func inspectChanges() {
        let current = Self.currentAppNames(in: trashURL)
        let added = current.subtracting(knownApps)
        knownApps = current
        for name in added {
            let appURL = trashURL.appending(path: name)
            if let alert = Self.inspectTrashedApp(at: appURL) {
                onDetected(alert)
            }
        }
    }

    static func currentAppNames(in trashURL: URL) -> Set<String> {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: trashURL.path)) ?? []
        return Set(entries.filter { $0.hasSuffix(".app") })
    }

    /// Reads bundle metadata of a newly trashed `.app` and measures its leftover traces.
    static func inspectTrashedApp(at appURL: URL, home: URL = AppHome.url) -> TrashedAppAlert? {
        let plistURL = appURL.appending(path: "Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: plistURL),
              let bundleID = info["CFBundleIdentifier"] as? String,
              !bundleID.isEmpty,
              !bundleID.hasPrefix("com.apple.") else {
            return nil
        }
        let appName = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? appURL.deletingPathExtension().lastPathComponent
        let installed = InstalledApp(id: appURL, name: appName, bundleID: bundleID, version: nil)
        let uninstaller = AppUninstaller(policy: SafetyPolicy(home: home))
        let traces = uninstaller.traces(for: installed).filter { $0.kind != .app }
        let bytes = traces.reduce(Int64(0)) { $0 + $1.bytes }
        guard !traces.isEmpty, bytes > 0 else { return nil }
        return TrashedAppAlert(id: "\(bundleID)-\(appName)", appName: appName, bundleID: bundleID,
                               traceCount: traces.count, traceBytes: bytes)
    }
}
