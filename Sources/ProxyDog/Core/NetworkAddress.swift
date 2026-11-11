import Darwin
import Foundation

/// LAN IPv4 address of this Mac, used by the "allow LAN devices" mode.
enum NetworkAddress {
    static func lanIPv4() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let list = interfaces else { return nil }
        defer { freeifaddrs(interfaces) }

        var candidates: [(name: String, address: String)] = []
        var pointer = list
        while true {
            let interface = pointer.pointee
            defer {
                if let next = interface.ifa_next { pointer = next }
            }
            guard let addr = interface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else {
                if interface.ifa_next == nil { break }
                continue
            }
            let flags = Int32(interface.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else {
                if interface.ifa_next == nil { break }
                continue
            }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(addr.pointee.sa_len)
            if getnameinfo(addr, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let value = String(cString: host)
                if !value.hasPrefix("169.254.") {
                    candidates.append((String(cString: interface.ifa_name), value))
                }
            }
            if interface.ifa_next == nil { break }
        }
        // Prefer Wi-Fi / Ethernet interfaces over virtual ones.
        let preferred = candidates.first { $0.name == "en0" } ?? candidates.first { $0.name.hasPrefix("en") }
        return (preferred ?? candidates.first)?.address
    }
}
