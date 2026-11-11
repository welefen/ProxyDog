import Foundation

/// Injects HTTP(S)_PROXY environment variables into the user's launchd session so
/// applications launched afterwards (Finder/Dock/`open`) that rely on env-based proxy
/// detection — e.g. Electron main processes and Node based tools — pick up ProxyDog.
///
/// `launchctl setenv` only affects processes started later; already running apps keep
/// their old environment. A LaunchAgent re-applies the variables at login so the setting
/// survives a reboot while the system proxy is still enabled.
enum SystemProxyEnvironment {
    private static let launchAgentLabel = "com.proxydog.app.proxyenv"
    private static let launchAgentPath = ("~/Library/LaunchAgents/" + launchAgentLabel + ".plist" as NSString)
        .expandingTildeInPath
    private static let savedNoProxyKey = "proxy.envSavedNoProxy"
    private static let activeKey = "proxy.envProxyActive"

    static func enable(port: Int) {
        let url = "http://127.0.0.1:\(port)"
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: activeKey) {
            defaults.set(launchctlGetenv("NO_PROXY") ?? "", forKey: savedNoProxyKey)
            defaults.set(true, forKey: activeKey)
        }
        let noProxy = mergedNoProxy(launchctlGetenv("NO_PROXY"))
        for name in ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"] {
            launchctlSetenv(name, url)
        }
        for name in ["NO_PROXY", "no_proxy"] {
            launchctlSetenv(name, noProxy)
        }
        writeLaunchAgent(url: url, noProxy: noProxy)
    }

    static func disable() {
        let defaults = UserDefaults.standard
        for name in ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy", "NO_PROXY", "no_proxy"] {
            launchctlUnsetenv(name)
        }
        if let saved = defaults.string(forKey: savedNoProxyKey), !saved.isEmpty {
            launchctlSetenv("NO_PROXY", saved)
            launchctlSetenv("no_proxy", saved)
        }
        defaults.removeObject(forKey: savedNoProxyKey)
        defaults.set(false, forKey: activeKey)
        try? FileManager.default.removeItem(atPath: launchAgentPath)
    }

    private static func mergedNoProxy(_ existing: String?) -> String {
        var entries = (existing ?? "").split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        for loopback in ["127.0.0.1", "localhost", "::1"] where !entries.contains(loopback) {
            entries.append(loopback)
        }
        return entries.joined(separator: ",")
    }

    private static func launchctlSetenv(_ name: String, _ value: String) {
        _ = runLaunchctl(["setenv", name, value])
    }

    private static func launchctlUnsetenv(_ name: String) {
        _ = runLaunchctl(["unsetenv", name])
    }

    private static func launchctlGetenv(_ name: String) -> String? {
        let result = runLaunchctl(["getenv", name])
        let value = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    @discardableResult
    private static func runLaunchctl(_ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errorPipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            _ = errorPipe
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    private static func writeLaunchAgent(url: String, noProxy: String) {
        let script = [
            "/bin/launchctl setenv HTTP_PROXY '\(url)'",
            "/bin/launchctl setenv HTTPS_PROXY '\(url)'",
            "/bin/launchctl setenv ALL_PROXY '\(url)'",
            "/bin/launchctl setenv http_proxy '\(url)'",
            "/bin/launchctl setenv https_proxy '\(url)'",
            "/bin/launchctl setenv all_proxy '\(url)'",
            "/bin/launchctl setenv NO_PROXY '\(noProxy)'",
            "/bin/launchctl setenv no_proxy '\(noProxy)'",
        ].joined(separator: " && ")
        let plist: [String: Any] = [
            "Label": launchAgentLabel,
            "ProgramArguments": ["/bin/sh", "-c", script],
            "RunAtLoad": true,
            "ProcessType": "Background",
        ]
        do {
            let directory = (launchAgentPath as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: URL(fileURLWithPath: launchAgentPath), options: .atomic)
        } catch {
            // Best-effort: the immediate launchctl injection still works for this session.
        }
    }
}
