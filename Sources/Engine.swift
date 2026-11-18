import AppKit

/// Owns the per-screen state: original wallpaper, generated wallpaper, overlay window.
///
/// Displays are identified by their UUID, not by `CGDirectDisplayID`: the id changes when a
/// monitor is unplugged and plugged in again, the UUID does not. For every display a `Record`
/// ties together the user's original wallpaper and the generated file made from it. Records live
/// on disk, so a wallpaper can always be traced back to its original, whichever display the
/// system happens to show it on after a reconnect.
///
/// Power notes: nothing runs periodically except a 60 s safety timer with wide tolerance
/// (paused while the displays sleep). Everything else is event driven: screen changes, Space
/// changes, wake, light/dark switch, and a file-system watch on the system wallpaper store.
/// The heavy image work runs on a utility-QoS queue.
final class Engine {
    private struct ScreenState {
        var uuid: String
        var original: URL
        var originalOptions: [NSWorkspace.DesktopImageOptionKey: Any]
        var processed: ProcessedWallpaper
        var window: OverlayWindow?
    }

    /// What we must remember about one physical display. Persisted.
    private struct Record {
        var original: URL
        var scaling: UInt
        var clipping: Bool
        var generated: URL

        var options: [NSWorkspace.DesktopImageOptionKey: Any] {
            [.imageScaling: scaling, .allowClipping: clipping]
        }
    }

    private var states: [CGDirectDisplayID: ScreenState] = [:]
    private var records: [String: Record] = [:]          // display UUID → record
    private var inFlight = Set<CGDirectDisplayID>()
    private let worker = DispatchQueue(label: "hidenko.worker", qos: .utility)

    private var safetyTimer: Timer?
    private var storeWatcher: DispatchSourceFileSystemObject?
    private var pendingRefresh: DispatchWorkItem?
    private var displaysAsleep = false
    private var forceRebuild = false
    private var lastTopologyChange = Date.distantPast
    private(set) var isEnabled = false

    private let recordsKey = "records.v2"
    private let legacyKey = "originalWallpapers"          // v1: original paths by display id
    private let debug = ProcessInfo.processInfo.environment["HIDENKO_DEBUG"] != nil

    /// Right after displays are (dis)connected macOS may put a default wallpaper on a screen.
    /// For this long we put the user's own one back instead of treating it as a new choice.
    private let settleWindow: TimeInterval = 10

    private static let fillOptions: [NSWorkspace.DesktopImageOptionKey: Any] = [
        .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
        .allowClipping: true,
    ]

    // MARK: - Public

    func enable() {
        guard !isEnabled else { return }
        isEnabled = true
        loadRecords()
        startWatching()
        refresh()
    }

    func disable() {
        stopWatching()
        pendingRefresh?.cancel()
        forceRebuild = false
        guard isEnabled else { return }
        isEnabled = false

        // Put the original back on every connected screen, whoever it belongs to now.
        var restored = Set<String>()
        for screen in NSScreen.screens {
            let id = WallpaperProcessor.displayID(of: screen)
            let uuid = WallpaperProcessor.displayUUID(of: screen)
            let current = NSWorkspace.shared.desktopImageURL(for: screen)

            let source: (url: URL, options: [NSWorkspace.DesktopImageOptionKey: Any])?
            if let st = states[id], st.uuid == uuid {
                source = (st.original, st.originalOptions)
            } else if let r = records[uuid] {
                source = (r.original, r.options)
            } else if let c = current, let r = records.values.first(where: { $0.generated == c }) {
                source = (r.original, r.options)
            } else {
                source = nil
            }
            guard let source else {
                if let c = current, WallpaperProcessor.isGenerated(c) {
                    NSLog("HidenKO: display %u still shows a generated file and its original is unknown", id)
                }
                continue
            }
            // Retry with plain "fill" options if the saved ones are rejected.
            var ok = false
            for options in [source.options, Self.fillOptions] where !ok {
                do {
                    try NSWorkspace.shared.setDesktopImageURL(source.url, for: screen, options: options)
                    ok = true
                } catch {
                    NSLog("HidenKO: restore failed for display %u: %@", id, error.localizedDescription)
                }
            }
            // The call can succeed without the system applying it. Only a restore we can see counts;
            // otherwise the record and the generated file stay, and nothing is lost.
            if ok {
                let target = source.url.resolvingSymlinksInPath()
                var applied = false
                for _ in 0..<10 where !applied {
                    applied = NSWorkspace.shared.desktopImageURL(for: screen)?.resolvingSymlinksInPath() == target
                    if !applied { Thread.sleep(forTimeInterval: 0.1) }
                }
                if applied { restored.insert(uuid) } else { NSLog("HidenKO: restore of display %u did not take effect", id) }
            }
        }
        for state in states.values { state.window?.orderOut(nil); state.window?.close() }
        states.removeAll()

        // Records of displays that are not connected right now stay: their wallpaper is still a
        // generated file, and the next launch fixes it when they come back.
        for uuid in restored { records[uuid] = nil }
        saveRecords()
        collectGarbage()
    }

    /// Displays were connected, disconnected, rearranged or woke up.
    /// Overlays go back over their own menu bars right away (cheap); the full refresh follows later.
    func noteTopologyChange() {
        lastTopologyChange = Date()
        for state in states.values { state.window?.reposition() }
    }

    /// Coalesce bursts of notifications into a single refresh.
    func scheduleRefresh(after delay: TimeInterval = 0.5, force: Bool = false) {
        pendingRefresh?.cancel()
        // A forced request (light/dark switch) must survive being coalesced with a plain one.
        if force { forceRebuild = true }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.refresh()
            self.forceRebuild = false
        }
        pendingRefresh = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func displaysDidSleep() {
        displaysAsleep = true
        safetyTimer?.invalidate(); safetyTimer = nil
        for state in states.values { state.window?.orderOut(nil) }
    }

    func displaysDidWake() {
        displaysAsleep = false
        guard isEnabled else { return }
        startSafetyTimer()
        scheduleRefresh(after: 1)
    }

    /// Re-sync with the current screens, menu bar height and wallpaper.
    func refresh() {
        guard isEnabled, !displaysAsleep else { return }
        let screens = NSScreen.screens
        let liveIDs = Set(screens.map(WallpaperProcessor.displayID))
        let menuBarWindows = WallpaperProcessor.menuBarWindows()

        for id in states.keys where !liveIDs.contains(id) {
            states[id]?.window?.orderOut(nil)
            states[id]?.window?.close()
            states[id] = nil
        }

        for screen in screens {
            let id = WallpaperProcessor.displayID(of: screen)
            let uuid = WallpaperProcessor.displayUUID(of: screen)

            // The same id can come back for a different monitor: what we know belongs to the old one.
            if let st = states[id], st.uuid != uuid {
                st.window?.orderOut(nil); st.window?.close()
                states[id] = nil
            }
            // Whatever happens below (skip, rebuild, early return), the overlay must not stay where
            // the old screen layout left it.
            states[id]?.window?.reposition()

            let menuHeight = WallpaperProcessor.menuBarHeight(for: screen, menuBarWindows: menuBarWindows)
            guard menuHeight > 0 else {        // menu bar hidden on this screen: show nothing
                states[id]?.window?.orderOut(nil)
                continue
            }
            let stripHeight = menuHeight.rounded(.up) + 1
            guard let current = NSWorkspace.shared.desktopImageURL(for: screen) else { continue }

            // A static wallpaper looks the same in light and dark mode: skip the decode + PNG encode then.
            if let st = states[id], !(forceRebuild && st.processed.appearanceDependent),
               current.standardizedFileURL == st.processed.generatedURL.standardizedFileURL,
               abs(st.processed.stripHeight - stripHeight) < 0.5 {
                st.window?.show()
                continue
            }
            if debug { NSLog("HidenKO: rebuild display %u (%@) menu=%.1f", id, uuid, menuHeight) }
            rebuild(screen: screen, id: id, uuid: uuid, current: current, stripHeight: stripHeight)
        }
    }

    // MARK: - Rebuild

    private func rebuild(screen: NSScreen, id: CGDirectDisplayID, uuid: String, current: URL, stripHeight: CGFloat) {
        guard !inFlight.contains(id) else { return }

        // Work out which file is the user's real wallpaper. A generated file must never be taken
        // for it: its menu bar strip is already black, so the overlay would have nothing to show.
        let original: URL
        var options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
        let settling = Date().timeIntervalSince(lastTopologyChange) < settleWindow

        if !WallpaperProcessor.isGenerated(current) {
            if settling, let r = records[uuid], r.original != current, FileManager.default.fileExists(atPath: r.original.path) {
                // The system swapped in something else right after a display change: keep the user's wallpaper.
                if debug { NSLog("HidenKO: display %u got %@ during a display change; keeping %@", id, current.lastPathComponent, r.original.lastPathComponent) }
                original = r.original; options = r.options
            } else {
                original = current          // the user picked this one
            }
        } else if let r = records[uuid] {
            original = r.original; options = r.options
        } else if let r = records.values.first(where: { $0.generated == current }) {
            // A new or reconnected display inherited a file generated for another display.
            original = r.original; options = r.options
        } else if let r = lastKnownOriginal(for: uuid) {
            // Records are gone (cleared preferences, a restore that did not take): use the independent copy.
            NSLog("HidenKO: display %u: recovered the original from last-known.json", id)
            original = r.original; options = r.options
        } else if let legacy = legacyOriginal(for: id) ?? WallpaperProcessor.generatedDisplayID(current).flatMap(legacyOriginal) {
            original = legacy
        } else {
            NSLog("HidenKO: display %u shows a generated file and its original is unknown; leaving it alone", id)
            return
        }
        guard FileManager.default.fileExists(atPath: original.path) else {
            NSLog("HidenKO: original %@ is missing; leaving display %u alone", original.path, id)
            return
        }

        let info = WallpaperProcessor.info(for: screen)
        let appearance = NSApp.effectiveAppearance
        inFlight.insert(id)
        worker.async { [weak self] in
            let processed = WallpaperProcessor.process(info: info, source: original, stripHeight: stripHeight, appearance: appearance)
            // Hand the decoded wallpaper's memory back to the system; the app idles at a few MB otherwise.
            malloc_zone_pressure_relief(nil, 0)
            DispatchQueue.main.async {
                self?.finishRebuild(id: id, uuid: uuid, previous: current, original: original, options: options, processed: processed)
            }
        }
    }

    private func finishRebuild(id: CGDirectDisplayID, uuid: String, previous: URL, original: URL,
                               options: [NSWorkspace.DesktopImageOptionKey: Any], processed: ProcessedWallpaper?) {
        inFlight.remove(id)
        guard let processed else { NSLog("HidenKO: could not process %@", original.path); return }
        // The screen may be gone, or be another monitor by now.
        guard isEnabled, let screen = screen(for: id), WallpaperProcessor.displayUUID(of: screen) == uuid else {
            try? FileManager.default.removeItem(at: processed.generatedURL)
            return
        }
        do {
            try NSWorkspace.shared.setDesktopImageURL(processed.generatedURL, for: screen, options: Self.fillOptions)
        } catch {
            NSLog("HidenKO: setDesktopImageURL failed: %@", error.localizedDescription)
            try? FileManager.default.removeItem(at: processed.generatedURL)
            return
        }

        var state = states[id] ?? ScreenState(uuid: uuid, original: original, originalOptions: options, processed: processed, window: nil)
        state.original = original
        state.originalOptions = options
        state.processed = processed
        if let w = state.window {
            w.update(screen: screen, processed: processed)
        } else {
            state.window = OverlayWindow(screen: screen, uuid: uuid, processed: processed)
        }
        states[id] = state

        records[uuid] = Record(original: original,
                               scaling: (options[.imageScaling] as? NSNumber)?.uintValue ?? NSImageScaling.scaleProportionallyUpOrDown.rawValue,
                               clipping: (options[.allowClipping] as? Bool) ?? true,
                               generated: processed.generatedURL)
        if let r = records[uuid] { rememberLastKnown(uuid: uuid, original: r.original, scaling: r.scaling, clipping: r.clipping) }
        saveRecords()
        collectGarbage()

        // Give the system a moment to repaint the bar black before the overlay appears. The layout
        // may have changed meanwhile (wake, reconnect), so `show` re-checks where the window goes.
        let window = state.window
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            if self?.isEnabled == true, self?.displaysAsleep == false { window?.show() }
        }
    }

    // MARK: - Change detection

    private func startWatching() {
        startSafetyTimer()
        // The system keeps the chosen wallpaper in this folder; a change there means the user picked another one.
        let path = NSHomeDirectory() + "/Library/Application Support/com.apple.wallpaper/Store"
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend], queue: .main)
        src.setEventHandler { [weak self] in
            if self?.debug == true { NSLog("HidenKO: wallpaper store changed") }
            self?.scheduleRefresh(after: 0.7)
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        storeWatcher = src
    }

    private func stopWatching() {
        safetyTimer?.invalidate(); safetyTimer = nil
        storeWatcher?.cancel(); storeWatcher = nil
    }

    /// Catches whatever the notifications miss. Rare and heavily coalesced by the system.
    private func startSafetyTimer() {
        safetyTimer?.invalidate()
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
        t.tolerance = 30
        RunLoop.main.add(t, forMode: .common)
        safetyTimer = t
    }

    // MARK: - Helpers

    private func screen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { WallpaperProcessor.displayID(of: $0) == id }
    }

    /// Generated files the system's wallpaper store still points to. The store keeps several copies of
    /// the choice (per display, per Space, the system default) and `setDesktopImageURL` only updates
    /// some of them. The system falls back to the others after a reconnect or wake, so a file they
    /// name must stay on disk, or that screen loses its wallpaper.
    private func filesReferencedByWallpaperStore() -> Set<URL> {
        let path = NSHomeDirectory() + "/Library/Application Support/com.apple.wallpaper/Store/Index.plist"
        guard let data = FileManager.default.contents(atPath: path),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        else { return [] }
        var found = Set<URL>()
        func walk(_ value: Any) {
            if let dict = value as? [String: Any] {
                for (key, inner) in dict {
                    if key == "relative", let s = inner as? String, let url = URL(string: s), url.isFileURL,
                       WallpaperProcessor.isGenerated(url) {
                        found.insert(url.standardizedFileURL)
                    } else {
                        walk(inner)
                    }
                }
            } else if let array = value as? [Any] {
                array.forEach(walk)
            }
        }
        walk(plist)
        return found
    }

    /// A store entry may name a generated file that is already gone (deleted by an earlier version, or
    /// by hand). Put a copy of that display's current generated file there, so the system never meets
    /// a missing wallpaper when it falls back to that entry.
    private func healDanglingReferences(_ referenced: Set<URL>) {
        for url in referenced where !FileManager.default.fileExists(atPath: url.path) {
            guard let owner = WallpaperProcessor.generatedDisplayID(url), let screen = screen(for: owner),
                  let r = records[WallpaperProcessor.displayUUID(of: screen)],
                  FileManager.default.fileExists(atPath: r.generated.path) else { continue }
            try? FileManager.default.copyItem(at: r.generated, to: url)
            if debug { NSLog("HidenKO: re-created missing %@ for the wallpaper store", url.lastPathComponent) }
        }
    }

    /// Delete generated files nothing refers to: no record, and not the wallpaper store. A file of a
    /// disconnected display is kept: the system puts it back on that monitor when it returns.
    private func collectGarbage() {
        let referenced = filesReferencedByWallpaperStore()
        healDanglingReferences(referenced)
        let keep = Set(records.values.map { $0.generated.standardizedFileURL }).union(referenced)
        guard let files = try? FileManager.default.contentsOfDirectory(at: WallpaperProcessor.supportDir, includingPropertiesForKeys: nil) else { return }
        for f in files where f.lastPathComponent.hasPrefix("wallpaper-") && !keep.contains(f.standardizedFileURL) {
            // Never pull a file out from under a screen that still shows it.
            let inUse = NSScreen.screens.contains { NSWorkspace.shared.desktopImageURL(for: $0)?.standardizedFileURL == f.standardizedFileURL }
            if !inUse { try? FileManager.default.removeItem(at: f) }
        }
    }

    // MARK: - Persistence

    private func loadRecords() {
        guard let dict = UserDefaults.standard.dictionary(forKey: recordsKey) as? [String: [String: Any]] else { return }
        for (uuid, d) in dict {
            guard let o = d["original"] as? String, let g = d["generated"] as? String else { continue }
            records[uuid] = Record(original: URL(fileURLWithPath: o), scaling: (d["scaling"] as? NSNumber)?.uintValue ?? 3,
                                   clipping: (d["clipping"] as? Bool) ?? true, generated: URL(fileURLWithPath: g))
        }
    }

    // MARK: Last known originals
    //
    // A second, independent copy of "which original belongs to which monitor". It is written when an
    // original is adopted and never cleared by `disable()`, so a lost or emptied preferences file
    // (or a restore that did not take) cannot leave a screen with a generated file and no way home.

    private var lastKnownURL: URL { WallpaperProcessor.supportDir.appendingPathComponent("last-known.json") }

    private func lastKnownOriginal(for uuid: String) -> Record? {
        guard let data = try? Data(contentsOf: lastKnownURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]],
              let d = dict[uuid], let o = d["original"] as? String,
              FileManager.default.fileExists(atPath: o), !WallpaperProcessor.isGenerated(URL(fileURLWithPath: o))
        else { return nil }
        return Record(original: URL(fileURLWithPath: o), scaling: (d["scaling"] as? NSNumber)?.uintValue ?? 3,
                      clipping: (d["clipping"] as? Bool) ?? true, generated: URL(fileURLWithPath: "/"))
    }

    private func rememberLastKnown(uuid: String, original: URL, scaling: UInt, clipping: Bool) {
        var dict = (try? Data(contentsOf: lastKnownURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: [String: Any]] } ?? [:]
        dict[uuid] = ["original": original.path, "scaling": scaling, "clipping": clipping]
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: lastKnownURL, options: .atomic)
        }
    }

    private func saveRecords() {
        if records.isEmpty {
            UserDefaults.standard.removeObject(forKey: recordsKey)
            UserDefaults.standard.removeObject(forKey: legacyKey)
            return
        }
        let dict = records.mapValues { r -> [String: Any] in
            ["original": r.original.path, "generated": r.generated.path, "scaling": r.scaling, "clipping": r.clipping]
        }
        UserDefaults.standard.set(dict, forKey: recordsKey)
    }

    /// Originals saved by the first versions, keyed by display id. Only a fallback.
    private func legacyOriginal(for id: CGDirectDisplayID) -> URL? {
        guard let d = UserDefaults.standard.dictionary(forKey: legacyKey) as? [String: String], let path = d[String(id)] else { return nil }
        let url = URL(fileURLWithPath: path)
        guard !WallpaperProcessor.isGenerated(url), FileManager.default.fileExists(atPath: path) else { return nil }
        return url
    }
}
