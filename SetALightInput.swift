import Foundation
import AppKit
import ApplicationServices
import ScreenCaptureKit
import Vision
import CryptoKit
import Darwin

let targetBundle = "com.elixxier.SALv2"
var cancellationSignal: Int32 = 0
let originalParent = getppid()
var expectedObservation: [String: Any]?
func cancelled() -> Bool { cancellationSignal != 0 || getppid() != originalParent }
func checkCancellation() throws { if cancelled() { throw InputError("CANCELLED: operation stopped; already-applied input is not rolled back") } }
func checkObservation() throws {
    try checkCancellation()
    guard let expected = expectedObservation else { return }
    guard let pid = expected["pid"] as? Int32, pid == (try app()).processIdentifier,
          let windowID = expected["windowId"] as? UInt32,
          let raw = expected["bounds"] as? [String: Any],
          let frame = CGRect(dictionaryRepresentation: raw as CFDictionary),
          let captured = expected["capturedAtMs"] as? Double,
          Date().timeIntervalSince1970 * 1000 - captured >= -1000,
          Date().timeIntervalSince1970 * 1000 - captured <= 180000,
          try windows().contains(where: { entry in
              guard entry["id"] as? UInt32 == windowID, let b = entry["bounds"] as? [String: Any], let current = CGRect(dictionaryRepresentation: b as CFDictionary) else { return false }
              return current == frame
          }) else { throw InputError("STALE_OBSERVATION: target process, window, geometry, or observation age changed; inspect again") }
}
struct InputError: Error, CustomStringConvertible { let description: String; init(_ s: String) { description = s } }
func app() throws -> NSRunningApplication {
    guard let a = NSRunningApplication.runningApplications(withBundleIdentifier: targetBundle).first else { throw InputError("set.a.light 3D is not running") }
    return a
}
func front() -> Bool { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == targetBundle }
func assertFront() throws { try checkObservation(); if !front() { throw InputError("FOCUS_LOST: frontmost app is not set.a.light 3D") } }
func pause(_ seconds: Double) { RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds)) }
func focus() throws {
    try assertDisplay()
    let a = try app()
    if !front() { _ = a.activate(options: []) }
    let deadline = Date(timeIntervalSinceNow: 2)
    while !front() && Date() < deadline { pause(0.05) }
    try assertFront()
    try raiseTargetMainWindow()
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
            "screenRecordingAllowed": CGPreflightScreenCaptureAccess(), "helperVersion": "0.4.0",
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
        try checkCancellation()
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
    guard width.rounded() == width, width >= 640, width <= 4096 else { throw InputError("maxWidth must be an integer from 640 to 4096") }
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
    let geometry: [String: Any] = ["X": bounds.minX, "Y": bounds.minY, "Width": bounds.width, "Height": bounds.height]
    let visible = displays().compactMap { display -> [String: CGFloat]? in
        guard let b = display["bounds"] as? [String: Any], let r = CGRect(dictionaryRepresentation: b as CFDictionary) else { return nil }
        let part = bounds.intersection(r)
        return part.isNull ? nil : ["X": part.minX, "Y": part.minY, "Width": part.width, "Height": part.height]
    }
    var result: [String: Any] = ["windowId": window.windowID, "title": window.title ?? "", "bundleId": targetBundle,
            "capturedAt": ISO8601DateFormatter().string(from: Date()),
            "bounds": geometry,
            "observation": ["pid": pid, "windowId": window.windowID, "bounds": geometry, "capturedAtMs": Date().timeIntervalSince1970 * 1000],
            "onscreenRegions": visible,
            "imageHash": SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined(),
            "imageWidth": image.width, "imageHeight": image.height,
            "coordinateMapping": ["originX": bounds.minX, "originY": bounds.minY,
                                  "pointsPerPixelX": bounds.width / Double(image.width),
                                  "pointsPerPixelY": bounds.height / Double(image.height)],
            "coordinateFormula": "screenX = originX + imageX * pointsPerPixelX; screenY = originY + imageY * pointsPerPixelY",
            "imageBase64": png.base64EncodedString()]
    if p["ocr"] as? Bool == true {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        request.minimumTextHeight = 0.006
        try VNImageRequestHandler(cgImage: image).perform([request])
        let sx = bounds.width / Double(image.width), sy = bounds.height / Double(image.height)
        result["texts"] = (request.results ?? []).compactMap { observation -> [String: Any]? in
            guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.25 else { return nil }
            let box = observation.boundingBox
            let x = box.minX * Double(image.width), y = (1 - box.maxY) * Double(image.height)
            let w = box.width * Double(image.width), h = box.height * Double(image.height)
            var bright = 0, gold = 0
            let markerX = max(0, Int(x - 18 / sx)), markerY = max(0, Int(y - 2 / sy))
            let markerW = max(1, Int(16 / sx)), markerH = max(1, Int(h + 4 / sy))
            for py in markerY..<min(image.height, markerY + markerH) {
                for px in markerX..<min(image.width, markerX + markerW) {
                    guard let c = bitmap.colorAt(x: px, y: py)?.usingColorSpace(.deviceRGB) else { continue }
                    if min(c.redComponent, c.greenComponent, c.blueComponent) > 0.60 { bright += 1 }
                    if c.redComponent > 0.55 && c.greenComponent > 0.40 && c.blueComponent < 0.35 { gold += 1 }
                }
            }
            return ["text": candidate.string, "confidence": candidate.confidence,
                    "rect": ["x": x * sx, "y": y * sy, "width": w * sx, "height": h * sy],
                    "screenX": bounds.minX + (x + w / 2) * sx, "screenY": bounds.minY + (y + h / 2) * sy,
                    "leftMarkerBrightPixels": bright, "leftMarkerGoldPixels": gold]
        }
        var texts = result["texts"] as? [[String: Any]] ?? []
        if let transform = texts.first(where: { ($0["text"] as? String ?? "").lowercased().contains("transform") && (($0["rect"] as? [String:Double])?["x"] ?? 999) < 120 }),
           let ty = (transform["rect"] as? [String:Double])?["y"] {
            for i in texts.indices {
                guard let r = texts[i]["rect"] as? [String:Double], let x=r["x"], let y=r["y"],
                      x>90, x<185, y>ty-50, y<ty-8,
                      let decoded = segmentedNumber(bitmap, bounds, r) else { continue }
                texts[i]["text"]=decoded; texts[i]["confidence"]=0.99
                texts[i]["recognitionMethod"]="seven-segment pixel readback"
            }
        }
        result["texts"] = texts
        result["sliders"] = detectSliders(bitmap, bounds, texts)
        if p["includeImage"] as? Bool != true { result.removeValue(forKey: "imageBase64") }
    }
    return result
}
// The gold power display uses a seven-segment font. General OCR confuses 5/6
// and 8/9; classify its illuminated segments without guessing from the request.
func segmentedNumber(_ bitmap:NSBitmapImageRep, _ bounds:CGRect, _ r:[String:Double]) -> String? {
    let sx:Double=Double(bitmap.pixelsWide)/Double(bounds.width)
    let sy:Double=Double(bitmap.pixelsHigh)/Double(bounds.height)
    let rx:Double=r["x"] ?? 0, ry:Double=r["y"] ?? 0
    let rw:Double=r["width"] ?? 0, rh:Double=r["height"] ?? 0
    let left:Int=max(0,Int((rx-4)*sx))
    let right:Int=min(bitmap.pixelsWide-1,Int((rx+rw+4)*sx))
    let top:Int=max(0,Int((ry-4)*sy))
    let bottom:Int=min(bitmap.pixelsHigh-1,Int((ry+rh+4)*sy))
    guard left<right,top<bottom,right-left<180,bottom-top<100 else{return nil}
    func ink(_ x:Int,_ y:Int)->Bool {
        guard let c=bitmap.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB) else{return false}
        return c.redComponent>0.45 && c.greenComponent>0.3 && c.blueComponent<0.4 && c.redComponent>c.blueComponent*1.5
    }
    var runs=[(Int,Int)](), start:Int?
    for x in left...right {
        let hit=(top...bottom).contains{ink(x,$0)}
        if hit && start==nil {start=x}
        if !hit,let a=start {runs.append((a,x-1));start=nil}
    }
    if let a=start {runs.append((a,right))}
    guard (3...4).contains(runs.count) else{return nil}
    let zones:[(Double,Double,Double,Double)]=[(0.25,0.02,0.75,0.13),(0.8,0.18,0.98,0.4),(0.8,0.6,0.98,0.82),(0.25,0.87,0.75,0.98),(0.02,0.6,0.2,0.82),(0.02,0.18,0.2,0.4),(0.25,0.43,0.75,0.56)]
    let digits=[0x3f:"0",0x06:"1",0x5b:"2",0x4f:"3",0x66:"4",0x6d:"5",0x7d:"6",0x07:"7",0x7f:"8",0x6f:"9"]
    var output=""
    for (a,b) in runs {
        let ys=(top...bottom).filter{y in (a...b).contains{ink($0,y)}}
        guard let t=ys.first,let d=ys.last else{return nil}
        let w:Double=Double(b-a)
        let h:Double=Double(d-t)
        if h<4*sy && w<4*sx {output+=".";continue}
        guard h>=5*sy else{return nil}
        if w/h<0.35 {output+="1";continue}
        var mask=0
        for (index,z) in zones.enumerated() {
            let xs:ClosedRange<Int>=Int(Double(a)+w*z.0)...Int(Double(a)+w*z.2)
            let ys:ClosedRange<Int>=Int(Double(t)+h*z.1)...Int(Double(t)+h*z.3)
            var hits=0
            for y in ys {for x in xs {if ink(x,y){hits+=1}}}
            if Double(hits)/Double(xs.count*ys.count)>0.20 {mask |= 1<<index}
        }
        guard let digit=digits[mask] else{return nil};output+=digit
    }
    guard output.range(of:"^\\d{1,2}\\.\\d$",options:.regularExpression) != nil else{return nil}
    return output
}
func detectSliders(_ bitmap: NSBitmapImageRep, _ bounds: CGRect, _ texts: [[String: Any]]) -> [[String: Any]] {
    let sx = CGFloat(bitmap.pixelsWide) / bounds.width, sy = CGFloat(bitmap.pixelsHigh) / bounds.height
    func rgb(_ x: Double, _ y: Double) -> (Double, Double, Double) {
        let px = Int(x * sx), py = Int(y * sy)
        guard px >= 0, py >= 0, px < bitmap.pixelsWide, py < bitmap.pixelsHigh,
              let c = bitmap.colorAt(x: px, y: py)?.usingColorSpace(.deviceRGB) else { return (0, 0, 0) }
        return (c.redComponent, c.greenComponent, c.blueComponent)
    }
    func gray(_ x: Double, _ y: Double) -> Bool {
        let (r,g,b) = rgb(x,y)
        return min(r,g,b) > 0.30 && max(r,g,b) - min(r,g,b) < 0.15
    }
    func solid(_ x: Double, _ y: Double) -> Bool {
        let (r,g,b) = rgb(x,y)
        return min(r,g,b) > 0.29 || (r > 0.50 && g > 0.40 && b < 0.40)
    }
    func rect(_ t: [String: Any]) -> [String: Double] {
        let raw = t["rect"] as? [String: Any] ?? [:]
        return raw.compactMapValues { ($0 as? NSNumber)?.doubleValue ?? ($0 as? CGFloat).map(Double.init) }
    }
    func point(_ x: Double, _ y: Double) -> [String: Double] { ["x": bounds.minX+x, "y": bounds.minY+y] }
    var sliders = [[String: Any]]()
    if let transform = texts.first(where: { ($0["text"] as? String ?? "").lowercased().contains("transform") && (rect($0)["x"] ?? 999) < 120 }) {
        let ty = rect(transform)["y"] ?? 0
        let candidates = texts.filter { t in
            let r = rect(t), text = t["text"] as? String ?? ""
            return Double(text) != nil && (r["x"] ?? 0) > 90 && (r["x"] ?? 999) < 185 && (r["y"] ?? 0) > ty-50 && (r["y"] ?? 999) < ty-8
        }
        if candidates.count == 1, let value = candidates.first {
            let r = rect(value), cx = (r["x"] ?? 0)+(r["width"] ?? 0)/2, cy = r["y"] ?? 0
            var best = (length: 0, x: 0.0, start: 0, end: 0)
            for x in Int(cx-8)...Int(cx+8) {
                var start = 0
                for y in max(0,Int(cy-160))...Int(cy-2) {
                    if solid(Double(x),Double(y)) { if start == 0 { start = y } }
                    else if start != 0 {
                        if y-start > best.length { best = (y-start,Double(x),start,y-1) }
                        start = 0
                    }
                }
                if start != 0 && Int(cy-1)-start > best.length { best = (Int(cy-1)-start,Double(x),start,Int(cy-2)) }
            }
            if best.length > 60 {
                var thumbRows = [Int]()
                for y in best.start...best.end {
                    if gray(best.x-4,Double(y)) && gray(best.x+4,Double(y)) { thumbRows.append(y) }
                }
                if !thumbRows.isEmpty, thumbRows.count <= 18 {
                    let thumb = Double(thumbRows.reduce(0,+))/Double(thumbRows.count)
                    var toggles = [[String: Any]]()
                    let centerY = cy + (r["height"] ?? 10) / 2
                    for (id, dx, dy) in [("light_on", -109.0, 0.0), ("solo", -74.0, 0.0), ("tripod_visible", -41.0, 0.0), ("target_lock", -74.0, -30.0)] {
                        var gold = 0, visible = 0
                        let x = cx+dx, y = centerY+dy
                        for py in Int(y-8)...Int(y+8) {
                            for px in Int(x-8)...Int(x+8) {
                                let (red,green,blue) = rgb(Double(px),Double(py))
                                if max(red,green,blue) > 0.35 { visible += 1 }
                                if red > 0.55 && green > 0.40 && blue < 0.40 { gold += 1 }
                            }
                        }
                        if visible > 5 { toggles.append(["id":id,"value":gold > 4,"point":point(x,y)]) }
                    }
                    sliders.append(["id":"power", "axis":"vertical", "minPoint":point(best.x,Double(best.end)),
                                    "maxPoint":point(best.x,Double(best.start)), "thumb":point(best.x,thumb), "toggles":toggles])
                }
            }
        }
    }
    var temperatureIndex = 0
    for label in texts where (label["text"] as? String ?? "").lowercased() == "color temperature" && (rect(label)["x"] ?? 999) < 150 {
        let r = rect(label), lx = r["x"] ?? 0, ly = r["y"] ?? 0, lh = r["height"] ?? 10
        let values = texts.filter { t in abs((rect(t)["y"] ?? 0)-ly) < 8 && (rect(t)["x"] ?? 0) > lx+(r["width"] ?? 0) && (t["text"] as? String ?? "").hasSuffix("K") }
        guard let value = values.first else { continue }
        let vr = rect(value), right = (vr["x"] ?? 0)+(vr["width"] ?? 0)
        var bestY = 0, bestCount = 0
        for y in Int(ly+lh+4)...Int(ly+lh+24) {
            var count = 0
            for x in Int(lx)...Int(right) {
                let (red,green,blue) = rgb(Double(x),Double(y))
                if max(red,green,blue)-min(red,green,blue) > 0.06 { count += 1 }
            }
            if count > bestCount { bestCount = count; bestY = y }
        }
        if bestCount > 100 {
            var xs = [Int]()
            for x in Int(lx)...Int(right) {
                if gray(Double(x),Double(bestY)-5) || gray(Double(x),Double(bestY)+5) { xs.append(x) }
            }
            if !xs.isEmpty, xs.count < 20 {
                let thumb = Double(xs.reduce(0,+))/Double(xs.count)
                sliders.append(["id":temperatureIndex == 0 ? "color_temperature" : "modeling_temperature", "axis":"horizontal",
                                "minPoint":point(lx,Double(bestY)), "maxPoint":point(right,Double(bestY)), "thumb":point(thumb,Double(bestY))])
            }
        }
        temperatureIndex += 1
    }
    return sliders
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
    try checkObservation()
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
    // WindowServer supplies the front-to-back window order even when Unity's
    // Accessibility provider stalls. Never post through an overlapping window.
    let entries = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    for window in entries {
        guard (window[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
              let raw = window[kCGWindowBounds as String] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: raw as CFDictionary), rect.contains(point) else { continue }
        let pid = window[kCGWindowOwnerPID as String] as? Int32 ?? -1
        let detail: [String: Any] = ["pid": pid, "windowId": window[kCGWindowNumber as String] ?? 0,
                                    "method": "WindowServer topmost visible window"]
        // Floating overlays and the Dock canvas may pass input through.
        // Require AX to confirm the actual input recipient; never skip an
        // overlapping window solely because of its layer or application name.
        if pid != targetPID, (window[kCGWindowLayer as String] as? Int ?? 0) > 0 {
            let system = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(system, 1)
            var element: AXUIElement?
            let error = AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &element)
            if error == .success, let element = element {
                var recipient: pid_t = -1
                if AXUIElementGetPid(element, &recipient) == .success {
                    return (recipient == targetPID, ["pid":recipient,"method":"AX input recipient beneath overlay"])
                }
            }
            return (false, ["pid":pid,"method":"Overlay AX hit test","axError":error.rawValue])
        }
        return (pid == targetPID, detail)
    }
    return (false, ["pid": -1, "method": "WindowServer", "reason": "No visible window at point"])
}

func clickHID(_ p: [String: Any], focusBefore: Bool = true) throws -> [String: Any] {
    let point = CGPoint(x: try number(p, "x"), y: try number(p, "y"))
    let duration = (p["durationMs"] == nil ? 250 : try number(p, "durationMs")) / 1000
    let count = p["clickCount"] as? Int ?? 1
    guard (1...2).contains(count) else { throw InputError("clickCount must be 1 or 2") }
    guard duration >= 0.02 && duration <= 1 else { throw InputError("durationMs must be 20...1000") }
    guard AXIsProcessTrusted() else { throw InputError("Accessibility access is required for hit testing; no access was requested") }
    try assertPosting()
    if focusBefore { try focus(); pause(0.10) }
    else { try assertFront() }
    try validatePoint(point); try assertFront()
    let pid = try app().processIdentifier
    let initialHit = hitTest(point, targetPID: pid)
    guard initialHit.0 else { return ["clicked": false, "stage": "before_pointer_move", "hit": initialHit.1, "reason": "Input recipient is not set.a.light; no mouse event was posted"] }
    guard let source = CGEventSource(stateID: .hidSystemState),
          let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left),
          let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
          let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else { throw InputError("Could not construct HID mouse events") }
    move.flags = []; down.flags = []; up.flags = []
    down.setIntegerValueField(.mouseEventClickState, value: 1)
    up.setIntegerValueField(.mouseEventClickState, value: 1)
    guard CGWarpMouseCursorPosition(point) == .success else { throw InputError("Cursor positioning failed") }
    move.post(tap: .cghidEventTap); pause(0.20)
    try assertFront()
    let finalHit = hitTest(point, targetPID: pid)
    guard finalHit.0 else { return ["clicked": false, "stage": "before_mouse_down", "hit": finalHit.1, "reason": "AX hit changed after pointer move; no click was posted"] }
    guard !CGEventSource.buttonState(.combinedSessionState, button: .left) else { throw InputError("Mouse button already held; no input sent") }
    for index in 1...count {
        try assertFront()
        down.setIntegerValueField(.mouseEventClickState, value: Int64(index))
        up.setIntegerValueField(.mouseEventClickState, value: Int64(index))
        down.post(tap: .cghidEventTap); pause(duration)
        // Always release after sending down, including cancellation or focus loss.
        up.post(tap: .cghidEventTap); pause(0.06)
    }
    pause(0.10)
    return ["clicked": true, "method": "HID", "point": ["x": point.x, "y": point.y], "hit": finalHit.1, "frontmostAfter": front(), "uiEffectVerified": false]
}
func scrollHID(_ p: [String: Any], focusBefore: Bool = true) throws -> [String: Any] {
    let point = CGPoint(x: try number(p, "x"), y: try number(p, "y"))
    let delta = try number(p, "deltaY")
    guard delta.rounded() == delta, delta != 0, abs(delta) <= 2000 else { throw InputError("deltaY must be a nonzero integer from -2000 to 2000; positive scrolls up, negative scrolls down") }
    guard AXIsProcessTrusted() else { throw InputError("Accessibility access is required for hit testing; no access was requested") }
    try assertPosting()
    if focusBefore { try focus(); pause(0.10) }
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
    let via: CGPoint? = p["viaX"] == nil ? nil : CGPoint(x: try number(p, "viaX"), y: try number(p, "viaY"))
    func position(_ t: CGFloat) -> CGPoint {
        if let v = via {
            if t < 0.35 { return CGPoint(x: start.x+(v.x-start.x)*t/0.35, y: start.y+(v.y-start.y)*t/0.35) }
            return CGPoint(x: v.x+(end.x-v.x)*(t-0.35)/0.65, y: v.y+(end.y-v.y)*(t-0.35)/0.65)
        }
        return CGPoint(x: start.x+(end.x-start.x)*t, y: start.y+(end.y-start.y)*t)
    }
    let duration = (p["durationMs"] == nil ? 500 : try number(p, "durationMs")) / 1000
    guard duration >= 0.2 && duration <= 2 else { throw InputError("durationMs must be 200...2000") }
    guard AXIsProcessTrusted() else { throw InputError("Accessibility access is required for hit testing; no access was requested") }
    try assertPosting()
    if focusBefore { try focus(); pause(0.10) }
    else { try assertFront() }
    try validatePoint(start); try validatePoint(end); try assertFront()
    let pid = try app().processIdentifier
    let startHit = hitTest(start, targetPID: pid)
    let endHit = hitTest(end, targetPID: pid)
    guard startHit.0 && endHit.0 else { return ["dragged": false, "stage": "before_pointer_move", "startHit": startHit.1, "endHit": endHit.1, "reason": "Both endpoints must hit set.a.light; no mouse event was posted"] }
    let steps = max(10, min(60, Int(duration / 0.02)))
    // Validate the complete path against one captured geometry snapshot.
    // Avoid an expensive AX/window-server round trip for every interpolated pixel.
    let pathWindows = try windows().compactMap { w -> CGRect? in
        guard let b = w["bounds"] as? [String: Any] else { return nil }
        return CGRect(dictionaryRepresentation: b as CFDictionary)
    }
    let pathDisplays = displays().compactMap { d -> CGRect? in
        guard let b = d["bounds"] as? [String: Any] else { return nil }
        return CGRect(dictionaryRepresentation: b as CFDictionary)
    }
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps)
        let point = position(t)
        guard pathWindows.contains(where: { $0.contains(point) }), pathDisplays.contains(where: { $0.contains(point) }) else { throw InputError("Drag path leaves the visible target windows or displays") }
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
        if cancelled() || !front() { interrupted = true; break }
        let t = CGFloat(i) / CGFloat(steps)
        let point = position(t)
        if i == 1 || i == steps || i % 6 == 0 {
            do { try validatePoint(point) } catch { interrupted = true; break }
            if !hitTest(point, targetPID: pid).0 { interrupted = true; break }
        }
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
let keyCodes: [String: CGKeyCode] = ["a":0,"s":1,"d":2,"f":3,"h":4,"g":5,"z":6,"x":7,"c":8,"v":9,"b":11,"q":12,"w":13,"e":14,"r":15,"y":16,"t":17,"1":18,"2":19,"3":20,"4":21,"6":22,"5":23,"equal":24,"9":25,"7":26,"minus":27,"8":28,"0":29,"rightbracket":30,"o":31,"u":32,"leftbracket":33,"i":34,"p":35,"return":36,"enter":76,"l":37,"j":38,"apostrophe":39,"k":40,"semicolon":41,"backslash":42,"comma":43,"slash":44,"n":45,"m":46,"period":47,"tab":48,"space":49,"backspace":51,"escape":53,"delete":117,"home":115,"end":119,"pageup":116,"pagedown":121,"left":123,"right":124,"down":125,"up":126]
func keySpec(_ raw: String) throws -> (CGKeyCode, CGEventFlags) {
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
    return (code, flags)
}
func keypress(_ p: [String: Any]) throws -> [String: Any] {
    guard let raw = p["key"] as? String else { throw InputError("Expected key string, e.g. cmd+a or return") }
    let (code, flags) = try keySpec(raw)
    try assertPosting(); try assertFront()
    let pid = try app().processIdentifier
    guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true), let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else { throw InputError("Could not construct key event") }
    down.flags = flags; up.flags = flags
    if p["transport"] as? String == "hid" {
        // Unity polls physical modifier state for scene shortcuts. Flags on
        // Return alone work in Cocoa dialogs, but do not trigger its render key.
        let modifiers: [(CGEventFlags,CGKeyCode)] = [(.maskControl,59),(.maskAlternate,58),(.maskShift,56),(.maskCommand,55)]
        var held = [(CGEventFlags,CGKeyCode)]()
        var current = CGEventFlags()
        defer {
            for (flag,key) in held.reversed() {
                current.remove(flag)
                if let release = CGEvent(keyboardEventSource:nil,virtualKey:key,keyDown:false) {
                    release.flags=current; release.post(tap:.cghidEventTap)
                }
            }
        }
        for (flag,key) in modifiers where flags.contains(flag) {
            try assertFront()
            guard let press = CGEvent(keyboardEventSource:nil,virtualKey:key,keyDown:true) else { throw InputError("Could not construct modifier event") }
            current.insert(flag); press.flags=current; press.post(tap:.cghidEventTap)
            held.append((flag,key)); pause(0.04)
        }
        try assertFront()
        down.post(tap: .cghidEventTap); pause(0.10); up.post(tap: .cghidEventTap)
    } else {
        down.postToPid(pid); pause(0.06); up.postToPid(pid)
    }
    pause(0.10)
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
func axValue(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
    AXUIElementSetMessagingTimeout(element, 0.3)
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
    return value
}
func dialogElements() throws -> [AXUIElement] {
    guard AXIsProcessTrusted() else { throw InputError("Accessibility access is required") }
    let root = AXUIElementCreateApplication(try app().processIdentifier)
    AXUIElementSetMessagingTimeout(root, 0.3)
    let windows = axValue(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
    var pending = windows.map { ($0, 0) }, result = [AXUIElement]()
    let deadline = Date(timeIntervalSinceNow: 4)
    while !pending.isEmpty && result.count < 200 && Date() < deadline {
        try checkCancellation()
        let (element, depth) = pending.removeFirst()
        result.append(element)
        if depth < 18 {
            for child in (axValue(element, kAXChildrenAttribute) as? [AXUIElement] ?? []) { pending.append((child, depth + 1)) }
        }
    }
    return result
}
func dialogIdentifier(_ element:AXUIElement) -> String {
    // NSSavePanel overwrite alerts do not use a stable identifier on every
    // macOS release. Normalize only their exact, app-scoped Replace button.
    if axValue(element,kAXRoleAttribute) as? String == kAXButtonRole,
       axValue(element,kAXTitleAttribute) as? String == "Replace" { return "ReplaceButton" }
    return axValue(element,kAXIdentifierAttribute) as? String ?? ""
}
func dialogState() throws -> [String: Any] {
    let elements = try dialogElements()
    let fields: [[String: Any]] = elements.compactMap { element in
        let role = axValue(element, kAXRoleAttribute) as? String ?? ""
        guard [kAXTextFieldRole, kAXButtonRole, kAXSheetRole, "AXDialog"].contains(role) else { return nil }
        return ["role": role, "identifier": dialogIdentifier(element),
                "title": axValue(element, kAXTitleAttribute) as? String ?? "",
                "value": axValue(element, kAXValueAttribute) as? String ?? "",
                "enabled": axValue(element, kAXEnabledAttribute) as? Bool ?? false]
    }
    return ["elements": fields]
}
func dialogAction(_ p: [String: Any]) throws -> [String: Any] {
    try assertFront()
    guard let identifier = p["identifier"] as? String,
          ["saveAsNameTextField", "PathTextField", "OKButton", "CancelButton", "ReplaceButton"].contains(identifier) else { throw InputError("Dialog identifier is not allowed") }
    let matches = try dialogElements().filter { dialogIdentifier($0) == identifier }
    guard matches.count == 1, let element = matches.first else { throw InputError("Dialog control is missing or ambiguous") }
    guard axValue(element, kAXEnabledAttribute) as? Bool == true else { throw InputError("Dialog control is disabled") }
    let role = axValue(element, kAXRoleAttribute) as? String ?? ""
    if let value = p["value"] as? String {
        guard role == kAXTextFieldRole, value.utf16.count <= 4096 else { throw InputError("Expected a text field and bounded value") }
        guard AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFString) == .success else { throw InputError("Dialog text field rejected value") }
    } else {
        guard role == kAXButtonRole else { throw InputError("Expected a dialog button") }
        let pressed=AXUIElementPerformAction(element,kAXPressAction as CFString)
        // Save can synchronously open an overwrite sheet and exceed the AX
        // messaging timeout. Do not repeat the press: let the caller inspect
        // the resulting dialog/file before deciding whether it completed.
        pause(0.15)
        var state=try dialogState()
        let replacementVisible = identifier == "OKButton" && (state["elements"] as? [[String:Any]] ?? []).contains { $0["identifier"] as? String == "ReplaceButton" }
        guard pressed == .success || pressed == .cannotComplete || replacementVisible else { throw InputError("Dialog button rejected press: \(pressed.rawValue)") }
        state["actionAcknowledged"] = pressed == .success
        state["axResult"] = pressed.rawValue
        state["buttonRequested"] = identifier
        return state
    }
    pause(0.15)
    return try dialogState()
}
func dispatch(_ request: [String: Any], allowBatch: Bool = true, focusBefore: Bool = true) throws -> [String: Any] {
    try checkCancellation()
    guard let command = request["command"] as? String else { throw InputError("Missing command") }
    switch command {
    case "status": return try status()
    case "dialog_state": return try dialogState()
    case "dialog_action": return try dialogAction(request)
    case "screenshot": return try screenshot(request)
    case "inspect_ui":
        var options = request; options["ocr"] = true; options["maxWidth"] = 4096
        return try screenshot(options)
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
        guard allowBatch, let actions = request["actions"] as? [[String: Any]], !actions.isEmpty, actions.count <= 160 else { throw InputError("batch requires 1..160 non-nested actions") }
        guard actions.reduce(0, { $0 + (($1["text"] as? String)?.utf16.count ?? 0) }) <= 4096 else { throw InputError("Combined batch text exceeds 4096 UTF-16 units") }
        // Reject every malformed step before dispatching the first input event.
        for action in actions {
            guard let command = action["command"] as? String, ["focus", "click", "click_hid", "scroll_hid", "drag_hid", "keypress", "type_text"].contains(command) else { throw InputError("Batch action not allowed") }
            if command == "keypress" { guard let key = action["key"] as? String else { throw InputError("Expected key string") }; _ = try keySpec(key) }
            if command == "type_text" { guard let text = action["text"] as? String, text.utf16.count <= 4096 else { throw InputError("Invalid batch text") } }
            if ["click", "click_hid", "scroll_hid"].contains(command) { _ = try number(action, "x"); _ = try number(action, "y") }
            if command == "scroll_hid" { let d = try number(action, "deltaY"); guard d.rounded() == d, d != 0, abs(d) <= 2000 else { throw InputError("Invalid scroll delta") } }
            if command == "drag_hid" { for field in ["fromX", "fromY", "toX", "toY"] { _ = try number(action, field) } }
            if action["durationMs"] != nil { let d = try number(action, "durationMs"); guard command == "drag_hid" ? (200...2000).contains(d) : (20...1000).contains(d) else { throw InputError("Invalid duration") } }
        }
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
    signal(SIGTERM) { _ in cancellationSignal = 1 }
    signal(SIGINT) { _ in cancellationSignal = 1 }
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    let data: Data
    if CommandLine.arguments.count == 2 { data = Data(CommandLine.arguments[1].utf8) }
    else { data = FileHandle.standardInput.readDataToEndOfFile() }
    guard data.count <= 65536, let request = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw InputError("Expected JSON object under 64 KiB") }
    expectedObservation = request["observation"] as? [String: Any]
    try checkObservation()
    let result = try dispatch(request)
    let output = try JSONSerialization.data(withJSONObject: ["ok": true, "result": result], options: [.sortedKeys])
    FileHandle.standardOutput.write(output); FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    let output = try! JSONSerialization.data(withJSONObject: ["ok": false, "error": String(describing: error)], options: [.sortedKeys])
    FileHandle.standardOutput.write(output); FileHandle.standardOutput.write(Data("\n".utf8)); exit(1)
}
