import AppKit
import CryptoKit
import Foundation

/// Manifest served from the repository's `updates/latest.json`.
struct UpdateManifest: Decodable {
    let version: String
    let downloadURL: String
    let sha256: String
    let releaseNotes: String?
}

enum UpdatePhase: Equatable {
    case idle
    case checking
    case upToDate
    case available(String)
    case downloading(String)
    case ready(String)
    case installing(String)
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .checking, .downloading, .ready, .installing: return true
        default: return false
        }
    }
}

/// Lightweight self-updater: downloads `updates/latest.json` from GitHub, verifies the ZIP
/// by SHA-256, stages the new app bundle and swaps it after quitting. No third-party
/// framework and no signing keys — mirrors the updater in the sibling TidyMac project.
@MainActor
final class UpdateManager: ObservableObject {
    static let shared = UpdateManager()

    static let defaultFeedURL = URL(
        string: "https://api.github.com/repos/welefen/ProxyDog/contents/updates/latest.json?ref=master"
    )!
    static let fallbackFeedURL = URL(
        string: "https://raw.githubusercontent.com/welefen/ProxyDog/master/updates/latest.json"
    )!

    @Published private(set) var phase: UpdatePhase = .idle
    @Published private(set) var currentVersion: String = {
        if let override = ProcessInfo.processInfo.environment["PROXYDOG_CURRENT_VERSION"],
           !override.isEmpty {
            return override
        }
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? AppInfo.version
    }()

    private static var didStartOnLaunch = false

    private var feedURL: URL {
        if let raw = ProcessInfo.processInfo.environment["PROXYDOG_UPDATE_FEED"],
           let url = URL(string: raw) {
            return url
        }
        return Self.defaultFeedURL
    }

    var statusText: String {
        switch phase {
        case .idle:
            return String(localized: "Not checked yet")
        case .checking:
            return String(localized: "Checking for updates…")
        case .upToDate:
            return String(localized: "You’re on the latest version")
        case .available(let version):
            return String(format: String(localized: "Version %@ is available"), version)
        case .downloading(let version):
            return String(format: String(localized: "Downloading v%@…"), version)
        case .ready(let version):
            return String(format: String(localized: "v%@ is ready to install"), version)
        case .installing(let version):
            return String(format: String(localized: "Installing v%@ and restarting…"), version)
        case .failed(let message):
            return message
        }
    }

    /// Newer version offered/downloaded, used for the sidebar badge.
    var availableVersion: String? {
        switch phase {
        case .available(let version), .downloading(let version), .ready(let version):
            return version
        default:
            return nil
        }
    }

    var canInstall: Bool {
        if case .ready = phase { return true }
        return false
    }

    /// Automatic check two seconds after launch. Skipped for sample/demo runs, headless
    /// mode and development builds inside `build/` (which must not overwrite themselves).
    func startOnLaunch(isDemo: Bool) async {
        guard !isDemo, !Self.didStartOnLaunch else { return }
        guard !ProcessInfo.processInfo.arguments.contains("--headless") else { return }
        guard !ProcessInfo.processInfo.environment.keys.contains("PROXYDOG_UPDATE_DISABLE") else { return }
        let bundlePath = Bundle.main.bundleURL.path
        guard !bundlePath.contains("/build/") else { return }
        Self.didStartOnLaunch = true
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        guard phase == .idle else { return }
        await check(manual: false)
    }

    func check(manual: Bool) async {
        if phase.isBusy { return }
        if manual { phase = .checking }
        Self.debug("check manual=\(manual) feed=\(feedURL.absoluteString)")
        do {
            let manifest = try await fetchManifest()
            Self.debug("manifest=\(manifest.version) current=\(currentVersion)")
            guard Self.isVersion(manifest.version, newerThan: currentVersion) else {
                phase = .upToDate
                return
            }
            phase = .available(manifest.version)
            await downloadAndPrepare(manifest)
        } catch {
            Self.debug("check failed: \(error.localizedDescription)")
            phase = .failed(String(format: String(localized: "Update check failed: %@"), error.localizedDescription))
        }
    }

    /// QA hook: force a phase so the sidebar badge states can be reviewed without a feed.
    func qaSetPhase(_ phase: UpdatePhase) {
        self.phase = phase
    }

    func installDownloadedUpdate() {
        guard case .ready(let version) = phase, let staged = stagedAppURL else { return }
        installAndRelaunch(staged: staged, version: version)
    }

    // MARK: - Feed

    private func fetchManifest() async throws -> UpdateManifest {
        if let manifest = try? await fetch(feedURL) {
            return manifest
        }
        return try await fetch(Self.fallbackFeedURL)
    }

    private func fetch(_ url: URL) async throws -> UpdateManifest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let token = ProcessInfo.processInfo.environment["PROXYDOG_UPDATE_TOKEN"], !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/vnd.github.raw", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw UpdateError.feedUnavailable
        }
        return try JSONDecoder().decode(UpdateManifest.self, from: data)
    }

    // MARK: - Download and stage

    private var stagedAppURL: URL?

    private func downloadAndPrepare(_ manifest: UpdateManifest) async {
        Self.debug("downloading \(manifest.downloadURL)")
        phase = .downloading(manifest.version)
        do {
            guard let downloadURL = URL(string: manifest.downloadURL),
                  let scheme = downloadURL.scheme?.lowercased(),
                  scheme == "https" || scheme == "http" else {
                throw UpdateError.invalidDownloadURL
            }
            let work = FileManager.default.temporaryDirectory
                .appendingPathComponent("ProxyDogUpdate-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let archive = work.appendingPathComponent("update.zip")

            var request = URLRequest(url: downloadURL)
            request.timeoutInterval = 120
            if let token = ProcessInfo.processInfo.environment["PROXYDOG_UPDATE_TOKEN"], !token.isEmpty {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            let (temporaryFile, response) = try await URLSession.shared.download(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw UpdateError.downloadFailed
            }
            try FileManager.default.moveItem(at: temporaryFile, to: archive)

            let expected = manifest.sha256.lowercased()
            let actual = try Self.sha256(of: archive)
            guard !expected.isEmpty, actual == expected else {
                throw UpdateError.checksumMismatch
            }

            let extracted = work.appendingPathComponent("extracted", isDirectory: true)
            try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
            try Self.run("/usr/bin/ditto", ["-x", "-k", archive.path, extracted.path])

            guard let app = Self.findAppBundle(in: extracted) else {
                throw UpdateError.appBundleMissing
            }
            guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
                  let identifier = info["CFBundleIdentifier"] as? String,
                  identifier == AppInfo.bundleIdentifier else {
                throw UpdateError.invalidBundle
            }
            let stagedVersion = info["CFBundleShortVersionString"] as? String ?? ""
            guard stagedVersion == manifest.version else {
                throw UpdateError.versionMismatch
            }

            stagedAppURL = app
            phase = .ready(manifest.version)
        } catch {
            phase = .failed(String(format: String(localized: "Update download failed: %@"), error.localizedDescription))
        }
    }

    // MARK: - Install

    private func installAndRelaunch(staged: URL, version: String) {
        let target = Bundle.main.bundleURL
        let parent = target.deletingLastPathComponent()
        guard target.pathExtension == "app",
              FileManager.default.isWritableFile(atPath: parent.path) else {
            phase = .failed(String(localized: "Cannot write to the app folder. Move ProxyDog to Applications and try again."))
            return
        }
        do {
            let script = FileManager.default.temporaryDirectory
                .appendingPathComponent("proxydog-update-\(UUID().uuidString).sh")
            let content = """
            #!/bin/sh
            pid="$1"
            target="$2"
            staged="$3"
            while kill -0 "$pid" 2> /dev/null; do
                sleep 0.3
            done
            backup="${target}.backup.$$"
            if [ -e "$target" ]; then
                mv "$target" "$backup" || exit 1
            fi
            if /usr/bin/ditto "$staged" "$target"; then
                rm -rf "$backup"
                /usr/bin/xattr -dr com.apple.quarantine "$target" 2>/dev/null || true
                /usr/bin/open -n "$target"
                exit 0
            else
                rm -rf "$target"
                if [ -e "$backup" ]; then mv "$backup" "$target"; fi
                exit 1
            fi
            """
            try content.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [script.path, "\(ProcessInfo.processInfo.processIdentifier)", target.path, staged.path]
            try process.run()

            phase = .installing(version)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                NSApp.terminate(nil)
            }
        } catch {
            phase = .failed(String(format: String(localized: "Update install failed: %@"), error.localizedDescription))
        }
    }

    // MARK: - Helpers

    private static func debug(_ message: String) {
        guard ProcessInfo.processInfo.environment["PROXYDOG_UPDATE_DEBUG"] == "1" else { return }
        let line = "[\(Date())] \(message)\n"
        let url = URL(fileURLWithPath: "/tmp/proxydog-update-debug.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8) ?? Data())
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError.toolFailed((tool as NSString).lastPathComponent)
        }
    }

    private static func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func findAppBundle(in directory: URL) -> URL? {
        let direct = directory.appendingPathComponent("ProxyDog.app")
        if FileManager.default.fileExists(atPath: direct.appendingPathComponent("Contents/Info.plist").path) {
            return direct
        }
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return nil
        }
        for case let url as URL in enumerator where url.pathExtension == "app" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/Info.plist").path) {
                return url
            }
        }
        return nil
    }

    private static func isVersion(_ lhs: String, newerThan rhs: String) -> Bool {
        lhs.compare(rhs, options: .numeric) == .orderedDescending
    }
}

enum UpdateError: LocalizedError {
    case feedUnavailable
    case invalidDownloadURL
    case downloadFailed
    case checksumMismatch
    case appBundleMissing
    case invalidBundle
    case versionMismatch
    case toolFailed(String)

    var errorDescription: String? {
        switch self {
        case .feedUnavailable:
            return String(localized: "Could not reach the update feed.")
        case .invalidDownloadURL:
            return String(localized: "The update download URL is invalid.")
        case .downloadFailed:
            return String(localized: "Downloading the update failed.")
        case .checksumMismatch:
            return String(localized: "The update archive failed its checksum; update aborted.")
        case .appBundleMissing:
            return String(localized: "The update archive does not contain ProxyDog.app.")
        case .invalidBundle:
            return String(localized: "The downloaded app is not ProxyDog.")
        case .versionMismatch:
            return String(localized: "The downloaded version does not match the update manifest.")
        case .toolFailed(let tool):
            return String(format: String(localized: "Could not extract the update archive: %@"), tool)
        }
    }
}
