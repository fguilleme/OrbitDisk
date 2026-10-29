import SwiftUI
import AppKit

final class OrbitDiskAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
    }
}

@main
struct OrbitDiskApp: App {
    @NSApplicationDelegateAdaptor(OrbitDiskAppDelegate.self) private var appDelegate
    @StateObject private var model = ScanViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(
                    width: model.state == .ready ? 1_000 : 900,
                    height: model.state == .ready ? 690 : 340
                )
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 900, height: 340)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Analyser un dossier…") { model.chooseFolder() }
                    .keyboardShortcut("o")
                Button("Analyser le dossier personnel") {
                    model.startScan(FileManager.default.homeDirectoryForCurrentUser)
                }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            }
        }
    }
}
