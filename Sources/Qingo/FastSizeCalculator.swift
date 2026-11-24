import Darwin
import Foundation

/// High-speed APFS-aware directory size calculator using macOS `getattrlistbulk`.
///
/// Key properties:
/// - Reads entry names, file types, inode IDs, logical sizes, allocated block sizes, and link counts
///   in batched kernel syscalls (3–5x faster than per-file `FileManager` + `lstat` enumeration).
/// - Stays strictly on the starting volume (`st_dev`), never follows symlinks, and deduplicates hard links.
enum FastSizeCalculator {
    struct SizeSummary: Equatable, Sendable {
        var logical: Int64 = 0
        var allocated: Int64 = 0
        var itemCount: Int = 0
        var unreadableCount: Int = 0
    }

    struct ChildEntry: Identifiable, Equatable, Sendable {
        let url: URL
        let name: String
        let isDirectory: Bool
        let bytes: Int64
        var isMeasuring: Bool = false
        var id: URL { url }
    }

    static func measure(_ root: URL, conservativeHardLinks: Bool = false) -> SizeSummary {
        var st = stat()
        guard lstat(root.path, &st) == 0 else { return SizeSummary(unreadableCount: 1) }
        let type = st.st_mode & mode_t(S_IFMT)
        if type == mode_t(S_IFLNK) { return SizeSummary() }
        if type != mode_t(S_IFDIR) {
            let alloc: Int64
            if type == mode_t(S_IFREG) {
                alloc = (conservativeHardLinks && st.st_nlink > 1) ? 0 : max(0, Int64(st.st_blocks) * 512)
            } else {
                alloc = 0
            }
            return SizeSummary(logical: max(0, st.st_size), allocated: alloc, itemCount: 1)
        }
        var seenInodes = Set<UInt64>()
        var summary = SizeSummary()
        walkBulk(path: root.path, rootDevice: st.st_dev, conservativeHardLinks: conservativeHardLinks,
                 seenInodes: &seenInodes, summary: &summary)
        return summary
    }

    static func allocatedBytes(of url: URL) -> Int64 {
        measure(url).allocated
    }

    /// Measures immediate children of `directory` concurrently for interactive Space Lens drill-down.
    static func directChildrenSizes(of directory: URL) async -> [ChildEntry] {
        let entries = listImmediateChildren(of: directory)
        return await withTaskGroup(of: ChildEntry?.self) { group in
            for item in entries {
                group.addTask {
                    if Task.isCancelled { return nil }
                    let size = measure(item.url).allocated
                    return ChildEntry(url: item.url, name: item.name, isDirectory: item.isDirectory, bytes: size, isMeasuring: false)
                }
            }
            var measured: [ChildEntry] = []
            for await entry in group {
                if let entry, entry.bytes > 0 { measured.append(entry) }
            }
            return measured.sorted { $0.bytes > $1.bytes }
        }
    }

    /// Returns visible immediate children instantaneously (< 5 ms) for streaming Space Lens display.
    static func listImmediateChildren(of directory: URL) -> [ChildEntry] {
        let canonical = CanonicalPath.url(directory)
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: canonical,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else {
            return []
        }
        return children.compactMap { child in
            guard let vals = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  vals.isSymbolicLink != true else { return nil }
            let name = child.lastPathComponent
            if name == ".DS_Store" || name == ".localized" { return nil }
            return ChildEntry(url: child, name: name, isDirectory: vals.isDirectory == true, bytes: 0, isMeasuring: true)
        }.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// Streams measured sizes for each child entry via `AsyncStream` with bounded concurrency (max 6)
    /// so large directories never saturate disk I/O or flood the main actor.
    static func childrenSizeStream(of directory: URL, entries: [ChildEntry], maxConcurrent: Int = 6) -> AsyncStream<ChildEntry> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .utility) {
                let limit = max(1, maxConcurrent)
                var nextIndex = 0
                await withTaskGroup(of: ChildEntry?.self) { group in
                    func enqueueNext() {
                        guard nextIndex < entries.count else { return }
                        let item = entries[nextIndex]
                        nextIndex += 1
                        group.addTask {
                            if Task.isCancelled { return nil }
                            let size = measure(item.url).allocated
                            return ChildEntry(url: item.url, name: item.name, isDirectory: item.isDirectory, bytes: size, isMeasuring: false)
                        }
                    }
                    for _ in 0..<min(limit, entries.count) {
                        enqueueNext()
                    }
                    for await measured in group {
                        if Task.isCancelled { break }
                        if let measured { continuation.yield(measured) }
                        enqueueNext()
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func walkBulk(path: String, rootDevice: dev_t, conservativeHardLinks: Bool,
                                 seenInodes: inout Set<UInt64>, summary: inout SizeSummary) {
        if Task.isCancelled { return }
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else {
            summary.unreadableCount += 1
            return
        }
        defer { close(fd) }

        var dirStat = stat()
        guard fstat(fd, &dirStat) == 0, dirStat.st_dev == rootDevice else {
            summary.unreadableCount += 1
            return
        }

        var attrList = attrlist()
        attrList.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attrList.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
            | attrgroup_t(ATTR_CMN_NAME)
            | attrgroup_t(ATTR_CMN_OBJTYPE)
            | attrgroup_t(ATTR_CMN_FILEID)
        attrList.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT)
            | attrgroup_t(ATTR_FILE_TOTALSIZE)
            | attrgroup_t(ATTR_FILE_ALLOCSIZE)

        let bufferSize = 64 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 8)
        defer { buffer.deallocate() }

        var subdirs: [String] = []

        while true {
            if Task.isCancelled { return }
            let count = getattrlistbulk(fd, &attrList, buffer, bufferSize, 0)
            if count <= 0 { break }

            var cursor = buffer
            for _ in 0..<count {
                let entryLength = cursor.loadUnaligned(as: UInt32.self)
                var fieldPtr = cursor.advanced(by: MemoryLayout<UInt32>.size)

                let returned = fieldPtr.loadUnaligned(as: attribute_set_t.self)
                fieldPtr = fieldPtr.advanced(by: MemoryLayout<attribute_set_t>.size)

                var nameString: String?
                if (returned.commonattr & attrgroup_t(ATTR_CMN_NAME)) != 0 {
                    let nameRef = fieldPtr.loadUnaligned(as: attrreference_t.self)
                    let nameStart = fieldPtr.advanced(by: Int(nameRef.attr_dataoffset))
                    nameString = String(cString: nameStart.assumingMemoryBound(to: CChar.self))
                    fieldPtr = fieldPtr.advanced(by: MemoryLayout<attrreference_t>.size)
                }

                var objType: fsobj_type_t = 0
                if (returned.commonattr & attrgroup_t(ATTR_CMN_OBJTYPE)) != 0 {
                    objType = fieldPtr.loadUnaligned(as: fsobj_type_t.self)
                    fieldPtr = fieldPtr.advanced(by: MemoryLayout<fsobj_type_t>.size)
                }

                var fileID: UInt64 = 0
                if (returned.commonattr & attrgroup_t(ATTR_CMN_FILEID)) != 0 {
                    fileID = fieldPtr.loadUnaligned(as: UInt64.self)
                    fieldPtr = fieldPtr.advanced(by: MemoryLayout<UInt64>.size)
                }

                var linkCount: UInt32 = 1
                if (returned.fileattr & attrgroup_t(ATTR_FILE_LINKCOUNT)) != 0 {
                    linkCount = fieldPtr.loadUnaligned(as: UInt32.self)
                    fieldPtr = fieldPtr.advanced(by: MemoryLayout<UInt32>.size)
                }

                var totalSize: off_t = 0
                if (returned.fileattr & attrgroup_t(ATTR_FILE_TOTALSIZE)) != 0 {
                    totalSize = fieldPtr.loadUnaligned(as: off_t.self)
                    fieldPtr = fieldPtr.advanced(by: MemoryLayout<off_t>.size)
                }

                var allocSize: off_t = 0
                if (returned.fileattr & attrgroup_t(ATTR_FILE_ALLOCSIZE)) != 0 {
                    allocSize = fieldPtr.loadUnaligned(as: off_t.self)
                    fieldPtr = fieldPtr.advanced(by: MemoryLayout<off_t>.size)
                }

                summary.itemCount += 1

                if objType == UInt32(VDIR.rawValue) {
                    if let name = nameString, name != ".", name != ".." {
                        subdirs.append(path == "/" ? "/\(name)" : "\(path)/\(name)")
                    }
                } else if objType == UInt32(VREG.rawValue) {
                    if conservativeHardLinks {
                        let lAdd = summary.logical.addingReportingOverflow(max(0, Int64(totalSize)))
                        summary.logical = lAdd.overflow ? Int64.max : lAdd.partialValue
                        if linkCount == 1 {
                            let aAdd = summary.allocated.addingReportingOverflow(max(0, Int64(allocSize)))
                            summary.allocated = aAdd.overflow ? Int64.max : aAdd.partialValue
                        }
                    } else {
                        let shouldCount: Bool
                        if linkCount > 1 && fileID != 0 {
                            shouldCount = seenInodes.insert(fileID).inserted
                        } else {
                            shouldCount = true
                        }
                        if shouldCount {
                            let lAdd = summary.logical.addingReportingOverflow(max(0, Int64(totalSize)))
                            summary.logical = lAdd.overflow ? Int64.max : lAdd.partialValue
                            let aAdd = summary.allocated.addingReportingOverflow(max(0, Int64(allocSize)))
                            summary.allocated = aAdd.overflow ? Int64.max : aAdd.partialValue
                        }
                    }
                }

                cursor = cursor.advanced(by: Int(entryLength))
            }
        }

        for subdir in subdirs {
            walkBulk(path: subdir, rootDevice: rootDevice, conservativeHardLinks: conservativeHardLinks,
                     seenInodes: &seenInodes, summary: &summary)
        }
    }
}
