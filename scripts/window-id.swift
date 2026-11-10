import Foundation
import CoreGraphics

/// Prints the CGWindowID of the first on-screen window owned by the given app name.
/// Usage: window-id ProxyDog
let targetName = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "ProxyDog"
let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]

guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
    exit(1)
}

var best: (id: Int, area: Double) = (0, 0)
for info in windows {
    guard let owner = info[kCGWindowOwnerName as String] as? String, owner == targetName else { continue }
    guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
    guard let number = info[kCGWindowNumber as String] as? Int else { continue }
    var area = 0.0
    if let bounds = info[kCGWindowBounds as String] as? [String: Any] {
        let width = bounds["Width"] as? Double ?? 0
        let height = bounds["Height"] as? Double ?? 0
        area = width * height
    }
    if area > best.area {
        best = (number, area)
    }
}

if best.id == 0 { exit(2) }
print(best.id)
