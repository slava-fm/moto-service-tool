import SwiftUI
import AppKit
import DucatiResetKit

@main
struct DucatiResetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var vm = ResetViewModel()

    var body: some Scene {
        WindowGroup("Moto Service Tool") {
            ContentView(vm: vm)
                .frame(minWidth: 760, minHeight: 560)
        }
        .windowResizability(.contentSize)
    }
}

/// Makes the SwiftPM executable behave as a normal foreground app.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}
