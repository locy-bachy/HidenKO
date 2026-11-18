import AppKit
import QuartzCore

/// Click-through window that sits over the menu bar. It samples what is behind it (the black
/// menu bar plus its white text and status items) and screen-blends the real wallpaper strip on
/// top: black becomes wallpaper, white stays white.
///
/// The window knows which monitor it belongs to (by UUID) and puts itself back over that
/// monitor's menu bar whenever it is moved, including when macOS shuffles windows around during
/// a display change or wake. Event driven: no polling.
final class OverlayWindow: NSWindow {
    private let wallpaperLayer = CALayer()
    let displayUUID: String
    private var stripHeight: CGFloat

    init(screen: NSScreen, uuid: String, processed: ProcessedWallpaper) {
        displayUUID = uuid
        stripHeight = processed.stripHeight
        let h = processed.stripHeight
        let rect = NSRect(x: screen.frame.minX, y: screen.frame.maxY - h, width: screen.frame.width, height: h)
        super.init(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        level = .statusBar
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]

        let view = NSView(frame: NSRect(origin: .zero, size: rect.size))
        view.wantsLayer = true
        view.layerContentsRedrawPolicy = .never   // nothing to draw: AppKit never needs to redisplay it
        view.autoresizingMask = [.width, .height]
        let root = view.layer!
        root.masksToBounds = true

        if let backdrop = Self.makeBackdropLayer() {
            backdrop.frame = root.bounds
            backdrop.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            root.addSublayer(backdrop)
        }

        wallpaperLayer.frame = root.bounds
        wallpaperLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        wallpaperLayer.contentsGravity = .resize
        wallpaperLayer.contentsScale = screen.backingScaleFactor
        wallpaperLayer.compositingFilter = "screenBlendMode"
        wallpaperLayer.contents = processed.strip
        root.addSublayer(wallpaperLayer)

        contentView = view

        // macOS moves windows to another screen when theirs goes away or the layout changes.
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(moved), name: NSWindow.didMoveNotification, object: self)
        nc.addObserver(self, selector: #selector(moved), name: NSWindow.didChangeScreenNotification, object: self)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The frame is always set by `reposition()`; never let AppKit nudge it elsewhere.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    @objc private func moved() { reposition() }

    /// Put the window over its own monitor's menu bar. Screen origins move when a display is
    /// connected, disconnected or rearranged, even if the wallpaper itself does not change.
    /// Returns false (and hides the window) when that monitor is not connected right now.
    @discardableResult
    func reposition() -> Bool {
        guard let screen = NSScreen.screens.first(where: { WallpaperProcessor.displayUUID(of: $0) == displayUUID }) else {
            orderOut(nil)
            return false
        }
        let rect = NSRect(x: screen.frame.minX, y: screen.frame.maxY - stripHeight, width: screen.frame.width, height: stripHeight)
        if frame != rect { setFrame(rect, display: false) }
        return true
    }

    /// Show the window, but only where it belongs.
    func show() {
        if reposition(), !isVisible { orderFrontRegardless() }
    }

    func update(screen: NSScreen, processed: ProcessedWallpaper) {
        stripHeight = processed.stripHeight
        reposition()
        // No implicit 0.25 s cross-fade: one frame instead of a burst of animation frames.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wallpaperLayer.contentsScale = screen.backingScaleFactor
        wallpaperLayer.contents = processed.strip
        CATransaction.commit()
    }

    /// CABackdropLayer is a private QuartzCore class; look it up at runtime and only touch keys it responds to.
    private static func makeBackdropLayer() -> CALayer? {
        guard let cls = NSClassFromString("CABackdropLayer") as? CALayer.Type else {
            NSLog("HidenKO: CABackdropLayer not available")
            return nil
        }
        let layer = cls.init()
        func set(_ key: String, _ value: Any) {
            let setter = NSSelectorFromString("set" + key.prefix(1).uppercased() + key.dropFirst() + ":")
            if layer.responds(to: setter) { layer.setValue(value, forKey: key) }
        }
        set("windowServerAware", true)
        set("groupName", "HidenKO")
        set("scale", 1.0)
        return layer
    }
}
