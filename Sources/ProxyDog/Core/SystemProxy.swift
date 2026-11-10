import Foundation

/// Toggles the macOS system HTTP/HTTPS proxy to point at ProxyDog.
///
/// Owned by the proxy core (`Sources/ProxyDog/Core/`). Requires admin rights, which
/// are requested through the standard macOS authorization prompt.
enum SystemProxy {
    private static let networksetup = "/usr/sbin/networksetup"
    private static let route = "/sbin/route"
    private static let ifconfig = "/sbin/ifconfig"

    /// Name of the active network service, e.g. "Wi-Fi".
    static func activeNetworkService() -> String? {
        if let device = defaultRouteInterface(), let service = service(forDevice: device) {
            return service
        }
        return enabledServices().first
    }

    /// Whether the system proxy is currently pointed at `port` on localhost.
    static func isEnabled(port: Int) -> Bool {
        for service in enabledServices() {
            guard let result = try? ProcessRunner.run(networksetup, ["-getwebproxy", service]) else { continue }
            if result.succeeded, proxyOutputMatches(result.stdout, port: port) {
                return true
            }
        }
        return false
    }

    /// Enables the HTTP and HTTPS system proxy for every active network service.
    static func enable(port: Int) throws {
        let services = activeServices()
        guard !services.isEmpty else {
            throw ProxyError.systemProxyFailed("No active network service was found.")
        }
        var commands = ["set -e"]
        for service in services {
            let quoted = ProcessRunner.shellQuote(service)
            commands.append("\(networksetup) -setwebproxy \(quoted) 127.0.0.1 \(port)")
            commands.append("\(networksetup) -setsecurewebproxy \(quoted) 127.0.0.1 \(port)")
        }
        try ProcessRunner.runAdminShell(commands.joined(separator: "; "))
    }

    /// Disables the HTTP and HTTPS system proxy for every active network service.
    static func disable() throws {
        let services = activeServices()
        guard !services.isEmpty else { return }
        var commands: [String] = []
        for service in services {
            let quoted = ProcessRunner.shellQuote(service)
            commands.append("\(networksetup) -setwebproxystate \(quoted) off")
            commands.append("\(networksetup) -setsecurewebproxystate \(quoted) off")
        }
        commands.append("true")
        try ProcessRunner.runAdminShell(commands.joined(separator: "; "))
    }

    // MARK: - Helpers

    /// All enabled network services (skipping the ones prefixed with `*`).
    private static func enabledServices() -> [String] {
        guard let result = try? ProcessRunner.run(networksetup, ["-listallnetworkservices"]),
              result.succeeded
        else { return [] }

        var services: [String] = []
        for line in result.stdout.split(separator: "\n") {
            let name = line.trimmingCharacters(in: .whitespaces)
            if name.isEmpty { continue }
            if name.hasPrefix("*") { continue }
            if name.lowercased().contains("denotes that a network service is disabled") { continue }
            services.append(name)
        }
        return services
    }

    /// Enabled services that currently have a usable IPv4 address, falling back to all
    /// enabled services when detection fails.
    private static func activeServices() -> [String] {
        let services = enabledServices()
        guard !services.isEmpty else { return [] }
        let mapping = serviceDeviceMap()

        var active: [String] = []
        for service in services {
            guard let device = mapping[service] else { continue }
            guard let result = try? ProcessRunner.run(ifconfig, [device]) else { continue }
            if result.stdout.contains("inet ") || result.stdout.contains("status: active") {
                active.append(service)
            }
        }
        return active.isEmpty ? services : active
    }

    private static func serviceDeviceMap() -> [String: String] {
        guard let result = try? ProcessRunner.run(networksetup, ["-listnetworkserviceorder"]),
              result.succeeded
        else { return [:] }

        var map: [String: String] = [:]
        var pendingService: String?
        for rawLine in result.stdout.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("("), line.hasSuffix(")") == false {
                // "(1) Wi-Fi"
                if let close = line.firstIndex(of: ")") {
                    let name = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
                    pendingService = name.isEmpty ? nil : name
                }
                continue
            }
            if line.lowercased().hasPrefix("(hardware port:"), let service = pendingService {
                if let deviceRange = line.range(of: "Device:") {
                    let device = line[deviceRange.upperBound...]
                        .trimmingCharacters(in: CharacterSet(charactersIn: ") ").union(.whitespaces))
                    if !device.isEmpty {
                        map[service] = device
                    }
                }
                pendingService = nil
            }
        }
        return map
    }

    private static func defaultRouteInterface() -> String? {
        guard let result = try? ProcessRunner.run(route, ["-n", "get", "default"]),
              result.succeeded
        else { return nil }
        for line in result.stdout.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("interface:") else { continue }
            let device = trimmed.dropFirst("interface:".count).trimmingCharacters(in: .whitespaces)
            return device.isEmpty ? nil : device
        }
        return nil
    }

    private static func service(forDevice device: String) -> String? {
        let map = serviceDeviceMap()
        return map.first(where: { $0.value == device })?.key
    }

    /// Parses `networksetup -getwebproxy` output and checks it points at 127.0.0.1:port.
    private static func proxyOutputMatches(_ output: String, port: Int) -> Bool {
        var enabled = false
        var server: String?
        var proxyPort: Int?
        for rawLine in output.split(separator: "\n") {
            let parts = rawLine.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2 else { continue }
            switch parts[0].lowercased() {
            case "enabled":
                enabled = parts[1].lowercased() == "yes"
            case "server":
                server = parts[1]
            case "port":
                proxyPort = Int(parts[1])
            default:
                break
            }
        }
        guard enabled, proxyPort == port, let server else { return false }
        return server == "127.0.0.1" || server == "localhost"
    }
}
