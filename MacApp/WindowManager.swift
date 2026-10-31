import AppKit
import ApplicationServices

struct WindowSnapshot {
    let element: AXUIElement
    let frame: CGRect
}
struct LayoutResult {
    var moved = 0
    var skipped = 0
    var snapshots: [WindowSnapshot] = []
}
enum WindowManager {
    static func attribute(_ element: AXUIElement, _ key: CFString) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key, &result) == .success else { return nil }
        return result
    }
    static func frame(_ window: AXUIElement) -> CGRect? {
        guard let position = attribute(window, kAXPositionAttribute as CFString),
              let size = attribute(window, kAXSizeAttribute as CFString),
              CFGetTypeID(position) == AXValueGetTypeID(),
              CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }
    static func setFrame(_ frame: CGRect, window: AXUIElement) -> Bool {
        var point = frame.origin
        var size = frame.size
        guard let position = AXValueCreate(.cgPoint, &point),
              let dimensions = AXValueCreate(.cgSize, &size) else { return false }
        let resized = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, dimensions)
        let moved = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
        return resized == .success && moved == .success
    }
    static func arrange(pids: [pid_t], rectangles: [CGRect]) -> LayoutResult {
        var result = LayoutResult()
        var slot = 0
        for pid in pids {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 1.5)
            guard let windows = attribute(app, kAXWindowsAttribute as CFString) as? [AXUIElement] else { continue }
            for window in windows {
                guard slot < rectangles.count else { return result }
                guard attribute(window, kAXSubroleAttribute as CFString) as? String == kAXStandardWindowSubrole,
                      attribute(window, kAXMinimizedAttribute as CFString) as? Bool != true,
                      attribute(window, "AXFullScreen" as CFString) as? Bool != true else { continue }
                guard let original = frame(window) else { result.skipped += 1; continue }
                let desired = rectangles[slot]
                let success = setFrame(desired, window: window)
                if let actual = frame(window), actual != original {
                    result.snapshots.append(WindowSnapshot(element: window, frame: original))
                }
                // Terminal snaps to character cells; other apps can enforce a minimum size.
                if success {
                    result.moved += 1
                    if let actual = frame(window),
                       abs(actual.width - desired.width) > 20 || abs(actual.height - desired.height) > 20 {
                        result.skipped += 1
                    }
                    slot += 1
                } else {
                    result.skipped += 1
                }
            }
        }
        return result
    }
    static func restore(_ snapshots: [WindowSnapshot]) -> Int {
        snapshots.filter { !setFrame($0.frame, window: $0.element) }.count
    }
}
