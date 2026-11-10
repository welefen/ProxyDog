import Foundation

enum AppInfo {
    static let name = "ProxyDog"
    static let version: String = {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }()
    static let build: String = {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }()
    static var versionLabel: String { "v\(version)" }
    static let bundleIdentifier = "com.proxydog.app"
}

/// Layout / product constants shared by the UI.
enum AppDefaults {
    static let proxyPort = 8888
    static let socksPort = 8889
    static let maxCapturedRequests = 2_000
    static let maxBodyBytes = 2 * 1024 * 1024
    static let defaultWindowWidth: CGFloat = 1280
    static let defaultWindowHeight: CGFloat = 820
}
