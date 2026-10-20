import CoreGraphics
import Foundation

// Prints the window number of the named app's largest normal window.
let owner = CommandLine.arguments[1]
let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
    .filter { $0[kCGWindowOwnerName as String] as? String == owner && $0[kCGWindowLayer as String] as? Int == 0 }
func area(_ window: [String: Any]) -> Double {
    let bounds = window[kCGWindowBounds as String] as? [String: Double] ?? [:]
    return (bounds["Width"] ?? 0) * (bounds["Height"] ?? 0)
}
guard let largest = windows.max(by: { area($0) < area($1) }) else { exit(1) }
print(largest[kCGWindowNumber as String]!)
