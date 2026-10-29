# OrbitDisk

OrbitDisk is a native macOS disk space analyzer with an interactive sunburst map. It helps you identify large folders, navigate through storage usage, reveal files in Finder, and collect items that you may want to remove.

The application is independently implemented in Swift and SwiftUI. Its visual navigation is inspired by disk visualization tools such as DaisyDisk, while using its own interface, name, and assets.

## Features

- Scan an entire mounted volume or a selected folder
- Fast, cancellable filesystem traversal
- Live scan progress with item and byte counts
- Interactive multi-level sunburst visualization
- Navigate backward, forward, or directly to the scan root
- Inspect file and folder sizes
- Reveal items in Finder
- Collect items before moving them to the Trash
- Detect Time Machine volumes
- Account for APFS hidden and shared space
- Avoid symbolic-link loops and duplicate mounted volumes
- Handle inaccessible folders without aborting the complete scan

## Requirements

- macOS 14 or later
- Xcode with Swift 6.2 support

## Open in Xcode

`OrbitDisk.xcodeproj` is the primary project.

1. Open `OrbitDisk.xcodeproj` in Xcode.
2. Select the **OrbitDisk** scheme.
3. Press **Run** to launch the app or **Test** to run the test suite.

You can also open the project from Terminal:

```bash
open OrbitDisk.xcodeproj
```

## Run from Terminal

The repository also includes a Swift Package manifest for quick local builds:

```bash
swift run OrbitDisk
```

OrbitDisk activates itself in the foreground when launched from Terminal.

## Build the macOS Application

Use the packaging script to create a standalone application bundle:

```bash
./Scripts/package_app.sh release
open dist/OrbitDisk.app
```

The resulting bundle is written to `dist/OrbitDisk.app`.

## Run the Tests

Using Swift Package Manager:

```bash
swift test
```

Using Xcode:

```bash
xcodebuild \
  -project OrbitDisk.xcodeproj \
  -scheme OrbitDisk \
  -destination 'platform=macOS' \
  test
```

## Permissions and APFS

macOS may prevent OrbitDisk from reading protected folders. Grant **Full Disk Access** in **System Settings → Privacy & Security → Full Disk Access** if you want the most complete scan possible.

APFS uses clones, snapshots, purgeable storage, and shared blocks. As a result, the sum of individually scanned files may differ from the physical space reported by macOS. OrbitDisk reconciles the final visualization with the volume's physical usage and represents the difference as hidden space.

Symbolic links are not followed. Mounted volumes and synthetic macOS root entries are excluded from a startup-disk scan to prevent loops, double counting, and accidental scans of unrelated disks.

## Project Structure

```text
OrbitDisk.xcodeproj       Xcode project and shared scheme
Package.swift             Swift Package Manager manifest
Sources/OrbitDisk         Application source code
Tests/OrbitDiskTests      Unit tests
Packaging/Info.plist      Application bundle metadata
Scripts/package_app.sh    Release packaging script
```

## Safety

OrbitDisk never deletes an item immediately. Items selected for cleanup are moved to the macOS Trash, where they can still be restored until the Trash is emptied.
