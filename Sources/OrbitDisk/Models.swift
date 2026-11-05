import Foundation
import SwiftUI

struct DiskNode: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case folder, file, aggregate
    }

    let id: String
    let name: String
    let url: URL?
    let size: Int64
    let itemCount: Int
    let kind: Kind
    let children: [DiskNode]
    let isUnreadable: Bool

    var isDirectory: Bool { kind == .folder }
    var isSmallerObjects: Bool { id.hasSuffix("/.orbit-other") }

    func node(atPath path: String) -> DiskNode? {
        if id == path { return self }
        for child in children where path.hasPrefix(child.id) || child.id == path {
            if let match = child.node(atPath: path) { return match }
        }
        return nil
    }

    func path(to targetID: String) -> [DiskNode]? {
        if id == targetID { return [self] }
        for child in children {
            if let suffix = child.path(to: targetID) {
                return [self] + suffix
            }
        }
        return nil
    }

    func removingNodes(atOrBelow removedPaths: Set<String>) -> DiskNode? {
        let isRemoved = removedPaths.contains { removedPath in
            id == removedPath || id.hasPrefix(removedPath + "/")
        }
        if isRemoved { return nil }

        let updatedChildren = children.compactMap {
            $0.removingNodes(atOrBelow: removedPaths)
        }
        guard updatedChildren.count != children.count
                || zip(updatedChildren, children).contains(where: {
                    $0.id != $1.id || $0.size != $1.size || $0.itemCount != $1.itemCount
                }) else {
            return self
        }

        let previousChildSize = children.reduce(Int64(0)) { $0 + $1.size }
        let updatedChildSize = updatedChildren.reduce(Int64(0)) { $0 + $1.size }
        let previousChildItems = children.reduce(0) { $0 + $1.itemCount }
        let updatedChildItems = updatedChildren.reduce(0) { $0 + $1.itemCount }
        return DiskNode(
            id: id,
            name: name,
            url: url,
            size: max(0, size - (previousChildSize - updatedChildSize)),
            itemCount: max(1, itemCount - (previousChildItems - updatedChildItems)),
            kind: kind,
            children: updatedChildren,
            isUnreadable: isUnreadable
        )
    }

    /// Keeps meaningful branches visible and combines objects too small to
    /// produce a useful chart segment. Existing scanner overflow is folded
    /// into the same aggregate, so its size remains exactly conserved.
    static func consolidatingSmallChildren(
        _ children: [DiskNode],
        parentID: String,
        parentSize: Int64,
        minimumVisible: Int = 3,
        minimumFraction: Double = 0.0001
    ) -> [DiskNode] {
        let sorted = children
            .filter { !$0.isSmallerObjects }
            .sorted {
                if $0.size != $1.size { return $0.size > $1.size }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        let threshold = max(1, Int64(Double(max(parentSize, 0)) * minimumFraction))
        var visible: [DiskNode] = []
        var smallerSize: Int64 = 0
        var smallerItems = 0

        for (index, child) in sorted.enumerated() {
            if index < minimumVisible || child.size >= threshold {
                visible.append(child)
            } else {
                smallerSize += child.size
                smallerItems += child.itemCount
            }
        }

        for aggregate in children where aggregate.isSmallerObjects {
            smallerSize += aggregate.size
            smallerItems += aggregate.itemCount
        }

        if smallerItems > 0 {
            visible.append(DiskNode(
                id: parentID + "/.orbit-other",
                name: "smaller objects…",
                url: nil,
                size: smallerSize,
                itemCount: smallerItems,
                kind: .aggregate,
                children: [],
                isUnreadable: false
            ))
        }
        return visible
    }

    /// Reconciles a scanned hierarchy with the physical usage reported by the
    /// filesystem. APFS can hide protected space and share blocks between
    /// clones, so summing per-file allocation is not always equal to volume use.
    func reconciled(to physicalSize: Int64) -> DiskNode {
        guard isDirectory, physicalSize > 0, size != physicalSize else { return self }

        if size < physicalSize {
            let hiddenSize = physicalSize - size
            let hidden = DiskNode(
                id: id + "/.orbit-hidden-space",
                name: "hidden space…",
                url: nil,
                size: hiddenSize,
                itemCount: 0,
                kind: .aggregate,
                children: [],
                isUnreadable: false
            )
            return DiskNode(
                id: id,
                name: name,
                url: url,
                size: physicalSize,
                itemCount: itemCount,
                kind: kind,
                children: children + [hidden],
                isUnreadable: isUnreadable
            )
        }

        let scale = Double(physicalSize) / Double(size)
        return scaled(by: scale, forcedSize: physicalSize)
    }

    private func scaled(by scale: Double, forcedSize: Int64? = nil) -> DiskNode {
        DiskNode(
            id: id,
            name: name,
            url: url,
            size: forcedSize ?? max(0, Int64((Double(size) * scale).rounded())),
            itemCount: itemCount,
            kind: kind,
            children: children.map { $0.scaled(by: scale) },
            isUnreadable: isUnreadable
        )
    }
}

struct ScanProgress: Sendable {
    let path: String
    let items: Int
    let bytes: Int64
    let inaccessibleItems: Int
    let estimatedFraction: Double?

    init(
        path: String,
        items: Int,
        bytes: Int64,
        inaccessibleItems: Int,
        estimatedFraction: Double? = nil
    ) {
        self.path = path
        self.items = items
        self.bytes = bytes
        self.inaccessibleItems = inaccessibleItems
        self.estimatedFraction = estimatedFraction
    }

    func fraction(of expectedBytes: Int64) -> Double {
        if let estimatedFraction {
            return min(1, max(0, estimatedFraction))
        }
        guard expectedBytes > 0 else { return 0 }
        return min(0.99, max(0, Double(bytes) / Double(expectedBytes)))
    }
}

struct VolumeInfo: Identifiable, Sendable {
    let id: String
    let url: URL
    let name: String
    let total: Int64
    let available: Int64
    let availableIncludingPurgeable: Int64
    let isInternal: Bool
    let isTimeMachine: Bool

    var used: Int64 { max(0, total - available) }
    var purgeable: Int64 { max(0, availableIncludingPurgeable - available) }
    var fractionUsed: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(used) / Double(total)))
    }
}

enum ByteText {
    static func string(_ bytes: Int64) -> String {
        let value = Double(max(0, bytes))
        let units = ["bytes", "KB", "MB", "GB", "TB", "PB"]
        var unitIndex = 0
        var scaled = value
        while scaled >= 1_000, unitIndex < units.count - 1 {
            scaled /= 1_000
            unitIndex += 1
        }

        if unitIndex == 0 { return "\(Int64(scaled)) bytes" }
        let rounded = (scaled * 10).rounded() / 10
        let fractionDigits = rounded == rounded.rounded() ? 0 : 1
        let number = rounded.formatted(
            .number.precision(.fractionLength(fractionDigits))
        )
        return "\(number) \(units[unitIndex])"
    }
}

enum OrbitPalette {
    static let colors: [Color] = [
        Color(red: 0.35, green: 0.84, blue: 0.95),
        Color(red: 0.38, green: 0.64, blue: 1.00),
        Color(red: 0.61, green: 0.46, blue: 0.98),
        Color(red: 0.92, green: 0.38, blue: 0.78),
        Color(red: 1.00, green: 0.45, blue: 0.42),
        Color(red: 1.00, green: 0.66, blue: 0.28),
        Color(red: 0.60, green: 0.86, blue: 0.38),
        Color(red: 0.22, green: 0.78, blue: 0.62)
    ]

    static func color(for id: String, depth: Int = 0) -> Color {
        var value = UInt64(5381)
        for byte in id.utf8 { value = ((value << 5) &+ value) &+ UInt64(byte) }
        let base = colors[Int(value % UInt64(colors.count))]
        return base.opacity(max(0.52, 1 - Double(depth) * 0.10))
    }
}
