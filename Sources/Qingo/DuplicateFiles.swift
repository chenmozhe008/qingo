import CryptoKit
import Darwin
import Foundation

struct DuplicateFiles: Sendable {
    static let minimumBytes: Int64 = 50_000_000
    let policy: SafetyPolicy

    struct File: Sendable, Equatable, Identifiable {
        let url: URL
        let bytes: Int64
        let identity: FileIdentity
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int
        var id: URL { url }
    }

    struct Group: Sendable, Identifiable {
        let digest: SHA256.Digest
        var files: [File]
        var id: SHA256.Digest { digest }
    }

    struct Result: Sendable {
        let groups: [Group]
        let unreadable: Int
    }

    func scan(_ folder: URL, ignoring ignored: Set<String> = []) throws -> Result {
        try scan(folders: [folder], minimumBytes: Self.minimumBytes, ignoring: ignored)
    }

    static func defaultUserFolders(home: URL = AppHome.url) -> [URL] {
        ["Downloads", "Desktop", "Documents", "Pictures"]
            .map { home.appending(path: $0) }
            .filter { CanonicalPath.isDirect($0) && FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Picks the oldest file in a duplicate group to keep by default when bulk-deduplicating.
    static func earliestKeeper(in group: Group) -> File? {
        group.files.min { lhs, rhs in
            if lhs.modifiedSeconds != rhs.modifiedSeconds { return lhs.modifiedSeconds < rhs.modifiedSeconds }
            return lhs.url.path < rhs.url.path
        }
    }

    /// Scans one or more folders using 3-stage deduplication:
    /// 1) Exact byte size bucket
    /// 2) 64 KB head + tail quick signature
    /// 3) Full streaming SHA-256 verification
    func scan(folders: [URL], minimumBytes: Int64 = DuplicateFiles.minimumBytes, ignoring ignored: Set<String> = []) throws -> Result {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .isPackageKey]
        var unreadable = 0
        var bySize: [Int64: [File]] = [:]
        var seenInodes: Set<FileIdentity> = []

        for folder in folders {
            let root = CanonicalPath.url(folder)
            guard allows(root), (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let rootIdentity = TrashService.currentIdentity(root) else {
                if folders.count == 1 { throw ScanError.unreadable(folder) }
                unreadable += 1
                continue
            }
            guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in unreadable += 1; return true }) else {
                if folders.count == 1 { throw ScanError.unreadable(root) }
                unreadable += 1
                continue
            }
            for case let url as URL in entries {
                try Task.checkCancellation()
                guard let values = try? url.resourceValues(forKeys: keys) else { unreadable += 1; continue }
                if values.isDirectory == true {
                    if ignored.contains(url.path) || !allows(url) ||
                        TrashService.currentIdentity(url)?.device != rootIdentity.device {
                        entries.skipDescendants()
                    }
                    continue
                }
                guard values.isRegularFile == true, Int64(values.fileSize ?? 0) >= minimumBytes,
                      !ignored.contains(url.path), allows(url),
                      let file = snapshot(url, minimumBytes: minimumBytes),
                      file.identity.device == rootIdentity.device,
                      seenInodes.insert(file.identity).inserted else { continue }
                bySize[file.bytes, default: []].append(file)
            }
        }

        // Stage 2: 64 KB head+tail prehash to eliminate false size matches without reading entire files.
        var groups: [Group] = []
        for candidates in bySize.values where candidates.count > 1 {
            var byPrehash: [SHA256.Digest: [File]] = [:]
            for file in candidates {
                try Task.checkCancellation()
                guard let pre = try? quickSignature(file, minimumBytes: minimumBytes) else { unreadable += 1; continue }
                byPrehash[pre, default: []].append(file)
            }
            // Stage 3: Full SHA-256 verification only for prehash collisions.
            for narrowed in byPrehash.values where narrowed.count > 1 {
                var matches: [SHA256.Digest: [File]] = [:]
                for file in narrowed {
                    try Task.checkCancellation()
                    guard let digest = try? hash(file, minimumBytes: minimumBytes) else { unreadable += 1; continue }
                    matches[digest, default: []].append(file)
                }
                groups += matches.compactMap { digest, files in
                    guard files.count > 1 else { return nil }
                    return Group(digest: digest, files: files.sorted { $0.url.path < $1.url.path })
                }
            }
        }
        try Task.checkCancellation()
        groups.sort {
            if $0.files[0].bytes != $1.files[0].bytes { return $0.files[0].bytes > $1.files[0].bytes }
            return $0.files[0].url.path < $1.files[0].url.path
        }
        return Result(groups: groups, unreadable: unreadable)
    }

    func move(_ file: File, keeping keeper: File, in group: Group) throws -> URL {
        let floor = min(file.bytes, keeper.bytes, Self.minimumBytes)
        guard file.url != keeper.url, group.files.contains(file), group.files.contains(keeper),
              try hash(file, minimumBytes: floor) == group.digest, try hash(keeper, minimumBytes: floor) == group.digest else { throw TrashError.changed }
        let item = ScanItem(id: file.url, url: file.url, kind: .largeFile, risk: .c, bytes: file.bytes,
                            note: "重复文件", canTrash: false, identity: file.identity)
        return try TrashService(policy: policy).moveToTrash(item) {
            guard snapshot(file.url, minimumBytes: floor) == file, snapshot(keeper.url, minimumBytes: floor) == keeper else { throw TrashError.changed }
        }
    }

    private func allows(_ url: URL) -> Bool {
        let path = url.path
        guard path == policy.home.path || path.hasPrefix(policy.home.path + "/") || path.hasPrefix("/Volumes/"),
              CanonicalPath.url(url).path == path, !policy.isProtected(url) else { return false }
        // Stay out of app data, cloud providers, and the contents of project or app packages.
        let library = policy.home.appending(path: "Library").path
        guard path != library, !path.hasPrefix(library + "/") else { return false }
        var parent = url
        while parent.path != "/" && parent.path != policy.home.path {
            guard !parent.lastPathComponent.hasPrefix("."),
                  !policy.isProject(parent),
                  let values = try? parent.resourceValues(forKeys: [.isPackageKey, .isUbiquitousItemKey]),
                  values.isPackage != true, values.isUbiquitousItem != true else { return false }
            parent.deleteLastPathComponent()
        }
        return true
    }

    private func snapshot(_ url: URL, minimumBytes: Int64 = DuplicateFiles.minimumBytes) -> File? {
        var statInfo = stat()
        guard allows(url), lstat(url.path, &statInfo) == 0 else { return nil }
        // A resource fork can hold additional content that is independent of the data fork.
        guard getxattr(url.path, "com.apple.ResourceFork", nil, 0, 0, XATTR_NOFOLLOW) < 0,
              errno == ENOATTR else { return nil }
        return Self.file(url, statInfo, minimumBytes: minimumBytes)
    }

    private static func file(_ url: URL, _ info: stat, minimumBytes: Int64 = DuplicateFiles.minimumBytes) -> File? {
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1,
              info.st_flags & UInt32(SF_DATALESS) == 0, info.st_size >= minimumBytes else { return nil }
        return File(url: url, bytes: info.st_size, identity: FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino)),
                    modifiedSeconds: info.st_mtimespec.tv_sec, modifiedNanoseconds: info.st_mtimespec.tv_nsec,
                    changedSeconds: info.st_ctimespec.tv_sec, changedNanoseconds: info.st_ctimespec.tv_nsec)
    }

    private func quickSignature(_ file: File, minimumBytes: Int64) throws -> SHA256.Digest {
        let sampleSize = 64 * 1024
        guard snapshot(file.url, minimumBytes: minimumBytes) == file else { throw TrashError.changed }
        let descriptor = open(file.url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw TrashError.changed }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, Self.file(file.url, info, minimumBytes: minimumBytes) == file else { throw TrashError.changed }
        var sha = SHA256()
        if let head = try handle.read(upToCount: sampleSize) { sha.update(data: head) }
        if file.bytes > Int64(sampleSize * 2) {
            try handle.seek(toOffset: UInt64(file.bytes - Int64(sampleSize)))
            if let tail = try handle.read(upToCount: sampleSize) { sha.update(data: tail) }
        }
        return sha.finalize()
    }

    private func hash(_ file: File, minimumBytes: Int64 = DuplicateFiles.minimumBytes) throws -> SHA256.Digest {
        guard snapshot(file.url, minimumBytes: minimumBytes) == file else { throw TrashError.changed }
        let descriptor = open(file.url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw TrashError.changed }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, Self.file(file.url, info, minimumBytes: minimumBytes) == file else { throw TrashError.changed }
        var sha = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            sha.update(data: chunk)
        }
        guard snapshot(file.url, minimumBytes: minimumBytes) == file else { throw TrashError.changed }
        return sha.finalize()
    }
}
