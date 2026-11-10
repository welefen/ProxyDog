import AppKit
import SwiftUI

/// Resolves the icon of the local app that originated a request.
///
/// Paths are cached because the traffic list re-renders on every capture update.
/// Resolution is main-thread only (the view layer calls it synchronously).
@MainActor
enum AppIconProvider {
    private static var cache: [String: NSImage] = [:]
    private static var misses: Set<String> = []

    /// 16x16 icon for the app bundle (or executable) at `path`; nil when unknown/missing.
    static func icon(for path: String?) -> NSImage? {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return nil
        }
        if let cached = cache[path] { return cached }
        if misses.contains(path) { return nil }
        guard let target = iconTarget(for: path) else {
            misses.insert(path)
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: target)
        icon.size = NSSize(width: 16, height: 16)
        cache[path] = icon
        return icon
    }

    /// Prefer the enclosing `.app` bundle for crisp app artwork; fall back to the file.
    private static func iconTarget(for path: String) -> String? {
        let fileManager = FileManager.default
        if let range = path.range(of: ".app/") {
            let bundlePath = String(path[..<range.lowerBound]) + ".app"
            if fileManager.fileExists(atPath: bundlePath) {
                return bundlePath
            }
        }
        if path.hasSuffix(".app"), fileManager.fileExists(atPath: path) {
            return path
        }
        if fileManager.fileExists(atPath: path) {
            return path
        }
        return nil
    }
}

/// Small fixed-size app icon with a same-width empty placeholder when attribution is
/// unknown, so the traffic list columns stay aligned.
struct ClientAppIcon: View {
    let path: String?

    var body: some View {
        Group {
            if let image = AppIconProvider.icon(for: path) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 16, height: 16)
            } else {
                Color.clear
                    .frame(width: 16, height: 16)
            }
        }
        .frame(width: DS.Metric.appIconColumnWidth, alignment: .center)
        .accessibilityHidden(true)
    }
}
