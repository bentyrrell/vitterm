import AppKit
import ObjectiveC

/// The terminal window.
///
/// A window with both `.fullSizeContentView` and `titlebarAppearsTransparent` (which we need to paint
/// the titlebar with the theme and put the tab strip in it) is dragged by the window server without
/// AppKit treating it as a user move ("Window move completed without beginning"). On every move event
/// AppKit then runs `-[NSWindow _setFrameAfterMove:]` as if the window had been moved programmatically:
/// it clamps the window below the menu bar of the screen it was on, and once the drag crosses onto
/// another display it re-places the window there (centered, or where it last was on that display), so
/// the window jumps away from the cursor.
///
/// While the left mouse button is down we skip that method and simply adopt the frame the window server
/// has. Nothing public sits on this path (`setFrame` and `constrainFrameRect` are never called), so the
/// hook is private API; it is installed only if the method exists with the expected signature, and the
/// window falls back to AppKit's behavior otherwise.
final class TerminalWindow: NSWindow {
    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        _ = TerminalWindow.installMoveHook
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
    }

    private static let installMoveHook: Void = {
        let sel = NSSelectorFromString("_setFrameAfterMove:")
        guard let method = class_getInstanceMethod(NSWindow.self, sel),
              let encoding = method_getTypeEncoding(method),
              String(cString: encoding) == "v48@0:8{CGRect={CGPoint=dd}{CGSize=dd}}16" else { return }
        typealias Original = @convention(c) (NSWindow, Selector, NSRect) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
        let replacement: @convention(block) (NSWindow, NSRect) -> Void = { window, rect in
            if let w = window as? TerminalWindow, w.isBeingDragged {
                w.followDrag(to: w.serverFrame ?? rect)
            } else {
                original(window, sel, rect)
            }
        }
        class_addMethod(TerminalWindow.self, sel, imp_implementationWithBlock(replacement), encoding)
    }()

    /// A move while the left button is down is the user dragging the window (live resizes excluded).
    private var isBeingDragged: Bool {
        NSEvent.pressedMouseButtons & 1 != 0 && !inLiveResize && !styleMask.contains(.fullScreen)
    }

    /// Record where the window server has put the window, without any constraining or re-placement.
    private func followDrag(to r: NSRect) {
        if frame != r { setFrame(r, display: false) }
    }

    /// The window's current frame according to the window server, in AppKit screen coordinates.
    private var serverFrame: NSRect? {
        guard windowNumber > 0,
              let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(windowNumber)) as? [[CFString: Any]],
              let dict = info.first?[kCGWindowBounds],
              let b = CGRect(dictionaryRepresentation: dict as! CFDictionary),
              let primary = NSScreen.screens.first else { return nil }
        // CoreGraphics measures from the top-left of the primary display, AppKit from its bottom-left.
        return NSRect(x: b.minX, y: primary.frame.maxY - b.maxY, width: b.width, height: b.height)
    }
}
