import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// Local, user-authorized filming helper. No app data or source modification.
let args = Array(CommandLine.arguments.dropFirst())
let allowedBundles = ["com.oontz.SnipSnipSnip", "com.apple.Preview", "com.apple.TextEdit"]
func value(_ e: AXUIElement, _ k: String) -> CFTypeRef? {
    var v: CFTypeRef?; AXUIElementCopyAttributeValue(e, k as CFString, &v); return v
}
func windows(_ pid: pid_t) -> [AXUIElement] {
    value(AXUIElementCreateApplication(pid), kAXWindowsAttribute) as? [AXUIElement] ?? []
}
func point(_ e: AXUIElement) -> CGPoint {
    var p = CGPoint.zero
    if let v = value(e, kAXPositionAttribute), CFGetTypeID(v) == AXValueGetTypeID() { AXValueGetValue(v as! AXValue, .cgPoint, &p) }
    return p
}
func size(_ e: AXUIElement) -> CGSize {
    var s = CGSize.zero
    if let v = value(e, kAXSizeAttribute), CFGetTypeID(v) == AXValueGetTypeID() { AXValueGetValue(v as! AXValue, .cgSize, &s) }
    return s
}
func tree(_ e: AXUIElement, _ depth: Int = 0) {
    guard depth < 13 else { return }
    let role=value(e,kAXRoleAttribute) as? String ?? ""
    let title=value(e,kAXTitleAttribute) as? String ?? ""
    let desc=value(e,kAXDescriptionAttribute) as? String ?? ""
    let v=value(e,kAXValueAttribute).map { String(describing:$0).prefix(220) } ?? ""
    print(String(repeating:" ",count:depth),role,title,desc,"value=\(v)","frame=\(point(e)) \(size(e))")
    for c in value(e,kAXChildrenAttribute) as? [AXUIElement] ?? [] { tree(c,depth+1) }
}
func app(_ pid: pid_t) -> NSRunningApplication {
    guard let app = NSRunningApplication(processIdentifier: pid), allowedBundles.contains(app.bundleIdentifier ?? "") else { fatalError("Target is not an approved filming app") }; return app
}
func findElement(_ root: AXUIElement, _ match: (AXUIElement) -> Bool) -> AXUIElement? {
    if match(root) { return root }
    for child in value(root,kAXChildrenAttribute) as? [AXUIElement] ?? [] {
        if let found=findElement(child,match) { return found }
    }
    return nil
}
func mouse(_ type: CGEventType, _ p: CGPoint) {
    let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)!
    event.post(tap: .cghidEventTap)
}
func move(_ end: CGPoint, _ seconds: Double, dragging: Bool = false) {
    let start = CGEvent(source:nil)!.location
    let steps = max(1, Int(seconds * 60))
    for i in 1...steps {
        let t = Double(i)/Double(steps), ease = t*t*(3-2*t)
        mouse(dragging ? .leftMouseDragged : .mouseMoved, CGPoint(x:start.x+(end.x-start.x)*ease,y:start.y+(end.y-start.y)*ease))
        Thread.sleep(forTimeInterval:seconds/Double(steps))
    }
}
func flags(_ list: [String]) -> CGEventFlags {
    var f = CGEventFlags()
    for s in list { if s == "cmd" { f.insert(.maskCommand) }; if s == "shift" { f.insert(.maskShift) }; if s == "alt" { f.insert(.maskAlternate) }; if s == "ctrl" { f.insert(.maskControl) } }
    return f
}
func action(_ a: [String:Any]) {
    let op = a["op"] as! String
    let x = (a["x"] as? Double) ?? 0, y = (a["y"] as? Double) ?? 0
    let duration = (a["duration"] as? Double) ?? 0.55
    switch op {
    case "move": move(CGPoint(x:x,y:y), duration)
    case "click":
        move(CGPoint(x:x,y:y),duration); mouse(.leftMouseDown,CGPoint(x:x,y:y)); Thread.sleep(forTimeInterval:0.08); mouse(.leftMouseUp,CGPoint(x:x,y:y))
    case "drag":
        let start = CGPoint(x:(a["fromX"] as! Double),y:(a["fromY"] as! Double))
        move(start,0.35); mouse(.leftMouseDown,start); Thread.sleep(forTimeInterval:0.12); move(CGPoint(x:x,y:y),duration,dragging:true); mouse(.leftMouseUp,CGPoint(x:x,y:y))
    case "key":
        let code = CGKeyCode(a["code"] as! Int), f = flags(a["flags"] as? [String] ?? [])
        for down in [true,false] { let e=CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:down)!; e.flags=f; if let pid=a["pid"] as? Int { e.postToPid(pid_t(pid)) } else { e.post(tap:.cghidEventTap) }; Thread.sleep(forTimeInterval:0.04) }
    case "text":
        let text = a["text"] as! String
        for char in text {
            let utf16 = Array(String(char).utf16)
            for down in [true,false] { let e=CGEvent(keyboardEventSource:nil,virtualKey:0,keyDown:down)!; e.keyboardSetUnicodeString(stringLength:utf16.count,unicodeString:utf16); if let pid=a["pid"] as? Int { e.postToPid(pid_t(pid)) } else { e.post(tap:.cghidEventTap) } }
            Thread.sleep(forTimeInterval:(a["interval"] as? Double) ?? 0.055)
        }
    case "frame":
        let pid = pid_t(a["pid"] as! Int), targetApp = app(pid)
        let title = a["title"] as! String
        guard let w = windows(pid).first(where: {(value($0,kAXTitleAttribute) as? String ?? "") == title}) else { fatalError("No exact window title: \(title)") }
        var p=CGPoint(x:x,y:y), s=CGSize(width:a["width"] as! Double,height:a["height"] as! Double)
        AXUIElementSetAttributeValue(w,kAXPositionAttribute as CFString,AXValueCreate(.cgPoint,&p)!)
        AXUIElementSetAttributeValue(w,kAXSizeAttribute as CFString,AXValueCreate(.cgSize,&s)!)
        targetApp.activate(options:[]); AXUIElementPerformAction(w,kAXRaiseAction as CFString)
    case "activate": _ = app(pid_t(a["pid"] as! Int)).activate(options:[])
    case "press":
        let pid=pid_t(a["pid"] as! Int); _=app(pid)
        let name=a["name"] as! String
        let root=AXUIElementCreateApplication(pid)
        guard let e=findElement(root,{ (value($0,kAXTitleAttribute) as? String)==name || (value($0,kAXDescriptionAttribute) as? String)==name }) else { fatalError("Missing UI element: \(name)") }
        let result=AXUIElementPerformAction(e,kAXPressAction as CFString)
        print("press \(name): \(result.rawValue)")
    case "adjust":
        let pid=pid_t(a["pid"] as! Int); _=app(pid)
        let name=a["name"] as! String
        guard let e=findElement(AXUIElementCreateApplication(pid),{ (value($0,kAXTitleAttribute) as? String)==name || (value($0,kAXDescriptionAttribute) as? String)==name }) else { fatalError("Missing UI element: \(name)") }
        var available: CFArray?
        AXUIElementCopyActionNames(e, &available)
        let actionName=(a["direction"] as? String)=="decrement" ? kAXDecrementAction : kAXIncrementAction
        guard (available as? [String] ?? []).contains(actionName) else { fatalError("Adjustment not exposed by \(name)") }
        for _ in 0..<(a["count"] as? Int ?? 1) {
            let result=AXUIElementPerformAction(e,actionName as CFString)
            guard result == .success else { fatalError("Adjustment failed: \(result.rawValue)") }
            Thread.sleep(forTimeInterval:(a["interval"] as? Double) ?? 0.08)
        }
    case "select-text":
        let pid=pid_t(a["pid"] as! Int); _=app(pid)
        let text=a["text"] as! String
        guard let e=findElement(AXUIElementCreateApplication(pid),{ (value($0,kAXRoleAttribute) as? String)=="AXTextArea" && ((value($0,kAXValueAttribute) as? String)?.contains(text) ?? false) }), let s=value(e,kAXValueAttribute) as? String else { fatalError("Text not found") }
        let r=(s as NSString).range(of:text)
        var selected=CFRange(location:r.location,length:r.length)
        AXUIElementSetAttributeValue(e,kAXFocusedAttribute as CFString,kCFBooleanTrue)
        AXUIElementSetAttributeValue(e,kAXSelectedTextRangeAttribute as CFString,AXValueCreate(.cfRange,&selected)!)
    default: fatalError("Unknown action")
    }
}
if args.first == "tree", args.count == 3 {
    let pid=pid_t(args[1])!; _=app(pid)
    if let w=windows(pid).first(where:{(value($0,kAXTitleAttribute) as? String ?? "") == args[2]}) { tree(w) }
} else if args.first == "import-image", args.count == 2 {
    guard let source=NSImage(contentsOfFile:args[1]) else { fatalError("Image unavailable") }
    let pb=NSPasteboard(name:NSPasteboard.Name("com.snipsnipsnip.app-preview.source"))
    pb.clearContents(); guard pb.writeObjects([source]) else { fatalError("Unable to prepare image") }
    print("snipsnipsnip://import-pasteboard?name=com.snipsnipsnip.app-preview.source&source=Orbit")
} else if args.first == "status" {
    print("frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none")")
    print("accessibility=\(AXIsProcessTrusted()) postEvents=\(CGPreflightPostEventAccess()) screenCapture=\(CGPreflightScreenCaptureAccess()) pointer=\(CGEvent(source:nil)!.location)")
    for a in NSWorkspace.shared.runningApplications where allowedBundles.contains(a.bundleIdentifier ?? "") {
        print("APP \(a.processIdentifier) \(a.bundleIdentifier ?? "")")
        for w in windows(a.processIdentifier) { print("WINDOW \(value(w,kAXTitleAttribute) as? String ?? "") frame=\(point(w)) \(size(w))") }
    }
    if let ws=CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] {
        for w in ws where ["SnipSnipSnip","Preview","TextEdit","ChatGPT Computer Use"].contains(w[kCGWindowOwnerName as String] as? String ?? "") {
            print("CG \(w[kCGWindowNumber as String] ?? "") \(w[kCGWindowOwnerName as String] ?? "") \(w[kCGWindowName as String] ?? "") \(w[kCGWindowBounds as String] ?? "")")
        }
    }
} else if args.first == "plan", args.count == 2 {
    guard AXIsProcessTrusted() && CGPreflightPostEventAccess() else { fatalError("Native-control permission unavailable; no events posted") }
    let plan = try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:args[1]))) as! [[String:Any]]
    let start = ProcessInfo.processInfo.systemUptime
    for a in plan {
        let at=(a["at"] as? Double) ?? 0
        let remaining=at-(ProcessInfo.processInfo.systemUptime-start)
        if remaining>0 { Thread.sleep(forTimeInterval:remaining) }
        print(String(format:"%.3f",ProcessInfo.processInfo.systemUptime-start),a["op"] ?? ""); fflush(stdout)
        action(a)
    }
} else { print("Usage: film-control status | plan actions.json") }
