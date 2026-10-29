import XCTest
@testable import OrbitDisk

final class OrbitDiskTests: XCTestCase {
    func testByteTextProducesReadableValue() {
        let result = ByteText.string(1_073_741_824)
        XCTAssertTrue(result.contains("GB") || result.contains("Go"))
    }

    func testNodeLookupFindsNestedChild() {
        let leaf = DiskNode(id: "/tmp/root/a.txt", name: "a.txt", url: nil, size: 42, itemCount: 1, kind: .file, children: [], isUnreadable: false)
        let root = DiskNode(id: "/tmp/root", name: "root", url: nil, size: 42, itemCount: 2, kind: .folder, children: [leaf], isUnreadable: false)
        XCTAssertEqual(root.node(atPath: leaf.id)?.size, 42)
    }

    func testReconciliationAddsHiddenPhysicalSpace() {
        let visible = DiskNode(id: "/visible", name: "visible", url: nil, size: 60, itemCount: 1, kind: .folder, children: [], isUnreadable: false)
        let root = DiskNode(id: "/", name: "Macintosh HD", url: URL(fileURLWithPath: "/"), size: 60, itemCount: 2, kind: .folder, children: [visible], isUnreadable: false)

        let reconciled = root.reconciled(to: 100)

        XCTAssertEqual(reconciled.size, 100)
        XCTAssertEqual(reconciled.children.last?.name, "hidden space…")
        XCTAssertEqual(reconciled.children.last?.size, 40)
    }

    func testReconciliationCapsSharedAPFSBlocks() {
        let child = DiskNode(id: "/clone", name: "clone", url: nil, size: 200, itemCount: 1, kind: .file, children: [], isUnreadable: false)
        let root = DiskNode(id: "/", name: "Macintosh HD", url: URL(fileURLWithPath: "/"), size: 200, itemCount: 2, kind: .folder, children: [child], isUnreadable: false)

        let reconciled = root.reconciled(to: 125)

        XCTAssertEqual(reconciled.size, 125)
        XCTAssertEqual(reconciled.children.first?.size, 125)
    }

    func testScanProgressFractionIsBoundedUntilCompletion() {
        let halfway = ScanProgress(path: "/tmp", items: 10, bytes: 500, inaccessibleItems: 0)
        XCTAssertEqual(halfway.fraction(of: 1_000), 0.5, accuracy: 0.001)

        let beyondEstimate = ScanProgress(path: "/tmp", items: 20, bytes: 1_200, inaccessibleItems: 0)
        XCTAssertEqual(beyondEstimate.fraction(of: 1_000), 0.99, accuracy: 0.001)

        let explicitCompletion = ScanProgress(
            path: "/tmp",
            items: 20,
            bytes: 500,
            inaccessibleItems: 0,
            estimatedFraction: 1
        )
        XCTAssertEqual(explicitCompletion.fraction(of: 1_000), 1, accuracy: 0.001)
    }

    func testNativeScannerBuildsDirectoryTree() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitDiskTree-\(UUID().uuidString)", isDirectory: true)
        let nested = directory.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let rootFile = directory.appendingPathComponent("root.bin")
        let nestedFile = nested.appendingPathComponent("nested.bin")
        try Data(repeating: 1, count: 8_192).write(to: rootFile)
        try Data(repeating: 2, count: 4_096).write(to: nestedFile)

        let result = try await DiskScanner().scan(directory) { _ in }

        XCTAssertGreaterThanOrEqual(result.itemCount, 4)
        XCTAssertGreaterThanOrEqual(result.size, 12_288)
        XCTAssertNotNil(result.node(atPath: nestedFile.path))
    }

    func testScannerStopsWhenCancelled() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitDiskCancellation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for index in 0..<2_000 {
            FileManager.default.createFile(
                atPath: directory.appendingPathComponent("item-\(index)").path,
                contents: Data([0])
            )
        }

        let scanner = DiskScanner()
        let scan = Task {
            try await scanner.scan(directory) { _ in }
        }
        try? await Task.sleep(for: .milliseconds(2))
        scan.cancel()

        do {
            _ = try await scan.value
            XCTFail("L’analyse aurait dû être annulée")
        } catch ScanError.cancelled {
            // Expected.
        } catch is CancellationError {
            // Also acceptable when cancellation is observed by the parent task.
        }
    }
}
