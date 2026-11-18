import AppKit

/// Plain-value snapshot of an NSScreen, safe to hand to a background queue.
struct ScreenInfo {
    let id: CGDirectDisplayID
    let size: CGSize          // points
    let scale: CGFloat
    let colorSpace: CGColorSpace
}

/// Result of preparing one screen: the untouched top strip of the wallpaper (shown by the
/// overlay) and a generated copy of the wallpaper whose menu bar area is pure black.
struct ProcessedWallpaper {
    let strip: CGImage
    let generatedURL: URL
    let stripHeight: CGFloat  // points: menu bar height plus a safety margin
    /// Source holds more than one image (dynamic light/dark wallpaper), so the result depends on the appearance.
    let appearanceDependent: Bool
}

enum WallpaperProcessor {
    static let supportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("HidenKO", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Height of the real menu bar on this screen, in points. 0 when it is hidden.
    /// Read from the WindowServer menu bar window: on notched MacBooks the bar is taller than
    /// `frame.maxY - visibleFrame.maxY` suggests.
    /// `menuBarWindows` comes from `menuBarWindows()`, fetched once per refresh for all screens.
    static func menuBarHeight(for screen: NSScreen, menuBarWindows: [[String: Any]]) -> CGFloat {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let cgX = screen.frame.minX
        let cgY = primaryHeight - screen.frame.maxY

        for w in menuBarWindows {
            guard let b = w[kCGWindowBounds as String] as? [String: Any],
                  let x = b["X"] as? Double, let y = b["Y"] as? Double,
                  let width = b["Width"] as? Double, let height = b["Height"] as? Double
            else { continue }
            if abs(x - cgX) < 2, abs(y - cgY) < 2, abs(width - screen.frame.width) < 2, height > 1, height < 120 {
                return CGFloat(height)
            }
        }
        let diff = screen.frame.maxY - screen.visibleFrame.maxY
        return diff > 1 && diff < 120 ? diff : 0
    }

    /// The WindowServer menu bar windows (layer 24). One window-list round trip for all screens.
    static func menuBarWindows() -> [[String: Any]] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.filter {
            ($0[kCGWindowLayer as String] as? Int) == 24 && ($0[kCGWindowOwnerName as String] as? String) == "Window Server"
        }
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    /// Stable identity of the physical display. `CGDirectDisplayID` changes after a reconnect, the UUID does not.
    static func displayUUID(of screen: NSScreen) -> String {
        let id = displayID(of: screen)
        if let cf = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
           let s = CFUUIDCreateString(nil, cf) as String? {
            return s
        }
        return "id-\(id)"
    }

    static func info(for screen: NSScreen) -> ScreenInfo {
        ScreenInfo(id: displayID(of: screen), size: screen.frame.size, scale: screen.backingScaleFactor,
                   colorSpace: screen.colorSpace?.cgColorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!)
    }

    /// Files made by this app (or by its earlier "ClearBar" build) are never a user's real wallpaper.
    static func isGenerated(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let legacy = supportDir.deletingLastPathComponent().appendingPathComponent("ClearBar").standardizedFileURL.path
        return path.hasPrefix(supportDir.standardizedFileURL.path) || path.hasPrefix(legacy)
    }

    /// Display a generated file was made for, from its name "wallpaper-<id>-<stamp>.png".
    static func generatedDisplayID(_ url: URL) -> CGDirectDisplayID? {
        guard isGenerated(url) else { return nil }
        let parts = url.deletingPathExtension().lastPathComponent.split(separator: "-")
        guard parts.count == 3, parts[0] == "wallpaper" else { return nil }
        return CGDirectDisplayID(parts[1])
    }

    /// Heavy part (decode, scale, encode PNG). Safe to call off the main thread.
    static func process(info: ScreenInfo, source: URL, stripHeight: CGFloat, appearance: NSAppearance) -> ProcessedWallpaper? {
        autoreleasepool {
            guard stripHeight > 0, let image = NSImage(contentsOf: source) else { return nil }
            // Pixel size of the best representation, so "fill" maths works for dynamic (.heic) wallpapers too.
            let rep = image.representations.max { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh }
            let sw = CGFloat(rep?.pixelsWide ?? Int(image.size.width))
            let sh = CGFloat(rep?.pixelsHigh ?? Int(image.size.height))
            guard sw > 0, sh > 0 else { return nil }

            let pxW = Int((info.size.width * info.scale).rounded())
            let pxH = Int((info.size.height * info.scale).rounded())
            let stripPx = min(pxH, Int((stripHeight * info.scale).rounded(.up)))

            // Opaque bitmap: a wallpaper has no transparency. No alpha channel means a smaller, faster PNG
            // for us to encode and for the wallpaper agent to decode, and cheaper compositing of the strip.
            let opaque = CGImageAlphaInfo.noneSkipLast.rawValue
            guard let ctx = CGContext(data: nil, width: pxW, height: pxH, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: info.colorSpace, bitmapInfo: opaque)
            else { return nil }

            // "Fill Screen": scale to cover, centre-crop.
            let s = max(CGFloat(pxW) / sw, CGFloat(pxH) / sh)
            let dw = sw * s, dh = sh * s
            ctx.interpolationQuality = .high
            let dest = CGRect(x: (CGFloat(pxW) - dw) / 2, y: (CGFloat(pxH) - dh) / 2, width: dw, height: dh)

            // Draw through AppKit under the system appearance, so a dynamic wallpaper resolves to
            // the light or dark variant the user is looking at right now.
            let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = gc
            appearance.performAsCurrentDrawingAppearance {
                image.draw(in: dest, from: .zero, operation: .copy, fraction: 1)
            }
            NSGraphicsContext.restoreGraphicsState()

            // Copy the strip into a bitmap of its own. Cropping a full-screen CGImage would keep the whole
            // full-screen buffer (tens of MB per display) alive for as long as the overlay shows the strip,
            // and making that image before the black fill would force a second full-screen copy.
            // The first rows in memory are the top of the picture, i.e. the menu bar.
            guard let src = ctx.data,
                  let stripCtx = CGContext(data: nil, width: pxW, height: stripPx, bitsPerComponent: 8, bytesPerRow: 0,
                                           space: info.colorSpace, bitmapInfo: opaque),
                  let dst = stripCtx.data
            else { return nil }
            for row in 0..<stripPx {
                memcpy(dst + row * stripCtx.bytesPerRow, src + row * ctx.bytesPerRow, min(ctx.bytesPerRow, stripCtx.bytesPerRow))
            }
            guard let strip = stripCtx.makeImage() else { return nil }

            // CGContext origin is bottom-left, so the menu bar is the top rows of the bitmap.
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: pxH - stripPx, width: pxW, height: stripPx))
            guard let modified = ctx.makeImage() else { return nil }

            let stamp = Int(Date().timeIntervalSince1970 * 1000)
            let url = supportDir.appendingPathComponent("wallpaper-\(info.id)-\(stamp).png")
            guard let out = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(out, modified, nil)
            guard CGImageDestinationFinalize(out) else { return nil }
            return ProcessedWallpaper(strip: strip, generatedURL: url, stripHeight: stripHeight,
                                      appearanceDependent: isAppearanceDependent(source))
        }
    }

    /// A single-image file looks the same in light and dark mode; only multi-image (dynamic .heic)
    /// wallpapers need a rebuild when the appearance changes. Reads the header only. Unknown → true.
    static func isAppearanceDependent(_ url: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return true }
        return CGImageSourceGetCount(src) != 1
    }

}
