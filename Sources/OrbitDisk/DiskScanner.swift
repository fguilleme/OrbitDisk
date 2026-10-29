import Darwin
import Foundation

enum ScanError: LocalizedError {
    case cancelled
    case cannotRead(URL)

    var errorDescription: String? {
        switch self {
        case .cancelled: "Analyse annulée"
        case .cannotRead(let url): "Impossible de lire \(url.path)"
        }
    }
}

private actor BulkProgressMerger {
    private let path: String
    private let baseItems: Int
    private let baseBytes: Int64
    private let baseInaccessible: Int
    private let totalBranches: Int
    private let started = ContinuousClock.now
    private var branches: [Int: ScanProgress] = [:]
    private var completedBranches: Set<Int> = []

    init(base: ScanProgress, totalBranches: Int) {
        path = base.path
        baseItems = base.items
        baseBytes = base.bytes
        baseInaccessible = base.inaccessibleItems
        self.totalBranches = totalBranches
    }

    func record(
        branch: Int,
        snapshot: ScanProgress,
        sink: @escaping @Sendable (ScanProgress) async -> Void
    ) async {
        if let previous = branches[branch], previous.items > snapshot.items { return }
        branches[branch] = snapshot
        completedBranches.insert(branch)
        await emit(path: snapshot.path, sink: sink)
    }

    func pulse(
        sink: @escaping @Sendable (ScanProgress) async -> Void
    ) async {
        await emit(path: path, sink: sink)
    }

    private func emit(
        path currentPath: String,
        sink: @escaping @Sendable (ScanProgress) async -> Void
    ) async {
        let combined = branches.values.reduce(
            into: (items: baseItems, bytes: baseBytes, inaccessible: baseInaccessible)
        ) { result, value in
            result.items += value.items
            result.bytes += value.bytes
            result.inaccessible += value.inaccessibleItems
        }
        let elapsed = started.duration(to: .now)
        let seconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
        // A full startup-volume scan currently takes roughly 30–35 seconds on
        // the reference SSD. This heartbeat makes ongoing native I/O visible;
        // completed branches remain the lower bound, and 94% is never crossed
        // until every worker has actually returned.
        let temporalFraction = min(0.94, max(0.01, seconds / 34 * 0.94))
        let completedFraction = totalBranches > 0
            ? Double(completedBranches.count) / Double(totalBranches)
            : 0
        await sink(ScanProgress(
            path: currentPath,
            items: combined.items,
            bytes: combined.bytes,
            inaccessibleItems: combined.inaccessible,
            estimatedFraction: max(temporalFraction, completedFraction)
        ))
    }
}

actor DiskScanner {
    private enum BulkScanError: Error {
        case unsupported
    }

    private struct BulkJob: Sendable {
        let id: Int
        let path: String
        let name: String
        let homeIndex: Int?
        let priority: Int
    }

    private struct BulkBranchResult: Sendable {
        let id: Int
        let node: DiskNode
        let totals: Totals
    }

    private struct HomeSkeleton {
        var accumulator: DirectoryAccumulator
        var jobIDs: [Int]
    }

    private struct FileIdentity: Hashable {
        let device: UInt64
        let inode: UInt64
    }

    private struct Totals: Sendable {
        var items = 0
        var bytes: Int64 = 0
        var inaccessible = 0
        var lastReport = ContinuousClock.now
    }

    /// Keeps only the largest children while their directory is being scanned.
    /// This avoids creating a huge temporary object graph for directories such
    /// as node_modules, caches, and Time Machine snapshots.
    private struct DirectoryAccumulator {
        let path: String
        let name: String
        let limit: Int
        var bytes: Int64 = 0
        var itemCount = 1
        var retained: [DiskNode] = []
        var omittedBytes: Int64 = 0
        var omittedItems = 0

        func shouldRetain(size: Int64) -> Bool {
            retained.count < limit || size > retained[0].size
        }

        mutating func addOmitted(size: Int64, itemCount: Int = 1) {
            bytes += size
            self.itemCount += itemCount
            omittedBytes += size
            omittedItems += itemCount
        }

        mutating func addFile(
            path: String,
            name: String,
            size: Int64,
            kind: DiskNode.Kind = .file,
            unreadable: Bool = false
        ) {
            bytes += size
            itemCount += 1

            guard retained.count < limit || size > retained[0].size else {
                omittedBytes += size
                omittedItems += 1
                return
            }

            let node = DiskNode(
                id: path,
                name: name,
                url: URL(fileURLWithPath: path),
                size: size,
                itemCount: 1,
                kind: kind,
                children: [],
                isUnreadable: unreadable
            )
            retainOrAggregate(node)
        }

        mutating func addNode(_ node: DiskNode) {
            bytes += node.size
            itemCount += node.itemCount
            retainOrAggregate(node)
        }

        mutating func finish(unreadable: Bool = false) -> DiskNode {
            retained.sort(by: Self.isPreferred)
            if omittedItems > 0 {
                retained.append(DiskNode(
                    id: path + "/.orbit-other",
                    name: "Autres éléments",
                    url: nil,
                    size: omittedBytes,
                    itemCount: omittedItems,
                    kind: .aggregate,
                    children: [],
                    isUnreadable: false
                ))
            }

            return DiskNode(
                id: path,
                name: name,
                url: URL(fileURLWithPath: path, isDirectory: true),
                size: bytes,
                itemCount: itemCount,
                kind: .folder,
                children: retained,
                isUnreadable: unreadable
            )
        }

        private mutating func retainOrAggregate(_ node: DiskNode) {
            guard retained.count >= limit else {
                retained.append(node)
                if retained.count == limit { makeMinHeap() }
                return
            }

            if node.size > retained[0].size {
                let removed = retained[0]
                omittedBytes += removed.size
                omittedItems += removed.itemCount
                retained[0] = node
                siftDown(from: 0)
            } else {
                omittedBytes += node.size
                omittedItems += node.itemCount
            }
        }

        private mutating func makeMinHeap() {
            guard retained.count > 1 else { return }
            for index in stride(from: retained.count / 2 - 1, through: 0, by: -1) {
                siftDown(from: index)
            }
        }

        private mutating func siftDown(from start: Int) {
            var parent = start
            while true {
                let left = parent * 2 + 1
                guard left < retained.count else { return }
                let right = left + 1
                var smallest = left
                if right < retained.count, retained[right].size < retained[left].size {
                    smallest = right
                }
                guard retained[smallest].size < retained[parent].size else { return }
                retained.swapAt(parent, smallest)
                parent = smallest
            }
        }

        private static func isPreferred(_ lhs: DiskNode, _ rhs: DiskNode) -> Bool {
            if lhs.size != rhs.size { return lhs.size > rhs.size }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    func scan(
        _ rootURL: URL,
        progress: @escaping @Sendable (ScanProgress) async -> Void
    ) async throws -> DiskNode {
        let url = rootURL.standardizedFileURL
        let worker = Task.detached(priority: .userInitiated) {
            var totals = Totals()
            let report: (ScanProgress) -> Void = { snapshot in
                Task { await progress(snapshot) }
            }
            let node: DiskNode
            do {
                node = try await Self.walkBulk(
                    url,
                    totals: &totals,
                    report: report,
                    progress: progress
                )
            } catch BulkScanError.unsupported {
                totals = Totals()
                node = try Self.walkNative(url, totals: &totals, report: report)
            }
            await progress(ScanProgress(
                path: url.path,
                items: totals.items,
                bytes: totals.bytes,
                inaccessibleItems: totals.inaccessible,
                estimatedFraction: 1
            ))
            return node
        }

        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    /// APFS returns names, types and allocation sizes for many entries in one
    /// syscall. A single reusable buffer avoids an allocation per directory;
    /// file names are decoded only for nodes retained by the visual hierarchy.
    private static func walkBulk(
        _ rootURL: URL,
        totals: inout Totals,
        report: (ScanProgress) -> Void,
        progress: @escaping @Sendable (ScanProgress) async -> Void
    ) async throws -> DiskNode {
        if rootURL.path == "/" {
            let result = try await walkRootBulkParallel(rootURL, progress: progress)
            totals = result.totals
            return result.node
        }

        let descriptor = open(rootURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw ScanError.cannotRead(rootURL) }
        defer { close(descriptor) }

        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        return try scanDirectoryBulk(
            descriptor: descriptor,
            path: rootURL.path,
            name: rootURL.lastPathComponent.ifEmpty("Macintosh HD"),
            isRoot: true,
            buffer: &buffer,
            totals: &totals,
            report: report
        )
    }

    /// Splits only the startup-volume root and user homes into independent
    /// jobs. The global limit keeps four bulk readers busy without recursively
    /// multiplying tasks or holding parent file descriptors open.
    private static func walkRootBulkParallel(
        _ rootURL: URL,
        progress: @escaping @Sendable (ScanProgress) async -> Void
    ) async throws -> (node: DiskNode, totals: Totals) {
        var planningTotals = Totals()
        var rootAccumulator = DirectoryAccumulator(
            path: rootURL.path,
            name: rootURL.lastPathComponent.ifEmpty("Macintosh HD"),
            limit: 64
        )
        var usersAccumulator: DirectoryAccumulator?
        var homes: [HomeSkeleton] = []
        var jobs: [BulkJob] = []
        var nextJobID = 0

        let rootEntries = try directEntries(at: rootURL)
        for entry in rootEntries {
            if shouldSkipSyntheticRootEntry(entry.url.path) { continue }
            if entry.isScannableDirectory {
                if entry.url.path == "/Users" {
                    do {
                        var users = DirectoryAccumulator(path: "/Users", name: "Users", limit: 24)
                        for userEntry in try directEntries(at: entry.url) {
                            if userEntry.isScannableDirectory {
                                var home = HomeSkeleton(
                                    accumulator: DirectoryAccumulator(
                                        path: userEntry.url.path,
                                        name: userEntry.url.lastPathComponent,
                                        limit: 24
                                    ),
                                    jobIDs: []
                                )
                                let homeIndex = homes.count
                                do {
                                    for child in try directEntries(at: userEntry.url) {
                                        if child.isScannableDirectory {
                                            let job = BulkJob(
                                                id: nextJobID,
                                                path: child.url.path,
                                                name: child.url.lastPathComponent,
                                                homeIndex: homeIndex,
                                                priority: jobPriority(path: child.url.path)
                                            )
                                            jobs.append(job)
                                            home.jobIDs.append(nextJobID)
                                            nextJobID += 1
                                        } else {
                                            addDirectFile(
                                                child,
                                                to: &home.accumulator,
                                                totals: &planningTotals
                                            )
                                        }
                                    }
                                } catch {
                                    let job = BulkJob(
                                        id: nextJobID,
                                        path: userEntry.url.path,
                                        name: userEntry.url.lastPathComponent,
                                        homeIndex: nil,
                                        priority: 1
                                    )
                                    jobs.append(job)
                                    nextJobID += 1
                                    continue
                                }
                                homes.append(home)
                            } else {
                                addDirectFile(userEntry, to: &users, totals: &planningTotals)
                            }
                        }
                        usersAccumulator = users
                    } catch {
                        jobs.append(BulkJob(
                            id: nextJobID,
                            path: entry.url.path,
                            name: entry.url.lastPathComponent,
                            homeIndex: nil,
                            priority: 0
                        ))
                        nextJobID += 1
                    }
                } else {
                    jobs.append(BulkJob(
                        id: nextJobID,
                        path: entry.url.path,
                        name: entry.url.lastPathComponent,
                        homeIndex: nil,
                        priority: jobPriority(path: entry.url.path)
                    ))
                    nextJobID += 1
                }
            } else {
                addDirectFile(entry, to: &rootAccumulator, totals: &planningTotals)
            }
        }

        jobs.sort {
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            return $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }

        let baseProgress = ScanProgress(
            path: rootURL.path,
            items: planningTotals.items,
            bytes: planningTotals.bytes,
            inaccessibleItems: planningTotals.inaccessible
        )
        let merger = BulkProgressMerger(base: baseProgress, totalBranches: jobs.count)
        let heartbeat = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                await merger.pulse(sink: progress)
                do {
                    try await Task.sleep(for: .milliseconds(125))
                } catch {
                    return
                }
            }
        }
        defer { heartbeat.cancel() }
        var results: [Int: BulkBranchResult] = [:]
        results.reserveCapacity(jobs.count)

        try await withThrowingTaskGroup(of: BulkBranchResult.self) { group in
            var next = 0
            for _ in 0..<min(4, jobs.count) {
                let job = jobs[next]
                next += 1
                group.addTask(priority: .userInitiated) {
                    try await scanBulkJob(job, merger: merger, progress: progress)
                }
            }

            while let result = try await group.next() {
                results[result.id] = result
                if next < jobs.count {
                    let job = jobs[next]
                    next += 1
                    group.addTask(priority: .userInitiated) {
                        try await scanBulkJob(job, merger: merger, progress: progress)
                    }
                }
            }
        }

        for job in jobs where job.homeIndex == nil {
            if let node = results[job.id]?.node { rootAccumulator.addNode(node) }
        }

        if var users = usersAccumulator {
            for index in homes.indices {
                var home = homes[index]
                for id in home.jobIDs {
                    if let node = results[id]?.node { home.accumulator.addNode(node) }
                }
                users.addNode(home.accumulator.finish())
            }
            rootAccumulator.addNode(users.finish())
        }

        for result in results.values {
            planningTotals.items += result.totals.items
            planningTotals.bytes += result.totals.bytes
            planningTotals.inaccessible += result.totals.inaccessible
        }
        return (rootAccumulator.finish(), planningTotals)
    }

    private static func shouldSkipSyntheticRootEntry(_ path: String) -> Bool {
        let name = URL(fileURLWithPath: path).lastPathComponent
        switch name {
        case ".file", ".nofollow", ".resolve", ".vol",
             "Volumes", "Network", "net", "home", "dev":
            return true
        default:
            return false
        }
    }

    private struct DirectEntry {
        let url: URL
        let isScannableDirectory: Bool
        let allocatedSize: Int64
    }

    private static func directEntries(at url: URL) throws -> [DirectEntry] {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isSymbolicLinkKey, .isVolumeKey,
            .fileAllocatedSizeKey, .totalFileAllocatedSizeKey
        ]
        return try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: []
        ).map { child in
            let values = try child.resourceValues(forKeys: keys)
            let isDirectory = values.isDirectory == true
                && values.isSymbolicLink != true
                && values.isVolume != true
            let size = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            return DirectEntry(url: child, isScannableDirectory: isDirectory, allocatedSize: size)
        }
    }

    private static func addDirectFile(
        _ entry: DirectEntry,
        to accumulator: inout DirectoryAccumulator,
        totals: inout Totals
    ) {
        totals.items += 1
        totals.bytes += entry.allocatedSize
        accumulator.addFile(
            path: entry.url.path,
            name: entry.url.lastPathComponent,
            size: entry.allocatedSize
        )
    }

    private static func jobPriority(path: String) -> Int {
        let name = URL(fileURLWithPath: path).lastPathComponent
        if path.hasPrefix("/Users/"), name == "Library" { return 0 }
        if path.hasPrefix("/Users/"), name == ".npm" { return 1 }
        switch path {
        case "/System": return 0
        case "/Library": return 1
        case "/Applications": return 2
        case "/opt", "/private": return 3
        default: return 10
        }
    }

    private static func scanBulkJob(
        _ job: BulkJob,
        merger: BulkProgressMerger,
        progress: @escaping @Sendable (ScanProgress) async -> Void
    ) async throws -> BulkBranchResult {
        let node: DiskNode
        do {
            node = try await scanWithNativeDU(path: job.path, name: job.name)
        } catch ScanError.cannotRead {
            var unreadable = DirectoryAccumulator(path: job.path, name: job.name, limit: 24)
            node = unreadable.finish(unreadable: true)
        }
        var totals = Totals()
        totals.items = node.itemCount
        totals.bytes = node.size
        totals.inaccessible = node.isUnreadable ? 1 : 0

        await merger.record(
            branch: job.id,
            snapshot: ScanProgress(
                path: job.path,
                items: totals.items,
                bytes: totals.bytes,
                inaccessibleItems: totals.inaccessible
            ),
            sink: progress
        )
        return BulkBranchResult(id: job.id, node: node, totals: totals)
    }

    /// Apple's `du` is a compact C/fts implementation with hard-link
    /// deduplication. Limiting its output depth keeps the transfer small while
    /// still providing every ring the current sunburst can display.
    private static func scanWithNativeDU(path: String, name: String) async throws -> DiskNode {
        let process = Process()
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("orbitdisk-du-\(UUID().uuidString).txt")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil),
              let output = try? FileHandle(forWritingTo: outputURL) else {
            throw ScanError.cannotRead(URL(fileURLWithPath: path))
        }
        defer {
            try? output.close()
            try? FileManager.default.removeItem(at: outputURL)
        }
        process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        var arguments = ["-k", "-x", "-d", "6"]
        if path == "/System" || path == "/Library" {
            arguments += ["-I", "Volumes"]
        } else if path == "/private" {
            arguments += ["-I", "com.apple.security.cryptexd"]
        }
        arguments.append(path)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        try process.run()

        do {
            while process.isRunning {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(20))
            }
        } catch {
            if process.isRunning { process.terminate() }
            throw ScanError.cancelled
        }

        try output.close()
        let data = try Data(contentsOf: outputURL, options: .mappedIfSafe)
        return try buildDUTree(data: data, rootPath: path, rootName: name)
    }

    private static func buildDUTree(
        data: Data,
        rootPath: String,
        rootName: String
    ) throws -> DiskNode {
        let normalizedRoot = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        var sizes: [String: Int64] = [:]
        sizes.reserveCapacity(max(64, data.count / 80))

        for line in data.split(separator: 0x0A) {
            guard let separator = line.firstIndex(of: 0x09), separator > line.startIndex,
                  let blocks = Int64(String(decoding: line[..<separator], as: UTF8.self)) else {
                continue
            }
            let pathStart = line.index(after: separator)
            let itemPath = String(decoding: line[pathStart...], as: UTF8.self)
            guard itemPath == normalizedRoot || itemPath.hasPrefix(normalizedRoot + "/") else {
                continue
            }
            sizes[itemPath] = blocks * 1_024
        }

        guard sizes[normalizedRoot] != nil else {
            throw ScanError.cannotRead(URL(fileURLWithPath: normalizedRoot))
        }

        var childrenByParent: [String: [String]] = [:]
        childrenByParent.reserveCapacity(sizes.count / 3)
        for itemPath in sizes.keys where itemPath != normalizedRoot {
            let parent = URL(fileURLWithPath: itemPath).deletingLastPathComponent().path
            if sizes[parent] != nil {
                childrenByParent[parent, default: []].append(itemPath)
            }
        }

        func makeNode(path: String, name: String, isRoot: Bool = false) -> DiskNode {
            let size = sizes[path] ?? 0
            let limit = isRoot ? 64 : 24
            let childPaths = (childrenByParent[path] ?? []).sorted {
                let left = sizes[$0] ?? 0
                let right = sizes[$1] ?? 0
                if left != right { return left > right }
                return $0.localizedStandardCompare($1) == .orderedAscending
            }
            let retainedPaths = Array(childPaths.prefix(limit))
            var children = retainedPaths.map {
                makeNode(path: $0, name: URL(fileURLWithPath: $0).lastPathComponent)
            }
            let represented = retainedPaths.reduce(Int64(0)) { $0 + (sizes[$1] ?? 0) }
            let aggregateSize = max(0, size - represented)
            if aggregateSize > 0 {
                children.append(DiskNode(
                    id: path + "/.orbit-other",
                    name: "Autres éléments",
                    url: nil,
                    size: aggregateSize,
                    itemCount: max(1, childPaths.count - retainedPaths.count),
                    kind: .aggregate,
                    children: [],
                    isUnreadable: false
                ))
            }
            return DiskNode(
                id: path,
                name: name,
                url: URL(fileURLWithPath: path, isDirectory: true),
                size: size,
                itemCount: 1 + children.reduce(0) { $0 + $1.itemCount },
                kind: .folder,
                children: children,
                isUnreadable: false
            )
        }

        return makeNode(path: normalizedRoot, name: rootName, isRoot: true)
    }

    private static func scanDirectoryBulk(
        descriptor: Int32,
        path: String,
        name: String,
        isRoot: Bool,
        buffer: inout [UInt8],
        totals: inout Totals,
        report: (ScanProgress) -> Void
    ) throws -> DiskNode {
        if Task.isCancelled { throw ScanError.cancelled }

        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = ATTR_CMN_RETURNED_ATTRS
            | UInt32(ATTR_CMN_NAME)
            | UInt32(ATTR_CMN_ERROR)
            | UInt32(ATTR_CMN_OBJTYPE)
        attributes.dirattr = UInt32(ATTR_DIR_MOUNTSTATUS)
        attributes.fileattr = UInt32(ATTR_FILE_ALLOCSIZE)

        var accumulator = DirectoryAccumulator(path: path, name: name, limit: isRoot ? 64 : 24)

        while true {
            if Task.isCancelled { throw ScanError.cancelled }
            let count = buffer.withUnsafeMutableBytes { bytes in
                getattrlistbulk(
                    descriptor,
                    &attributes,
                    bytes.baseAddress,
                    bytes.count,
                    UInt64(FSOPT_PACK_INVAL_ATTRS)
                )
            }

            if count == 0 { break }
            if count < 0 {
                if errno == ENOTSUP || errno == EINVAL || errno == ENOSYS || errno == ERANGE {
                    throw BulkScanError.unsupported
                }
                totals.inaccessible += 1
                return accumulator.finish(unreadable: true)
            }

            var pendingDirectories: [String] = []
            pendingDirectories.reserveCapacity(min(Int(count), 512))

            try buffer.withUnsafeBytes { bytes in
                guard let baseAddress = bytes.baseAddress else { return }
                var entryAddress = baseAddress

                for index in 0..<count {
                    if index & 255 == 0, Task.isCancelled { throw ScanError.cancelled }
                    let recordLength = Int(entryAddress.loadUnaligned(as: UInt32.self))
                    guard recordLength >= 40,
                          entryAddress + recordLength <= baseAddress + bytes.count else {
                        throw BulkScanError.unsupported
                    }

                    let recordEnd = entryAddress + recordLength
                    var field = entryAddress + MemoryLayout<UInt32>.size
                    let returned = readUnaligned(attribute_set_t.self, from: &field)
                    let entryError = returned.commonattr & UInt32(ATTR_CMN_ERROR) != 0
                        ? readUnaligned(UInt32.self, from: &field)
                        : 0
                    guard returned.commonattr & UInt32(ATTR_CMN_NAME) != 0 else {
                        entryAddress = recordEnd
                        continue
                    }
                    let nameReferenceAddress = field
                    let nameReference = readUnaligned(attrreference_t.self, from: &field)
                    let objectType = returned.commonattr & UInt32(ATTR_CMN_OBJTYPE) != 0
                        ? readUnaligned(UInt32.self, from: &field)
                        : 0
                    let mountStatus = returned.dirattr & UInt32(ATTR_DIR_MOUNTSTATUS) != 0
                        ? readUnaligned(UInt32.self, from: &field)
                        : 0
                    let allocated = returned.fileattr & UInt32(ATTR_FILE_ALLOCSIZE) != 0
                        ? max(0, readUnaligned(Int64.self, from: &field))
                        : 0
                    entryAddress = recordEnd

                    guard entryError == 0 else {
                        totals.inaccessible += 1
                        continue
                    }

                    if objectType == UInt32(VDIR.rawValue) {
                        guard mountStatus & UInt32(DIR_MNTSTATUS_MNTPOINT) == 0 else { continue }
                        guard let childName = decodeName(
                            referenceAddress: nameReferenceAddress,
                            reference: nameReference,
                            recordEnd: recordEnd
                        ) else { continue }
                        guard childName != ".", childName != ".." else { continue }
                        pendingDirectories.append(childName)
                        continue
                    }

                    totals.items += 1
                    totals.bytes += allocated
                    if accumulator.shouldRetain(size: allocated) {
                        guard let childName = decodeName(
                            referenceAddress: nameReferenceAddress,
                            reference: nameReference,
                            recordEnd: recordEnd
                        ) else { continue }
                        let childPath = joinedPath(parent: path, name: childName)
                        accumulator.addFile(path: childPath, name: childName, size: allocated)
                    } else {
                        accumulator.addOmitted(size: allocated)
                    }
                }
            }

            maybeReport(path: path, totals: &totals, report: report)

            // Recurse only after parsing the batch, because the shared buffer
            // will be overwritten by the child directory's bulk reads.
            for childName in pendingDirectories {
                if Task.isCancelled { throw ScanError.cancelled }
                let childPath = joinedPath(parent: path, name: childName)
                let childDescriptor = childName.withCString {
                    openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
                }
                guard childDescriptor >= 0 else {
                    totals.inaccessible += 1
                    var unreadable = DirectoryAccumulator(path: childPath, name: childName, limit: 24)
                    accumulator.addNode(unreadable.finish(unreadable: true))
                    continue
                }

                let childNode: DiskNode
                do {
                    childNode = try scanDirectoryBulk(
                        descriptor: childDescriptor,
                        path: childPath,
                        name: childName,
                        isRoot: false,
                        buffer: &buffer,
                        totals: &totals,
                        report: report
                    )
                    close(childDescriptor)
                } catch {
                    close(childDescriptor)
                    throw error
                }
                accumulator.addNode(childNode)
            }
        }

        return accumulator.finish()
    }

    private static func readUnaligned<T>(
        _ type: T.Type,
        from pointer: inout UnsafeRawPointer
    ) -> T {
        let value = pointer.loadUnaligned(as: T.self)
        pointer += MemoryLayout<T>.size
        return value
    }

    private static func decodeName(
        referenceAddress: UnsafeRawPointer,
        reference: attrreference_t,
        recordEnd: UnsafeRawPointer
    ) -> String? {
        let offset = Int(reference.attr_dataoffset)
        let storedLength = Int(reference.attr_length)
        guard offset >= 0, storedLength > 0 else { return nil }
        let start = referenceAddress + offset
        guard start >= referenceAddress, start + storedLength <= recordEnd else { return nil }
        return String(
            decoding: UnsafeRawBufferPointer(start: start, count: storedLength - 1),
            as: UTF8.self
        )
    }

    private static func joinedPath(parent: String, name: String) -> String {
        parent == "/" ? "/" + name : parent + "/" + name
    }

    /// `fts` performs the hierarchy walk and stat collection in libc. It is
    /// substantially cheaper than recursively asking Foundation for a fresh
    /// URLResourceValues object for every file.
    private static func walkNative(
        _ rootURL: URL,
        totals: inout Totals,
        report: (ScanProgress) -> Void
    ) throws -> DiskNode {
        guard let rootPath = strdup(rootURL.path) else { throw ScanError.cannotRead(rootURL) }
        defer { free(rootPath) }

        var paths: [UnsafeMutablePointer<CChar>?] = [rootPath, nil]
        let stream = paths.withUnsafeMutableBufferPointer { buffer in
            fts_open(buffer.baseAddress, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nil)
        }
        guard let stream else { throw ScanError.cannotRead(rootURL) }
        defer { fts_close(stream) }

        var directories: [DirectoryAccumulator] = []
        directories.reserveCapacity(32)
        let nestedMounts = nestedMountPaths(under: rootURL.path)
        var skippedDirectories = Set<String>()
        var seenHardLinks = Set<FileIdentity>()
        var rootNode: DiskNode?

        while let pointer = fts_read(stream) {
            if Task.isCancelled { throw ScanError.cancelled }

            let entry = pointer.pointee
            switch Int32(entry.fts_info) {
            case FTS_D:
                let path = String(cString: entry.fts_path)
                if entry.fts_level > 0, nestedMounts.contains(path) {
                    // macOS exposes the APFS Data volume both through firmlinks
                    // (/Users, /Applications, …) and at /System/Volumes/Data.
                    // It also mounts simulator runtimes and external disks below
                    // the startup volume. Pruning mount points prevents duplicate
                    // accounting and avoids scanning unrelated volumes.
                    _ = fts_set(stream, pointer, FTS_SKIP)
                    skippedDirectories.insert(path)
                    continue
                }
                let entryName = entryName(pointer)
                let isRoot = entry.fts_level == 0
                directories.append(DirectoryAccumulator(
                    path: path,
                    name: isRoot ? rootURL.lastPathComponent.ifEmpty("Macintosh HD") : entryName,
                    limit: isRoot ? 64 : 24
                ))

            case FTS_DP:
                let path = String(cString: entry.fts_path)
                if skippedDirectories.remove(path) != nil { continue }
                guard var directory = directories.popLast() else { continue }
                let node = directory.finish()
                if directories.isEmpty {
                    rootNode = node
                } else {
                    directories[directories.count - 1].addNode(node)
                }
                maybeReport(path: directory.path, totals: &totals, report: report)

            case FTS_DNR:
                totals.inaccessible += 1
                if var directory = directories.popLast() {
                    let node = directory.finish(unreadable: true)
                    if directories.isEmpty { rootNode = node }
                    else { directories[directories.count - 1].addNode(node) }
                }

            case FTS_F, FTS_DEFAULT:
                let allocated = allocatedSize(entry.fts_statp, seenHardLinks: &seenHardLinks)
                totals.items += 1
                totals.bytes += allocated

                if directories.isEmpty {
                    let path = String(cString: entry.fts_path)
                    rootNode = DiskNode(
                        id: path, name: entryName(pointer), url: URL(fileURLWithPath: path),
                        size: allocated, itemCount: 1, kind: .file,
                        children: [], isUnreadable: false
                    )
                } else if directories[directories.count - 1].shouldRetain(size: allocated) {
                    let path = String(cString: entry.fts_path)
                    directories[directories.count - 1].addFile(
                        path: path, name: entryName(pointer), size: allocated
                    )
                } else {
                    directories[directories.count - 1].addOmitted(size: allocated)
                }
                maybeReport(entry: pointer, totals: &totals, report: report)

            case FTS_SL, FTS_SLNONE:
                totals.items += 1
                if directories.isEmpty {
                    let path = String(cString: entry.fts_path)
                    rootNode = DiskNode(
                        id: path, name: entryName(pointer), url: URL(fileURLWithPath: path),
                        size: 0, itemCount: 1, kind: .file,
                        children: [], isUnreadable: false
                    )
                } else if directories[directories.count - 1].shouldRetain(size: 0) {
                    let path = String(cString: entry.fts_path)
                    directories[directories.count - 1].addFile(
                        path: path, name: entryName(pointer), size: 0
                    )
                } else {
                    directories[directories.count - 1].addOmitted(size: 0)
                }
                maybeReport(entry: pointer, totals: &totals, report: report)

            case FTS_ERR, FTS_NS, FTS_DC:
                let path = String(cString: entry.fts_path)
                let name = entryName(pointer)
                totals.inaccessible += 1
                if directories.last?.path == path, var directory = directories.popLast() {
                    let node = directory.finish(unreadable: true)
                    if directories.isEmpty { rootNode = node }
                    else { directories[directories.count - 1].addNode(node) }
                } else if directories.isEmpty {
                    rootNode = DiskNode(
                        id: path, name: name, url: URL(fileURLWithPath: path),
                        size: 0, itemCount: 1, kind: .file,
                        children: [], isUnreadable: true
                    )
                } else {
                    directories[directories.count - 1].addFile(
                        path: path, name: name, size: 0, unreadable: true
                    )
                }

            default:
                continue
            }
        }

        if Task.isCancelled { throw ScanError.cancelled }
        guard let rootNode else { throw ScanError.cannotRead(rootURL) }
        return rootNode
    }

    private static func allocatedSize(
        _ statPointer: UnsafeMutablePointer<stat>?,
        seenHardLinks: inout Set<FileIdentity>
    ) -> Int64 {
        guard let fileStat = statPointer?.pointee else { return 0 }
        if fileStat.st_nlink > 1 {
            let identity = FileIdentity(
                device: UInt64(fileStat.st_dev),
                inode: UInt64(fileStat.st_ino)
            )
            guard seenHardLinks.insert(identity).inserted else { return 0 }
        }
        let allocated = Int64(fileStat.st_blocks) * 512
        return allocated > 0 ? allocated : max(0, Int64(fileStat.st_size))
    }

    private static func nestedMountPaths(under rootPath: String) -> Set<String> {
        var mounts: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&mounts, MNT_NOWAIT)
        guard count > 0, let mounts else { return [] }

        let normalizedRoot = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        let prefix = normalizedRoot == "/" ? "/" : normalizedRoot + "/"
        var result = Set<String>()
        result.reserveCapacity(Int(count))

        // The writable APFS Data volume is also exposed through root firmlinks.
        // Keep this explicit fallback even if mount enumeration is restricted.
        if normalizedRoot == "/" {
            result.insert("/System/Volumes/Data")
        }

        for index in 0..<Int(count) {
            let mountPath = withUnsafePointer(to: &mounts[index].f_mntonname) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MNAMELEN)) {
                    String(cString: $0)
                }
            }
            let normalizedMount = URL(fileURLWithPath: mountPath).standardizedFileURL.path
            guard normalizedMount != normalizedRoot,
                  normalizedMount.hasPrefix(prefix) else { continue }
            result.insert(normalizedMount)
        }
        return result
    }

    private static func entryName(_ entry: UnsafeMutablePointer<FTSENT>) -> String {
        let count = Int(entry.pointee.fts_namelen)
        return withUnsafePointer(to: &entry.pointee.fts_name) { pointer in
            pointer.withMemoryRebound(to: UInt8.self, capacity: count) { bytes in
                String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
            }
        }
    }

    private static func maybeReport(
        path: String,
        totals: inout Totals,
        report: (ScanProgress) -> Void
    ) {
        let now = ContinuousClock.now
        if now - totals.lastReport > .milliseconds(75) {
            totals.lastReport = now
            report(ScanProgress(
                path: path,
                items: totals.items,
                bytes: totals.bytes,
                inaccessibleItems: totals.inaccessible
            ))
        }
    }

    private static func maybeReport(
        entry: UnsafeMutablePointer<FTSENT>,
        totals: inout Totals,
        report: (ScanProgress) -> Void
    ) {
        let now = ContinuousClock.now
        if now - totals.lastReport > .milliseconds(75) {
            totals.lastReport = now
            report(ScanProgress(
                path: String(cString: entry.pointee.fts_path),
                items: totals.items,
                bytes: totals.bytes,
                inaccessibleItems: totals.inaccessible
            ))
        }
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
