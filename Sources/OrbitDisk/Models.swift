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

    func node(atPath path: String) -> DiskNode? {
        if id == path { return self }
        for child in children where path.hasPrefix(child.id) || child.id == path {
            if let match = child.node(atPath: path) { return match }
        }
        return nil
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
        bytes.formatted(.byteCount(style: .file))
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
