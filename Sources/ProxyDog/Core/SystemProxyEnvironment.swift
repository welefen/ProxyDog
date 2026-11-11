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
        var commands: [[String]] = ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"]
            .map { ["setenv", $0, url] }
        commands += ["NO_PROXY", "no_proxy"].map { ["setenv", $0, noProxy] }
        runLaunchctlBatch(commands)
        writeLaunchAgent(url: url, noProxy: noProxy)
    }

    /// Removes our injected variables. Safe to call when nothing was injected and also
    /// recovers from stale state when UserDefaults were cleared.
    static func disable(port: Int? = nil) {
        let defaults = UserDefaults.standard
        let hasAgent = FileManager.default.fileExists(atPath: launchAgentPath)
        let active = defaults.bool(forKey: activeKey)
        if !active, !hasAgent {
            // Stale fallback: only trust an exact loopback URL for our own port.
            guard let port,
                  launchctlGetenv("HTTP_PROXY") == "http://127.0.0.1:\(port)" else { return }
        }

        var commands: [[String]] = ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"]
            .map { ["unsetenv", $0] }
        if let saved = defaults.string(forKey: savedNoProxyKey), !saved.isEmpty {
            commands.append(["setenv", "NO_PROXY", saved])
            commands.append(["setenv", "no_proxy", saved])
        } else {
            commands.append(["unsetenv", "NO_PROXY"])
            commands.append(["unsetenv", "no_proxy"])
        }
        runLaunchctlBatch(commands)
        defaults.removeObject(forKey: savedNoProxyKey)
        defaults.set(false, forKey: activeKey)
        try? FileManager.default.removeItem(atPath: launchAgentPath)
    }

    /// Non-blocking cleanup for app termination: launchctl operations can take seconds,
    /// so run them from a detached shell after the app is allowed to quit.
    static func scheduleDisableAfterExit() {
        let defaults = UserDefaults.standard
        let hasAgent = FileManager.default.fileExists(atPath: launchAgentPath)
        guard defaults.bool(forKey: activeKey) || hasAgent else { return }

        var lines = ["#!/bin/sh"]
        for name in ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"] {
            lines.append("/bin/launchctl unsetenv \(name)")
        }
        if let saved = defaults.string(forKey: savedNoProxyKey), !saved.isEmpty {
            lines.append("/bin/launchctl setenv NO_PROXY '\(saved)'")
            lines.append("/bin/launchctl setenv no_proxy '\(saved)'")
        } else {
            lines.append("/bin/launchctl unsetenv NO_PROXY")
            lines.append("/bin/launchctl unsetenv no_proxy")
        }
        lines.append("rm -f '\(launchAgentPath)'")
        lines.append("rm -f \"$0\"")
        let scriptPath = NSTemporaryDirectory() + "proxydog-env-cleanup-\(UUID().uuidString).sh"
        let script = lines.joined(separator: "\n") + "\n"
        guard (try? script.write(toFile: scriptPath, atomically: true, encoding: .utf8)) != nil else { return }

        defaults.removeObject(forKey: savedNoProxyKey)
        defaults.set(false, forKey: activeKey)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptPath]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
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

    private static func runLaunchctlBatch(_ commands: [[String]]) {
        let group = DispatchGroup()
        for arguments in commands {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                _ = runLaunchctl(arguments)
                group.leave()
            }
        }
        group.wait()
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
