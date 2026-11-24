import AppKit
import Foundation

/// High-level cleanup domain used by modular providers.
enum CleanCategory: String, CaseIterable, Codable, Sendable {
    case smartClean = "智能清理"
    case aiCreative = "创作与 AI"
    case developer = "开发与包缓存"
    case chat = "通讯与办公"
    case system = "系统维护"
    case appLeftover = "应用残留"
}

/// Permission tier required by a provider or action.
enum PermissionLevel: String, Codable, Sendable {
    case standard
    case fullDiskAccess
    case admin
}

/// How an item's size was measured so UI can communicate honesty about APFS sharing or CLI estimates.
enum ByteEstimate: Equatable, Sendable {
    case exactAllocated(Int64)
    case apfsSharedConservative(Int64)
    case cliEstimated(Int64)
    case unknown

    var bytes: Int64 {
        switch self {
        case .exactAllocated(let value), .apfsSharedConservative(let value), .cliEstimated(let value): value
        case .unknown: 0
        }
    }
}

/// Blocker preventing immediate cleanup, with structured data for one-click resolution.
enum ActionBlocker: Equatable, Sendable {
    case runningApp(bundleID: String, name: String)
    case needsFullDiskAccess
    case needsAdmin
}

/// Executable cleanup action routed through unified executors.
enum CleanAction: Equatable, Sendable {
    case trashFiles([URL])
    case runCLI(id: String)
    case evictCloud(URL)
    case thinSnapshots(targetBytes: Int64)
    case openGuide(String)
}

/// Uniform cleanup candidate produced by any `CleanerProvider`.
struct CleanCandidate: Identifiable, Equatable, Sendable {
    let id: String
    let category: CleanCategory
    let title: String
    let subtitle: String
    let risk: ScanRisk
    let estimate: ByteEstimate
    let action: CleanAction
    let blocker: ActionBlocker?
}

/// Shared immutable context passed to every `CleanerProvider`.
struct ScanContext: Sendable {
    let home: URL
    let policy: SafetyPolicy
    let hasFullDiskAccess: Bool
    let runningBundleIDs: Set<String>

    init(policy: SafetyPolicy = SafetyPolicy(),
         hasFullDiskAccess: Bool = false,
         runningBundleIDs: Set<String> = []) {
        self.home = policy.home
        self.policy = policy
        self.hasFullDiskAccess = hasFullDiskAccess
        self.runningBundleIDs = runningBundleIDs
    }
}

/// Modular provider contract: each cleanup domain owns its own discovery logic.
protocol CleanerProvider: Sendable {
    var id: String { get }
    var category: CleanCategory { get }
    var requiredPermission: PermissionLevel { get }

    func scan(context: ScanContext) async throws -> [CleanCandidate]
}

/// Concurrently runs registered `CleanerProvider`s and aggregates their candidates.
struct CleanupEngine: Sendable {
    let providers: [any CleanerProvider]

    func scanAll(context: ScanContext) async -> [CleanCandidate] {
        await withTaskGroup(of: [CleanCandidate].self) { group in
            for provider in providers {
                if provider.requiredPermission == .fullDiskAccess && !context.hasFullDiskAccess { continue }
                group.addTask {
                    (try? await provider.scan(context: context)) ?? []
                }
            }
            var all: [CleanCandidate] = []
            for await batch in group {
                all.append(contentsOf: batch)
            }
            return all.sorted { $0.estimate.bytes > $1.estimate.bytes }
        }
    }
}

/// Gracefully terminates blocking apps (such as browsers) before retrying cleanup.
/// Never force-kills (`kill -9`); waits for normal termination so unsaved tabs/sessions remain intact.
enum AppBlockerResolver {
    struct Result: Equatable, Sendable {
        let terminated: [String]
        let stillRunning: [String]

        var allExited: Bool { stillRunning.isEmpty }
    }

    @MainActor
    static func quitApps(bundleIDs: [String], timeout: TimeInterval = 6.0) async -> Result {
        let unique = Array(Set(bundleIDs)).sorted()
        var targets: [String: [NSRunningApplication]] = [:]
        for bundleID in unique {
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            if !apps.isEmpty {
                targets[bundleID] = apps
                for app in apps { _ = app.terminate() }
            }
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let remaining = targets.keys.filter { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }
            if remaining.isEmpty { break }
            do { try await Task.sleep(for: .milliseconds(150)) } catch { break }
        }
        let stillRunning = unique.filter { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }
        let terminated = unique.filter { targets[$0] != nil && !stillRunning.contains($0) }
        return Result(terminated: terminated, stillRunning: stillRunning)
    }
}
