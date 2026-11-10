import AppKit
import Combine
import SystemConfiguration
import SwiftUI

/// Small favicon cache for the sidebar's domain list.
///
/// Icons are fetched directly (bypassing the system proxy so the proxy never captures its
/// own favicon traffic), validated as images, and cached in memory plus on disk under
/// `~/Library/Caches/com.proxydog.app/favicons`. Domains that cannot be resolved (fake
/// sample domains, localhost, IP literals) simply fall back to the globe symbol.
@MainActor
final class FaviconStore: ObservableObject {
    static let shared = FaviconStore()

    @Published private var icons: [String: NSImage] = [:]

    private var failures: [String: Date] = [:]
    private var inFlight: Set<String> = []
    private var session: URLSession
    private var routeDescription = "direct"

    private static let failureTTL: TimeInterval = 10 * 60

    private init() {
        session = Self.makeSession(proxyDictionary: [:])
    }

    /// Routes icon lookups through the network path that can actually reach the site:
    /// ProxyDog's configured upstream proxy first, then the system proxy (unless it points
    /// at ProxyDog itself, which would loop), otherwise a direct connection.
    func updateRoute(upstream: UpstreamProxy?, ownPort: Int) {
        let dictionary = Self.proxyDictionary(upstream: upstream, ownPort: ownPort)
        let description = Self.describe(dictionary)
        guard description != routeDescription else { return }
        routeDescription = description
        session.invalidateAndCancel()
        session = Self.makeSession(proxyDictionary: dictionary)
        // A changed route can make previously unreachable icons reachable.
        failures.removeAll()
    }

    private static func makeSession(proxyDictionary: [AnyHashable: Any]) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = proxyDictionary
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 8
        configuration.httpAdditionalHeaders = [
            "Accept": "image/*,*/*;q=0.8",
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15",
        ]
        return URLSession(configuration: configuration)
    }

    private static func proxyDictionary(upstream: UpstreamProxy?, ownPort: Int) -> [AnyHashable: Any] {
        if let upstream {
            switch upstream.kind {
            case .httpConnect:
                return [
                    kCFNetworkProxiesHTTPEnable as String: true,
                    kCFNetworkProxiesHTTPProxy as String: upstream.host,
                    kCFNetworkProxiesHTTPPort as String: upstream.port,
                    kCFNetworkProxiesHTTPSEnable as String: true,
                    kCFNetworkProxiesHTTPSProxy as String: upstream.host,
                    kCFNetworkProxiesHTTPSPort as String: upstream.port,
                ]
            case .socks5:
                return [
                    kCFNetworkProxiesSOCKSEnable as String: true,
                    kCFNetworkProxiesSOCKSProxy as String: upstream.host,
                    kCFNetworkProxiesSOCKSPort as String: upstream.port,
                ]
            }
        }
        if let system = systemProxyDictionary(excludingPort: ownPort) {
            return system
        }
        return [:]
    }

    /// The OS-configured HTTP/HTTPS/SOCKS proxy, unless it is ProxyDog itself.
    private static func systemProxyDictionary(excludingPort ownPort: Int) -> [AnyHashable: Any]? {
        guard let proxies = SCDynamicStoreCopyProxies(nil) as? [String: Any] else { return nil }
        func flag(_ key: CFString) -> Bool {
            (proxies[key as String] as? NSNumber)?.boolValue ?? false
        }
        func string(_ key: CFString) -> String? {
            proxies[key as String] as? String
        }
        func port(_ key: CFString) -> Int? {
            (proxies[key as String] as? NSNumber)?.intValue
        }
        func isSelf(_ host: String?, _ port: Int?) -> Bool {
            guard let host, let port else { return false }
            return (host == "127.0.0.1" || host == "localhost") && port == ownPort
        }

        var dictionary: [AnyHashable: Any] = [:]
        let httpHost = string(kSCPropNetProxiesHTTPProxy), httpPort = port(kSCPropNetProxiesHTTPPort)
        if flag(kSCPropNetProxiesHTTPEnable), httpHost != nil, httpPort != nil,
           !isSelf(httpHost, httpPort) {
            dictionary[kCFNetworkProxiesHTTPEnable as String] = true
            dictionary[kCFNetworkProxiesHTTPProxy as String] = httpHost
            dictionary[kCFNetworkProxiesHTTPPort as String] = httpPort
        }
        let httpsHost = string(kSCPropNetProxiesHTTPSProxy), httpsPort = port(kSCPropNetProxiesHTTPSPort)
        if flag(kSCPropNetProxiesHTTPSEnable), httpsHost != nil, httpsPort != nil,
           !isSelf(httpsHost, httpsPort) {
            dictionary[kCFNetworkProxiesHTTPSEnable as String] = true
            dictionary[kCFNetworkProxiesHTTPSProxy as String] = httpsHost
            dictionary[kCFNetworkProxiesHTTPSPort as String] = httpsPort
        }
        if dictionary.isEmpty {
            let socksHost = string(kSCPropNetProxiesSOCKSProxy), socksPort = port(kSCPropNetProxiesSOCKSPort)
            if flag(kSCPropNetProxiesSOCKSEnable), socksHost != nil, socksPort != nil,
               !isSelf(socksHost, socksPort) {
                dictionary[kCFNetworkProxiesSOCKSEnable as String] = true
                dictionary[kCFNetworkProxiesSOCKSProxy as String] = socksHost
                dictionary[kCFNetworkProxiesSOCKSPort as String] = socksPort
            }
        }
        return dictionary.isEmpty ? nil : dictionary
    }

    private static func describe(_ dictionary: [AnyHashable: Any]) -> String {
        dictionary
            .map { "\($0.key)=\($0.value)" }
            .sorted()
            .joined(separator: "&")
    }

    func icon(for domain: String) -> NSImage? {
        if let cached = icons[domain] {
            return cached
        }
        // Disk cache is small; reading it synchronously keeps rows simple.
        if let diskImage = loadFromDisk(domain) {
            icons[domain] = diskImage
            return diskImage
        }
        return nil
    }

    func loadIfNeeded(_ domain: String) {
        guard shouldFetch(domain) else { return }
        guard icons[domain] == nil, !inFlight.contains(domain) else { return }
        if let failedAt = failures[domain], Date().timeIntervalSince(failedAt) < Self.failureTTL {
            return
        }

        inFlight.insert(domain)
        Task { [weak self] in
            guard let self else { return }
            let image = await self.fetchIcon(domain: domain)
            self.inFlight.remove(domain)
            if let image {
                self.icons[domain] = image
                self.saveToDisk(image, domain: domain)
            } else {
                self.failures[domain] = Date()
            }
        }
    }

    // MARK: Fetching

    private func fetchIcon(domain: String) async -> NSImage? {
        if let image = await fetchWellKnownIcon(domain: domain) {
            return image
        }

        // Many sites (chatgpt.com, doubao.com, …) only advertise their icon in the HTML.
        if let image = await fetchIconFromHTML(domain: domain) {
            return image
        }

        // Subdomains often have no icon of their own (mcs.doubao.com, chat.deepseek.com);
        // fall back one level to the registrable domain (doubao.com, deepseek.com).
        if let parent = Self.parentDomain(of: domain) {
            if let image = await fetchWellKnownIcon(domain: parent) {
                return image
            }
            if let image = await fetchIconFromHTML(domain: parent) {
                return image
            }
        }
        return nil
    }

    private func fetchWellKnownIcon(domain: String) async -> NSImage? {
        let candidates = [
            "https://\(domain)/favicon.ico",
            "https://\(domain)/favicon.png",
            "https://\(domain)/apple-touch-icon.png",
        ]
        for urlString in candidates {
            if let image = await Self.downloadImage(urlString) {
                return image
            }
        }
        return nil
    }

    private func fetchIconFromHTML(domain: String) async -> NSImage? {
        guard let icons = await Self.iconLinks(inHTMLOf: domain) else { return nil }
        for urlString in icons.prefix(3) {
            if let image = await Self.downloadImage(urlString) {
                return image
            }
        }
        return nil
    }

    /// One level up from a subdomain: `mcs.doubao.com` -> `doubao.com`,
    /// `chat.bbc.co.uk` -> `bbc.co.uk`. Handles common multi-part public suffixes.
    static func parentDomain(of host: String) -> String? {
        var labels = host.lowercased().split(separator: ".").map(String.init)
        if labels.last?.isEmpty == true { labels.removeLast() }
        guard labels.count >= 3 else { return nil }

        let multiPartSuffixes: Set<String> = [
            "com.cn", "net.cn", "org.cn", "gov.cn", "edu.cn", "ac.cn",
            "co.uk", "org.uk", "ac.uk", "gov.uk",
            "co.jp", "ne.jp", "or.jp",
            "com.au", "net.au", "org.au", "co.nz", "net.nz",
            "co.kr", "or.kr", "com.tw", "com.hk", "com.sg", "com.my", "com.ph", "co.id",
            "com.br", "com.ar", "com.mx", "com.co", "com.pe", "com.ve",
            "co.in", "co.za", "com.tr", "com.ru", "com.ua", "com.pl", "com.es",
        ]
        let lastTwo = labels.suffix(2).joined(separator: ".")
        let suffixCount = multiPartSuffixes.contains(lastTwo) ? 2 : 1
        let baseCount = suffixCount + 1
        guard labels.count > baseCount else { return nil }
        return labels.suffix(baseCount).joined(separator: ".")
    }

    private static func downloadImage(_ urlString: String) async -> NSImage? {
        guard let url = URL(string: urlString) else { return nil }
        guard let (data, response) = try? await shared.session.data(from: url) else { return nil }
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 { return nil }
        guard data.count > 0, data.count < 1_000_000 else { return nil }
        guard let image = NSImage(data: data), isValidIcon(image) else { return nil }
        return image
    }

    /// Extracts absolute icon URLs from the page head; used only when the well-known paths
    /// fail. Cheap regex scan — no HTML parser dependency.
    private static func iconLinks(inHTMLOf domain: String) async -> [String]? {
        guard let url = URL(string: "https://\(domain)/"),
              let (data, response) = try? await shared.session.data(from: url) else { return nil }
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 { return nil }
        guard data.count < 2_000_000,
              let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return nil
        }

        let pattern = "<link[^>]+rel\\s*=\\s*[\"']([^\"']*icon[^\"']*)[\"'][^>]*>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        var result: [String] = []
        for match in regex.matches(in: html, options: [], range: range) {
            guard let tagRange = Range(match.range, in: html) else { continue }
            let tag = String(html[tagRange])
            guard let href = firstAttribute("href", in: tag) else { continue }
            let cleaned = href
                .replacingOccurrences(of: "&amp;", with: "&")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }
            if cleaned.hasPrefix("//") {
                result.append("https:" + cleaned)
            } else if cleaned.hasPrefix("http") {
                result.append(cleaned)
            } else if cleaned.hasPrefix("/") {
                result.append("https://\(domain)" + cleaned)
            } else {
                result.append("https://\(domain)/" + cleaned)
            }
        }
        return result.isEmpty ? nil : result
    }

    private static func firstAttribute(_ name: String, in tag: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: "\(name)\\s*=\\s*[\"']([^\"']+)[\"']",
            options: [.caseInsensitive]
        ) else { return nil }
        let range = NSRange(tag.startIndex..<tag.endIndex, in: tag)
        guard let match = regex.firstMatch(in: tag, options: [], range: range),
              match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: tag) else { return nil }
        return String(tag[valueRange])
    }

    private static func isValidIcon(_ image: NSImage) -> Bool {
        guard let representation = image.representations.first else { return false }
        return representation.pixelsWide >= 8 && representation.pixelsHigh >= 8
    }

    // MARK: Eligibility

    /// Skips local and reserved names (sample traffic, localhost, IP literals) where a
    /// favicon lookup makes no sense.
    private func shouldFetch(_ domain: String) -> Bool {
        let host = domain.lowercased()
        guard !host.isEmpty else { return false }
        if host == "localhost" || host.hasSuffix(".localhost") { return false }
        for suffix in [".invalid", ".test", ".local", ".example", ".localhost"] where host.hasSuffix(suffix) {
            return false
        }
        // IP literals.
        if host.allSatisfy({ $0.isNumber || $0 == "." }) { return false }
        if host.contains(":") { return false }
        return true
    }

    // MARK: Disk cache

    private var cacheDirectory: URL? {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = base
            .appendingPathComponent("com.proxydog.app", isDirectory: true)
            .appendingPathComponent("favicons", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    private func cacheURL(for domain: String) -> URL? {
        guard let cacheDirectory else { return nil }
        let name = domain
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "..", with: "_")
        return cacheDirectory.appendingPathComponent(name + ".png")
    }

    private func loadFromDisk(_ domain: String) -> NSImage? {
        guard let url = cacheURL(for: domain),
              let data = try? Data(contentsOf: url),
              let image = NSImage(data: data) else { return nil }
        return image
    }

    private func saveToDisk(_ image: NSImage, domain: String) {
        guard let url = cacheURL(for: domain),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url, options: .atomic)
    }
}

/// Leading icon for a sidebar domain row: favicon when available, globe otherwise.
struct DomainFavicon: View {
    let domain: String
    var size: CGFloat = 14

    @ObservedObject private var store = FaviconStore.shared

    var body: some View {
        Group {
            if let icon = store.icon(for: domain) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            } else {
                Image(systemName: "globe")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(DSColor.textMuted)
                    .frame(width: size, height: size)
            }
        }
        .frame(width: 14, height: 14)
        .task(id: domain) {
            store.loadIfNeeded(domain)
        }
        .accessibilityHidden(true)
    }
}
