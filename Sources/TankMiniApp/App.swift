import AppKit
import SwiftUI
import TankMiniCore

// Launch options:
//   --demo                 run with built-in sample data instead of a pedal
//   --snapshot <file.png>  render the window to an image and quit (used for checking the layout)
//   --tuner                with --snapshot: render the tuner instead of the main window
//   --light / --dark       with --snapshot: force an appearance
let launchArguments = CommandLine.arguments
let demoMode = launchArguments.contains("--demo")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = PedalStore(demo: demoMode)
    let audio = AudioSetup(demo: demoMode)
    private var snapshotWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if let i = launchArguments.firstIndex(of: "--snapshot"), launchArguments.count > i + 1 {
            snapshot(to: launchArguments[i + 1])
            return
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func snapshot(to path: String) {
        for window in NSApp.windows { window.orderOut(nil) }
        let tunerShot = launchArguments.contains("--tuner")
        if tunerShot { store.setTuner(true) }
        let size = tunerShot ? NSSize(width: 400, height: 330) : NSSize(width: 1100, height: 700)
        let root: AnyView = tunerShot
            ? AnyView(TunerView().environmentObject(store).environmentObject(audio))
            : AnyView(ContentView().environmentObject(store).environmentObject(audio))
        let controller = NSHostingController(rootView: root)
        controller.sceneBridgingOptions = [.all] // carry the SwiftUI toolbar and title into the window
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: tunerShot ? [.titled] : [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        if launchArguments.contains("--light") { window.appearance = NSAppearance(named: .aqua) }
        if launchArguments.contains("--dark") { window.appearance = NSAppearance(named: .darkAqua) }
        window.contentViewController = controller
        window.toolbarStyle = .unified
        window.setContentSize(size)
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        snapshotWindow = window
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            guard let frameView = window.contentView?.superview,
                  let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { exit(1) }
            frameView.cacheDisplay(in: frameView.bounds, to: rep)
            let ok = (try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))) != nil
            exit(ok ? 0 : 1)
        }
    }
}

@main
struct TankMiniApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Tank Mini", id: "main") {
            ContentView()
                .environmentObject(delegate.store)
                .environmentObject(delegate.audio)
                .frame(minWidth: 940, minHeight: 600)
        }
        .defaultSize(width: 1100, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Pedal") {
                Button("Tuner") { delegate.store.setTuner(!delegate.store.tunerOn) }
                    .keyboardShortcut("t", modifiers: .command)
                Button("Bypass") { delegate.store.setBypass(!delegate.store.bypassed) }
                    .keyboardShortcut("b", modifiers: .command)
                Divider()
                Button("Previous Preset") { delegate.store.select(max(0, delegate.store.activeSlot - 1)) }
                    .keyboardShortcut("[", modifiers: .command)
                Button("Next Preset") { delegate.store.select(min(Bank.slots - 1, delegate.store.activeSlot + 1)) }
                    .keyboardShortcut("]", modifiers: .command)
                Divider()
                Button("Reload From Pedal") { delegate.store.reload() }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}
