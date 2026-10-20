import CoreGraphics
import Foundation

// Prints the window number of the named app's main window.
let owner = CommandLine.arguments[1]
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for window in windows where window[kCGWindowOwnerName as String] as? String == owner && window[kCGWindowLayer as String] as? Int == 0 {
    if let bounds = window[kCGWindowBounds as String] as? [String: Double], bounds["Width"] == 522 {
        print(window[kCGWindowNumber as String]!)
        exit(0)
    }
}
exit(1)
