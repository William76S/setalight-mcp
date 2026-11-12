import Foundation
import AppKit
import ApplicationServices
import ScreenCaptureKit

let targetBundle = "com.elixxier.SALv2"
struct InputError: Error, CustomStringConvertible { let description: String; init(_ s: String) { description = s } }
func app() throws -> NSRunningApplication {
    guard let a = NSRunningApplication.runningApplications(withBundleIdentifier: targetBundle).first else { throw InputError("set.a.light 3D is not running") }
    return a
}
func front() -> Bool { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == targetBundle }
func assertFront() throws { if !front() { throw InputError("Stopped: frontmost app is not set.a.light 3D") } }
func pause(_ seconds: Double) { RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds)) }
func focus() throws {
    try assertDisplay()
    let a = try app()
    if !front() { _ = a.activate(options: []) }
    let deadline = Date(timeIntervalSinceNow: 2)
    while !front() && Date() < deadline { pause(0.05) }
    try assertFront()
    pause(0.12)
    try assertFront()
}
func windows() throws -> [[String: Any]] {
    let pid = try app().processIdentifier
    let entries = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    return entries.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }.compactMap { w in
        guard let b = w[kCGWindowBounds as String] as? [String: Any] else { return nil }
        return ["id": w[kCGWindowNumber as String] ?? 0, "bounds": b, "title": w[kCGWindowName as String] ?? ""]
    }
}
func displays() -> [[String: Any]] {
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &ids, &count)
    return ids.prefix(Int(count)).map { id in
        let b = CGDisplayBounds(id)
        return ["id": id, "bounds": ["X": b.minX, "Y": b.minY, "Width": b.width, "Height": b.height], "pixelWidth": CGDisplayPixelsWide(id), "pixelHeight": CGDisplayPixelsHigh(id), "scaleX": Double(CGDisplayPixelsWide(id)) / b.width, "scaleY": Double(CGDisplayPixelsHigh(id)) / b.height]
    }
}
func status() throws -> [String: Any] {
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: targetBundle).first
    return ["bundleId": targetBundle, "running": running != nil,
            "pid": running?.processIdentifier ?? 0, "frontmost": front(),
            "accessibilityTrusted": AXIsProcessTrusted(), "eventPostingAllowed": CGPreflightPostEventAccess(),
            "screenRecordingAllowed": CGPreflightScreenCaptureAccess(), "helperVersion": "0.3.1",
            "coordinateSystem": "global Quartz screen points; origin top-left of primary display",
            "windows": running == nil ? [] : try windows(), "displays": displays()]
}
func requestAccess(_ p: [String: Any]) throws -> [String: Any] {
    guard let confirmed = p["confirmed"] as? NSNumber,
          CFGetTypeID(confirmed) == CFBooleanGetTypeID(), confirmed.boolValue else {
        throw InputError("Explicit user confirmation is required before requesting access")
    }
    let permission = p["permission"] as? String ?? "accessibility"
    let granted: Bool
    switch permission {
    case "accessibility":
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        granted = AXIsProcessTrustedWithOptions(options)
    case "screen_recording": granted = CGRequestScreenCaptureAccess()
    default: throw InputError("Unknown permission")
    }
    return ["permission": permission, "granted": granted, "applicationName": "SetALight MCP",
            "applicationBundleId": "local.setalight.mcp",
            "note": "macOS controls the permission dialog; only the user can grant access."]
}
// The run loop keeps AppKit responsive while ScreenCaptureKit returns asynchronously.
func waitFor<T>(_ operation: (@escaping (Result<T, Error>) -> Void) -> Void) throws -> T {
    let lock = NSLock()
    var result: Result<T, Error>?
    operation { value in lock.lock(); result = value; lock.unlock() }
    let deadline = Date(timeIntervalSinceNow: 12)
    while Date() < deadline {
        lock.lock(); let current = result; lock.unlock()
        if let current = current { return try current.get() }
        pause(0.01)
    }
    throw InputError("Screen capture timed out; no input was sent")
}
func screenshot(_ p: [String: Any]) throws -> [String: Any] {
    try assertDisplay()
    guard CGPreflightScreenCaptureAccess() else {
        throw InputError("Screen Recording permission is required for screenshots; no access was requested. Ask the user before request_access(permission: screen_recording).")
    }
    let pid = try app().processIdentifier
    let content: SCShareableContent = try waitFor { done in
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { value, error in
            if let error = error { done(.failure(error)) }
            else if let value = value { done(.success(value)) }
            else { done(.failure(InputError("No shareable window content"))) }
        }
    }
    let candidates = content.windows.filter {
        $0.owningApplication?.processID == pid && $0.owningApplication?.bundleIdentifier == targetBundle &&
        $0.isOnScreen && $0.windowLayer == 0 && $0.frame.width > 1 && $0.frame.height > 1
    }
    let window: SCWindow?
    if p["windowId"] != nil {
        let value = try number(p, "windowId")
        guard value.rounded() == value, value >= 1, value <= Double(UInt32.max) else { throw InputError("Invalid windowId") }
        window = candidates.first { $0.windowID == UInt32(value) }
    } else {
        window = candidates.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }
    guard let window = window else { throw InputError("No matching visible set.a.light window; other applications cannot be captured") }
    let width = p["maxWidth"] == nil ? 1600 : try number(p, "maxWidth")
    guard width.rounded() == width, width >= 640, width <= 2560 else { throw InputError("maxWidth must be an integer from 640 to 2560") }
    let bounds = window.frame
    let filter = SCContentFilter(desktopIndependentWindow: window)
    let config = SCStreamConfiguration()
    config.width = Int(min(width, bounds.width * Double(filter.pointPixelScale)))
    config.height = max(1, Int((Double(config.width) * bounds.height / bounds.width).rounded()))
    config.showsCursor = false
    config.ignoreShadowsSingleWindow = true
    config.scalesToFit = true
    config.preservesAspectRatio = false
    let image: CGImage = try waitFor { done in
        SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { value, error in
            if let error = error { done(.failure(error)) }
            else if let value = value { done(.success(value)) }
            else { done(.failure(InputError("No screenshot returned"))) }
        }
    }
    // A window move/resize during capture makes input coordinates unsafe.
    guard try windows().contains(where: { entry in
        guard let id = entry["id"] as? UInt32, id == window.windowID,
              let b = entry["bounds"] as? [String: Any],
              let current = CGRect(dictionaryRepresentation: b as CFDictionary) else { return false }
        return current == bounds
    }) else { throw InputError("Window changed while capturing; take another screenshot") }
    let bitmap = NSBitmapImageRep(cgImage: image)
    guard let png = bitmap.representation(using: .png, properties: [:]) else { throw InputError("Could not encode screenshot") }
    return ["windowId": window.windowID, "title": window.title ?? "", "bundleId": targetBundle,
            "capturedAt": ISO8601DateFormatter().string(from: Date()),
            "bounds": ["X": bounds.minX, "Y": bounds.minY, "Width": bounds.width, "Height": bounds.height],
            "imageWidth": image.width, "imageHeight": image.height,
            "coordinateMapping": ["originX": bounds.minX, "originY": bounds.minY,
                                  "pointsPerPixelX": bounds.width / Double(image.width),
                                  "pointsPerPixelY": bounds.height / Double(image.height)],
            "coordinateFormula": "screenX = originX + imageX * pointsPerPixelX; screenY = originY + imageY * pointsPerPixelY",
            "imageBase64": png.base64EncodedString()]
}
func fitWindow() throws -> [String: Any] {
    guard AXIsProcessTrusted() else { throw InputError("Accessibility permission is required; no access was requested") }
    try focus()
    let pid = try app().processIdentifier
    let application = AXUIElementCreateApplication(pid)
    var value: CFTypeRef?
    var window: AXUIElement?
    if AXUIElementCopyAttributeValue(application, kAXMainWindowAttribute as CFString, &value) == .success, let value = value, CFGetTypeID(value) == AXUIElementGetTypeID() {
        window = (value as! AXUIElement)
    } else {
        value = nil
        if AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success {
            window = (value as? [AXUIElement])?.first
        }
    }
    guard let window = window else { throw InputError("Cannot obtain the set.a.light main window") }
    var windowPID: pid_t = 0
    guard AXUIElementGetPid(window, &windowPID) == .success, windowPID == pid else { throw InputError("Window does not belong to set.a.light") }
    guard let primary = NSScreen.screens.first else { throw InputError("No primary screen found") }
    let visible = primary.visibleFrame
    let display = CGDisplayBounds(CGMainDisplayID())
    var position = CGPoint(x: visible.minX, y: display.maxY - visible.maxY)
    var size = visible.size
    guard let sizeValue = AXValueCreate(.cgSize, &size), let positionValue = AXValueCreate(.cgPoint, &position) else { throw InputError("Cannot construct window geometry values") }
    try assertFront()
    let sized = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
    guard sized == .success else { throw InputError("set.a.light rejected main-window resizing: AXError \(sized.rawValue)") }
    let moved = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
    guard moved == .success else { throw InputError("Window was resized but repositioning failed: AXError \(moved.rawValue)") }
    pause(0.25)
    return ["requestedBounds": ["X": position.x, "Y": position.y, "Width": size.width, "Height": size.height], "windows": try windows()]
}
func validatePoint(_ point: CGPoint) throws {
    guard point.x.isFinite && point.y.isFinite else { throw InputError("Coordinates must be finite") }
    let ws = try windows()
    let inside = ws.contains { w in
        guard let b = w["bounds"] as? [String: Any], let x = b["X"] as? Double, let y = b["Y"] as? Double, let width = b["Width"] as? Double, let height = b["Height"] as? Double else { return false }
        return CGRect(x: x, y: y, width: width, height: height).contains(point)
    }
    if !inside { throw InputError("Coordinates are outside visible set.a.light windows") }
    let insideDisplay = displays().contains { display in
        guard let b = display["bounds"] as? [String: CGFloat], let x = b["X"], let y = b["Y"], let width = b["Width"], let height = b["Height"] else { return false }
        return CGRect(x: x, y: y, width: width, height: height).contains(point)
    }
    if !insideDisplay { throw InputError("Coordinates are outside the active displays") }
}
func assertDisplay() throws {
    guard !displays().isEmpty else { throw InputError("No active display session. Unlock the Mac and connect a display before retrying.") }
}
func assertPosting() throws { try assertDisplay(); if !CGPreflightPostEventAccess() { throw InputError("macOS event-posting permission is unavailable; no access was requested or settings changed") } }
func number(_ p: [String: Any], _ name: String) throws -> Double {
    guard let n = p[name] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { throw InputError("Expected finite number: \(name)") }
    return n.doubleValue
}
func raiseTargetMainWindow() throws {
    let pid = try app().processIdentifier
    let application = AXUIElementCreateApplication(pid)
    var value: CFTypeRef?
    var window: AXUIElement?
    if AXUIElementCopyAttributeValue(application, kAXMainWindowAttribute as CFString, &value) == .success, let value = value, CFGetTypeID(value) == AXUIElementGetTypeID() {
        window = (value as! AXUIElement)
    } else {
        value = nil
        if AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success { window = (value as? [AXUIElement])?.first }
    }
    guard let window = window else { throw InputError("Cannot obtain set.a.light main window for AXRaise") }
    var windowPID: pid_t = 0
    guard AXUIElementGetPid(window, &windowPID) == .success, windowPID == pid else { throw InputError("AXRaise target does not belong to set.a.light") }
    let result = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    guard result == .success else { throw InputError("AXRaise failed: \(result.rawValue)") }
}
func hitTest(_ point: CGPoint, targetPID: pid_t) -> (Bool, [String: Any]) {
    var element: AXUIElement?
    let result = AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &element)
    guard result == .success, let element = element else { return (false, ["axError": result.rawValue, "pid": -1, "bundleId": "", "role": ""]) }
    var pid: pid_t = 0
    let pidResult = AXUIElementGetPid(element, &pid)
    var role: CFTypeRef?
    _ = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
    let diagnostic: [String: Any] = ["pid": pid, "bundleId": NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "", "role": (role as? String) ?? "", "axError": pidResult.rawValue]
    return (pidResult == .success && pid == targetPID, diagnostic)
}
func clickHID(_ p: [String: Any], focusBefore: Bool = true) throws -> [String: Any] {
    let point = CGPoint(x: try number(p, "x"), y: try number(p, "y"))
    let duration = (p["durationMs"] == nil ? 120 : try number(p, "durationMs")) / 1000
    guard duration >= 0.02 && duration <= 1 else { throw InputError("durationMs must be 20...1000") }
    guard AXIsProcessTrusted() else { throw InputError("Accessibility access is required for hit testing; no access was requested") }
    try assertPosting()
    if focusBefore { try focus(); try raiseTargetMainWindow(); pause(0.10) }
    else { try assertFront() }
    try validatePoint(point); try assertFront()
    let pid = try app().processIdentifier
    let initialHit = hitTest(point, targetPID: pid)
    guard initialHit.0 else { return ["clicked": false, "stage": "before_pointer_move", "hit": initialHit.1, "reason": "AX hit does not belong to set.a.light; no mouse event was posted"] }
    guard let source = CGEventSource(stateID: .hidSystemState),
          let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left),
          let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
          let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else { throw InputError("Could not construct HID mouse events") }
    move.flags = []; down.flags = []; up.flags = []
    down.setIntegerValueField(.mouseEventClickState, value: 1)
    up.setIntegerValueField(.mouseEventClickState, value: 1)
    guard CGWarpMouseCursorPosition(point) == .success else { throw InputError("Cursor positioning failed") }
    move.post(tap: .cghidEventTap); pause(0.10)
    try assertFront()
    let finalHit = hitTest(point, targetPID: pid)
    guard finalHit.0 else { return ["clicked": false, "stage": "before_mouse_down", "hit": finalHit.1, "reason": "AX hit changed after pointer move; no click was posted"] }
    guard !CGEventSource.buttonState(.combinedSessionState, button: .left) else { throw InputError("Mouse button already held; no input sent") }
    down.post(tap: .cghidEventTap); pause(duration)
    // Always release the button after sending down, including if focus changes.
    up.post(tap: .cghidEventTap); pause(0.10)
    return ["clicked": true, "method": "HID", "point": ["x": point.x, "y": point.y], "hit": finalHit.1, "frontmostAfter": front(), "uiEffectVerified": false]
}
func scrollHID(_ p: [String: Any], focusBefore: Bool = true) throws -> [String: Any] {
    let point = CGPoint(x: try number(p, "x"), y: try number(p, "y"))
    let delta = try number(p, "deltaY")
    guard delta.rounded() == delta, delta != 0, abs(delta) <= 2000 else { throw InputError("deltaY must be a nonzero integer from -2000 to 2000; positive scrolls up, negative scrolls down") }
    guard AXIsProcessTrusted() else { throw InputError("Accessibility access is required for hit testing; no access was requested") }
    try assertPosting()
    if focusBefore { try focus(); try raiseTargetMainWindow(); pause(0.10) }
    else { try assertFront() }
    try validatePoint(point); try assertFront()
    let pid = try app().processIdentifier
    let initialHit = hitTest(point, targetPID: pid)
    guard initialHit.0 else { return ["scrolled": false, "stage": "before_pointer_move", "hit": initialHit.1, "reason": "AX hit does not belong to set.a.light; no mouse event was posted"] }
    guard let source = CGEventSource(stateID: .hidSystemState),
          let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left),
          let scroll = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1, wheel1: Int32(delta), wheel2: 0, wheel3: 0) else { throw InputError("Could not construct HID scroll events") }
    move.flags = []; scroll.flags = []
    scroll.location = point
    guard CGWarpMouseCursorPosition(point) == .success else { throw InputError("Cursor positioning failed") }
    move.post(tap: .cghidEventTap); pause(0.10)
    try assertFront()
    let finalHit = hitTest(point, targetPID: pid)
    guard finalHit.0 else { return ["scrolled": false, "stage": "before_scroll", "hit": finalHit.1, "reason": "AX hit changed after pointer move; no scroll event was posted"] }
    scroll.post(tap: .cghidEventTap); pause(0.15)
    return ["scrolled": true, "method": "HID", "point": ["x": point.x, "y": point.y], "deltaY": delta, "units": "pixels; positive up, negative down", "hit": finalHit.1, "frontmostAfter": front(), "uiEffectVerified": false]
}
func dragHID(_ p: [String: Any], focusBefore: Bool = true) throws -> [String: Any] {
    let start = CGPoint(x: try number(p, "fromX"), y: try number(p, "fromY"))
    let end = CGPoint(x: try number(p, "toX"), y: try number(p, "toY"))
    let duration = (p["durationMs"] == nil ? 500 : try number(p, "durationMs")) / 1000
    guard duration >= 0.2 && duration <= 2 else { throw InputError("durationMs must be 200...2000") }
    guard AXIsProcessTrusted() else { throw InputError("Accessibility access is required for hit testing; no access was requested") }
    try assertPosting()
    if focusBefore { try focus(); try raiseTargetMainWindow(); pause(0.10) }
    else { try assertFront() }
    try validatePoint(start); try validatePoint(end); try assertFront()
    let pid = try app().processIdentifier
    let startHit = hitTest(start, targetPID: pid)
    let endHit = hitTest(end, targetPID: pid)
    guard startHit.0 && endHit.0 else { return ["dragged": false, "stage": "before_pointer_move", "startHit": startHit.1, "endHit": endHit.1, "reason": "Both endpoints must hit set.a.light; no mouse event was posted"] }
    let steps = max(10, min(60, Int(duration / 0.02)))
    // Check the complete straight path before pressing a mouse button.
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps)
        try validatePoint(CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
    }
    guard let source = CGEventSource(stateID: .hidSystemState),
          let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: start, mouseButton: .left),
          let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left),
          let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left) else { throw InputError("Could not construct HID drag events") }
    move.flags = []; down.flags = []; up.flags = []
    let eventNumber = Int64(Date().timeIntervalSince1970 * 1000) & 0x7fffffff
    down.setIntegerValueField(.mouseEventButtonNumber, value: 0)
    up.setIntegerValueField(.mouseEventButtonNumber, value: 0)
    down.setIntegerValueField(.mouseEventNumber, value: eventNumber)
    up.setIntegerValueField(.mouseEventNumber, value: eventNumber)
    down.setDoubleValueField(.mouseEventPressure, value: 1)
    up.setDoubleValueField(.mouseEventPressure, value: 0)
    down.setIntegerValueField(.mouseEventClickState, value: 1)
    up.setIntegerValueField(.mouseEventClickState, value: 1)
    guard CGWarpMouseCursorPosition(start) == .success else { throw InputError("Cursor positioning failed") }
    move.post(tap: .cghidEventTap); pause(0.10); try assertFront()
    let finalStartHit = hitTest(start, targetPID: pid)
    let finalEndHit = hitTest(end, targetPID: pid)
    guard finalStartHit.0 && finalEndHit.0 else { return ["dragged": false, "stage": "before_mouse_down", "startHit": finalStartHit.1, "endHit": finalEndHit.1, "reason": "An endpoint no longer hits set.a.light; no button event was posted"] }
    guard !CGEventSource.buttonState(.combinedSessionState, button: .left) else { throw InputError("Mouse button already held; no input sent") }
    down.post(tap: .cghidEventTap)
    pause(0.10)
    let hidButtonAfterDown = CGEventSource.buttonState(.hidSystemState, button: .left)
    let sessionButtonAfterDown = CGEventSource.buttonState(.combinedSessionState, button: .left)
    var lastPoint = start
    var interrupted = false
    for i in 1...steps {
        pause(duration / Double(steps))
        if !front() { interrupted = true; break }
        let t = CGFloat(i) / CGFloat(steps)
        let point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
        do { try validatePoint(point) } catch { interrupted = true; break }
        if !hitTest(point, targetPID: pid).0 { interrupted = true; break }
        guard let dragged = CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left) else { interrupted = true; break }
        // Send movement as a drag event, not a cursor warp. Unity may consume
        // relative deltas rather than merely the cursor's absolute position.
        dragged.flags = []
        dragged.setIntegerValueField(.mouseEventButtonNumber, value: 0)
        dragged.setIntegerValueField(.mouseEventNumber, value: eventNumber)
        dragged.setIntegerValueField(.mouseEventClickState, value: 1)
        dragged.setDoubleValueField(.mouseEventPressure, value: 1)
        dragged.setIntegerValueField(.mouseEventDeltaX, value: Int64(point.x.rounded() - lastPoint.x.rounded()))
        dragged.setIntegerValueField(.mouseEventDeltaY, value: Int64(point.y.rounded() - lastPoint.y.rounded()))
        dragged.post(tap: .cghidEventTap)
        lastPoint = point
    }
    // Release even on interruption so no synthesized button remains held.
    up.location = lastPoint
    up.post(tap: .cghidEventTap); pause(0.10)
    return ["dragged": !interrupted, "method": "HID", "from": ["x": start.x, "y": start.y], "requestedTo": ["x": end.x, "y": end.y], "actualTo": ["x": lastPoint.x, "y": lastPoint.y], "durationMs": duration * 1000, "interrupted": interrupted, "frontmostAfter": front(), "hidButtonAfterDown": hidButtonAfterDown, "sessionButtonAfterDown": sessionButtonAfterDown, "uiEffectVerified": false]
}
let keyCodes: [String: CGKeyCode] = ["a":0,"s":1,"d":2,"f":3,"h":4,"g":5,"z":6,"x":7,"c":8,"v":9,"b":11,"q":12,"w":13,"e":14,"r":15,"y":16,"t":17,"1":18,"2":19,"3":20,"4":21,"6":22,"5":23,"equal":24,"9":25,"7":26,"minus":27,"8":28,"0":29,"rightbracket":30,"o":31,"u":32,"leftbracket":33,"i":34,"p":35,"return":36,"l":37,"j":38,"apostrophe":39,"k":40,"semicolon":41,"backslash":42,"comma":43,"slash":44,"n":45,"m":46,"period":47,"tab":48,"space":49,"backspace":51,"escape":53,"delete":117,"home":115,"end":119,"pageup":116,"pagedown":121,"left":123,"right":124,"down":125,"up":126]
func keypress(_ p: [String: Any]) throws -> [String: Any] {
    guard let raw = p["key"] as? String else { throw InputError("Expected key string, e.g. cmd+a or return") }
    let bits = raw.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
    guard let key = bits.last, let code = keyCodes[key] else { throw InputError("Key not in allowlist") }
    var flags = CGEventFlags()
    for modifier in bits.dropLast() {
        switch modifier {
        case "cmd", "command", "super": flags.insert(.maskCommand)
        case "ctrl", "control": flags.insert(.maskControl)
        case "alt", "option": flags.insert(.maskAlternate)
        case "shift": flags.insert(.maskShift)
        default: throw InputError("Modifier not in allowlist")
        }
    }
    if flags.contains(.maskCommand) && ["tab", "space", "h"].contains(key) { throw InputError("Global/hide shortcuts are not permitted") }
    if flags.contains(.maskCommand) && flags.contains(.maskAlternate) && key == "escape" { throw InputError("System shortcut is not permitted") }
    if flags.contains(.maskControl) && ["left", "right", "up", "down"].contains(key) { throw InputError("Workspace shortcuts are not permitted") }
    try assertPosting(); try assertFront()
    let pid = try app().processIdentifier
    guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true), let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else { throw InputError("Could not construct key event") }
    down.flags = flags; up.flags = flags
    down.postToPid(pid); pause(0.04); up.postToPid(pid); pause(0.08)
    return ["key": raw, "frontmostAfter": front(), "uiEffectVerified": false]
}
func typeText(_ p: [String: Any]) throws -> [String: Any] {
    guard let text = p["text"] as? String, text.utf16.count <= 4096 else { throw InputError("text must be a string of at most 4096 UTF-16 units") }
    try assertPosting(); try assertFront()
    let pid = try app().processIdentifier
    // Small character-aligned chunks avoid splitting a surrogate pair.
    for character in text {
        try assertFront()
        let units = Array(String(character).utf16)
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true), let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { throw InputError("Could not construct text event") }
        down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        down.flags = []; up.flags = []
        down.postToPid(pid); up.postToPid(pid)
        pause(0.015)
    }
    return ["typedUTF16Units": text.utf16.count, "frontmostAfter": front(), "uiEffectVerified": false]
}
func dispatch(_ request: [String: Any], allowBatch: Bool = true, focusBefore: Bool = true) throws -> [String: Any] {
    guard let command = request["command"] as? String else { throw InputError("Missing command") }
    switch command {
    case "status": return try status()
    case "screenshot": return try screenshot(request)
    case "request_access": return try requestAccess(request)
    case "fit_window": return try fitWindow()
    case "focus":
        if focusBefore { try focus() } else { try assertFront() }
        return try status()
    case "click", "click_hid": return try clickHID(request, focusBefore: focusBefore)
    case "scroll_hid": return try scrollHID(request, focusBefore: focusBefore)
    case "drag_hid": return try dragHID(request, focusBefore: focusBefore)
    case "keypress": return try keypress(request)
    case "type_text": return try typeText(request)
    case "batch":
        guard allowBatch, let actions = request["actions"] as? [[String: Any]], !actions.isEmpty, actions.count <= 20 else { throw InputError("batch requires 1..20 non-nested actions") }
        guard actions.reduce(0, { $0 + (($1["text"] as? String)?.utf16.count ?? 0) }) <= 4096 else { throw InputError("Combined batch text exceeds 4096 UTF-16 units") }
        var results = [[String: Any]]()
        for (i, action) in actions.enumerated() {
            do {
                if i > 0 { try assertFront() }
                guard let command = action["command"] as? String, ["focus", "click", "click_hid", "scroll_hid", "drag_hid", "keypress", "type_text"].contains(command) else { throw InputError("Batch action not allowed") }
                let result = try dispatch(action, allowBatch: false, focusBefore: i == 0)
                if ["clicked", "scrolled", "dragged", "frontmostAfter"].contains(where: { (result[$0] as? Bool) == false }) || result["interrupted"] as? Bool == true {
                    return ["interrupted": true, "failedIndex": i, "completedCount": results.count,
                            "results": results, "failedResult": result, "uiEffectVerified": false]
                }
                results.append(result)
            } catch {
                return ["interrupted": true, "failedIndex": i, "completedCount": results.count,
                        "results": results, "error": String(describing: error), "uiEffectVerified": false]
            }
        }
        return ["results": results, "completedCount": results.count, "interrupted": false, "uiEffectVerified": false]
    default: throw InputError("Unknown command")
    }
}
do {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    let data: Data
    if CommandLine.arguments.count == 2 { data = Data(CommandLine.arguments[1].utf8) }
    else { data = FileHandle.standardInput.readDataToEndOfFile() }
    guard data.count <= 65536, let request = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw InputError("Expected JSON object under 64 KiB") }
    let result = try dispatch(request)
    let output = try JSONSerialization.data(withJSONObject: ["ok": true, "result": result], options: [.sortedKeys])
    FileHandle.standardOutput.write(output); FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    let output = try! JSONSerialization.data(withJSONObject: ["ok": false, "error": String(describing: error)], options: [.sortedKeys])
    FileHandle.standardOutput.write(output); FileHandle.standardOutput.write(Data("\n".utf8)); exit(1)
}
