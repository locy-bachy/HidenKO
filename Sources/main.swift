import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let engine = Engine()
    private var statusItem: NSStatusItem!
    private let toggleItem = NSMenuItem(title: "Прозрачная строка меню", action: #selector(toggle), keyEquivalent: "")
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "menubar.rectangle", accessibilityDescription: "HidenKO")

        let menu = NSMenu()
        toggleItem.target = self
        menu.addItem(toggleItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Вернуть обои и выйти", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu

        NotificationCenter.default.addObserver(self, selector: #selector(topologyChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let wnc = NSWorkspace.shared.notificationCenter
        wnc.addObserver(self, selector: #selector(refreshSoon), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            wnc.addObserver(self, selector: #selector(topologyChanged), name: name, object: nil)
        }
        wnc.addObserver(self, selector: #selector(displaysSleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        wnc.addObserver(self, selector: #selector(displaysWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(appearanceChanged),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"), object: nil)

        // Make sure the user's wallpaper comes back when the process is killed politely.
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in self?.engine.disable(); exit(0) }
            src.resume()
            signalSources.append(src)
        }

        // Test hook: `kill -USR1 <pid>` behaves like a display having just been (dis)connected.
        signal(SIGUSR1, SIG_IGN)
        let usr1 = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        usr1.setEventHandler { [weak self] in self?.topologyChanged() }
        usr1.resume()
        signalSources.append(usr1)

        engine.enable()
        toggleItem.state = .on
    }

    func applicationWillTerminate(_ notification: Notification) { engine.disable() }

    @objc private func toggle() {
        if engine.isEnabled { engine.disable() } else { engine.enable() }
        toggleItem.state = engine.isEnabled ? .on : .off
    }

    @objc private func refreshSoon() { engine.scheduleRefresh() }
    @objc private func topologyChanged() {
        engine.noteTopologyChange()
        engine.scheduleRefresh(after: 1)
    }
    @objc private func appearanceChanged() { engine.scheduleRefresh(force: true) }
    @objc private func displaysSleep() { engine.displaysDidSleep() }
    @objc private func displaysWake() { engine.displaysDidWake() }
    @objc private func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
