import AppKit
import Foundation
import SwiftUI

@MainActor
final class ScanViewModel: ObservableObject {
    private struct TrashOutcome: Sendable {
        var movedPaths: [String] = []
        var failures: [String] = []

        var moved: Int { movedPaths.count }
    }

    enum State: Equatable {
        case idle
        case scanning
        case ready
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var root: DiskNode?
    @Published private(set) var navigation: [DiskNode] = []
    @Published var selected: DiskNode?
    @Published private(set) var progress = ScanProgress(path: "", items: 0, bytes: 0, inaccessibleItems: 0)
    @Published private(set) var volumes: [VolumeInfo] = []
    @Published private(set) var scanTargetURL: URL?
    @Published private(set) var collected: [DiskNode] = []
    @Published private(set) var collectorTrashSecondsRemaining: Int?
    @Published private(set) var isTrashingCollected = false
    @Published private(set) var collectorStatus: String?
    @Published private(set) var collectorStatusIsError = false
    @Published var notice: String?

    private let scanner = DiskScanner()
    private var scanTask: Task<Void, Never>?
    private var collectorTrashCountdownTask: Task<Void, Never>?
    private var forwardNavigation: [DiskNode] = []

    var focus: DiskNode? { navigation.last ?? root }
    var isScanning: Bool { state == .scanning }
    var canNavigateForward: Bool { !forwardNavigation.isEmpty }
    var collectedSize: Int64 { collected.reduce(0) { $0 + $1.size } }

    init() {
        refreshVolumes()
    }

    func refreshVolumes() {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey, .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
            .volumeIsInternalKey,
            .volumeIsBrowsableKey
        ]
        let timeMachineMountPaths = Self.timeMachineMountPaths()
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(keys),
            options: [.skipHiddenVolumes]
        ) ?? [URL(fileURLWithPath: "/")]

        volumes = urls.compactMap { url in
            guard let value = try? url.resourceValues(forKeys: keys),
                  value.volumeIsBrowsable != false else { return nil }
            let fileSystemAttributes = try? FileManager.default.attributesOfFileSystem(forPath: url.path)
            let fileSystemTotal = (fileSystemAttributes?[.systemSize] as? NSNumber)?.int64Value ?? 0
            let fileSystemAvailable = (fileSystemAttributes?[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
            let total = Int64(value.volumeTotalCapacity ?? 0) > 0
                ? Int64(value.volumeTotalCapacity ?? 0)
                : fileSystemTotal
            let regularAvailable = value.volumeAvailableCapacity.map(Int64.init)
                ?? fileSystemAvailable
            let importantAvailable = value.volumeAvailableCapacityForImportantUsage
                ?? regularAvailable
            let physicalAvailable = fileSystemAvailable > 0
                ? fileSystemAvailable
                : regularAvailable
            let name = value.volumeName ?? (url.path == "/" ? "Macintosh HD" : url.lastPathComponent)
            let isTimeMachine = timeMachineMountPaths.contains(url.standardizedFileURL.path)
                || name.localizedCaseInsensitiveContains("Time Machine")
                || name == "™"
            return VolumeInfo(
                id: url.path,
                url: url,
                name: name,
                total: total,
                available: physicalAvailable,
                availableIncludingPurgeable: max(
                    physicalAvailable,
                    max(regularAvailable, importantAvailable)
                ),
                isInternal: value.volumeIsInternal ?? false,
                isTimeMachine: isTimeMachine
            )
        }
    }

    private static func timeMachineMountPaths() -> Set<String> {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        process.arguments = ["destinationinfo"]
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            guard let text = String(data: data, encoding: .utf8) else { return [] }
            return Set(text.split(separator: "\n").compactMap { line in
                let fields = line.split(separator: ":", maxSplits: 1)
                guard fields.count == 2,
                      fields[0].trimmingCharacters(in: .whitespaces) == "Mount Point" else { return nil }
                return URL(fileURLWithPath: fields[1].trimmingCharacters(in: .whitespaces)).standardizedFileURL.path
            })
        } catch {
            return []
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choisir un dossier à analyser"
        panel.prompt = "Analyser"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            startScan(url)
        }
    }

    func startScan(_ url: URL) {
        scanTask?.cancel()
        cancelCollectorTrash()
        collectorStatus = nil
        root = nil
        navigation = []
        selected = nil
        collected = []
        scanTargetURL = url.standardizedFileURL
        forwardNavigation = []
        progress = ScanProgress(path: url.path, items: 0, bytes: 0, inaccessibleItems: 0)
        state = .scanning
        let expectedPhysicalSize = volumes.first {
            $0.url.standardizedFileURL.path == url.standardizedFileURL.path
        }?.used

        scanTask = Task { [weak self] in
            guard let self else { return }
            let targetPath = url.standardizedFileURL.path
            do {
                let scannedResult = try await scanner.scan(url) { update in
                    await MainActor.run { [weak self] in
                        guard let self,
                              self.state == .scanning,
                              self.scanTargetURL?.path == targetPath else { return }
                        self.progress = update
                    }
                }
                guard !Task.isCancelled else { return }
                let result = expectedPhysicalSize.map { scannedResult.reconciled(to: $0) }
                    ?? scannedResult
                // Let SwiftUI render the scanner's explicit 100% update before
                // replacing the volume list with the analysis view.
                try await Task.sleep(for: .milliseconds(140))
                guard !Task.isCancelled else { return }
                root = result
                selected = nil
                state = .ready
            } catch is CancellationError {
                state = .idle
            } catch {
                if case ScanError.cancelled = error { state = .idle }
                else { state = .failed(error.localizedDescription) }
            }
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        scanTargetURL = nil
        state = .idle
        progress = ScanProgress(path: "", items: 0, bytes: 0, inaccessibleItems: 0)
    }

    func navigate(to node: DiskNode) {
        guard node.isDirectory else { selected = node; return }
        guard node.id != focus?.id else { return }
        guard let fullPath = root?.path(to: node.id) else { return }
        navigation = Array(fullPath.dropFirst())
        forwardNavigation.removeAll()
        selected = nil
    }

    func navigateBack() {
        if navigation.isEmpty { return }
        forwardNavigation.append(navigation.removeLast())
        selected = nil
    }

    func navigateForward() {
        guard let node = forwardNavigation.popLast() else { return }
        navigation.append(node)
        selected = nil
    }

    func navigateHome() {
        navigation.removeAll()
        forwardNavigation.removeAll()
        selected = nil
    }

    func returnToVolumes() {
        scanTask?.cancel()
        cancelCollectorTrash()
        collectorStatus = nil
        root = nil
        navigation = []
        forwardNavigation = []
        selected = nil
        collected = []
        scanTargetURL = nil
        state = .idle
        refreshVolumes()
    }

    func toggleCollected(_ node: DiskNode) {
        guard node.url != nil, node.id != root?.id else { return }
        cancelCollectorTrash()
        collectorStatus = nil
        if let index = collected.firstIndex(where: { $0.id == node.id }) {
            collected.remove(at: index)
        } else {
            collected.append(node)
        }
    }

    func beginTrashCollector() {
        guard !collected.isEmpty else { return }
        cancelCollectorTrash()
        collectorStatus = nil
        let delay = 5
        collectorTrashSecondsRemaining = delay
        collectorTrashCountdownTask = Task { [weak self] in
            for remaining in stride(from: delay - 1, through: 0, by: -1) {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                if remaining == 0 {
                    collectorTrashSecondsRemaining = nil
                    collectorTrashCountdownTask = nil
                    await trashCollectedItems()
                } else {
                    collectorTrashSecondsRemaining = remaining
                }
            }
        }
    }

    func cancelCollectorTrash() {
        collectorTrashCountdownTask?.cancel()
        collectorTrashCountdownTask = nil
        collectorTrashSecondsRemaining = nil
    }

    private func trashCollectedItems() async {
        let targets = topLevelCollectedURLs()
        guard !targets.isEmpty else { return }
        isTrashingCollected = true

        let outcome = await Task.detached(priority: .userInitiated) {
            var outcome = TrashOutcome()
            for url in targets {
                do {
                    var resultingURL: NSURL?
                    try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
                    outcome.movedPaths.append(url.path)
                } catch {
                    outcome.failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            return outcome
        }.value

        isTrashingCollected = false
        if outcome.moved > 0 {
            let noun = outcome.moved == 1 ? "item" : "items"
            if outcome.failures.isEmpty {
                collectorStatus = "\(outcome.moved) \(noun) moved to the Trash"
                collectorStatusIsError = false
            } else {
                collectorStatus = "\(outcome.moved) moved; \(outcome.failures.count) could not be moved"
                collectorStatusIsError = true
            }
            updateTreeAfterTrash(movedPaths: Set(outcome.movedPaths))
        } else {
            collectorStatus = outcome.failures.isEmpty
                ? "Nothing was moved to the Trash"
                : "Could not move \(outcome.failures.count) item\(outcome.failures.count == 1 ? "" : "s") to the Trash"
            collectorStatusIsError = true
        }
    }

    private func updateTreeAfterTrash(movedPaths: Set<String>) {
        let previousFocusID = focus?.id
        if let currentRoot = root,
           let updatedRoot = currentRoot.removingNodes(atOrBelow: movedPaths) {
            root = updatedRoot
            if let previousFocusID,
               let updatedPath = updatedRoot.path(to: previousFocusID) {
                navigation = Array(updatedPath.dropFirst())
            } else {
                navigation = []
            }
            forwardNavigation = forwardNavigation.compactMap {
                updatedRoot.node(atPath: $0.id)
            }
        }
        selected = nil
        collected.removeAll { node in
            movedPaths.contains { movedPath in
                node.id == movedPath || node.id.hasPrefix(movedPath + "/")
            }
        }
    }

    private func topLevelCollectedURLs() -> [URL] {
        let urls = collected.compactMap(\.url).map(\.standardizedFileURL).sorted {
            $0.pathComponents.count < $1.pathComponents.count
        }
        var result: [URL] = []
        for url in urls {
            let path = url.path
            let alreadyCovered = result.contains { parent in
                path == parent.path || path.hasPrefix(parent.path + "/")
            }
            if !alreadyCovered { result.append(url) }
        }
        return result
    }

    func reveal(_ node: DiskNode) {
        guard let url = node.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func moveToTrash(_ node: DiskNode) {
        guard let url = node.url, node.id != root?.id, node.id != focus?.id else {
            notice = "Le dossier actuellement affiché ne peut pas être déplacé dans la corbeille."
            return
        }
        do {
            var resultingURL: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
            notice = "« \(node.name) » a été déplacé dans la corbeille."
            if let rootURL = root?.url { startScan(rootURL) }
        } catch {
            notice = "Suppression impossible : \(error.localizedDescription)"
        }
    }
}
