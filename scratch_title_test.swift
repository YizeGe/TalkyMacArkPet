import Cocoa
import CoreGraphics

func getChromeWindowTitle() {
    let workspace = NSWorkspace.shared
    guard let app = workspace.runningApplications.first(where: { $0.bundleIdentifier == "com.google.Chrome" }) else { return }
    
    let options = CGWindowListOption(arrayLiteral: .optionOnScreenOnly, .excludeDesktopElements)
    if let windowListInfo = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] {
        for info in windowListInfo {
            if let windowPID = info[kCGWindowOwnerPID as String] as? Int32, windowPID == app.processIdentifier {
                let name = info[kCGWindowName as String] as? String ?? ""
                let layer = info[kCGWindowLayer as String] as? Int ?? 0
                print("Layer: \(layer), Name: '\(name)'")
            }
        }
    }
}

getChromeWindowTitle()
