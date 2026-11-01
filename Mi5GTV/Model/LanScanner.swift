import Foundation
import Darwin

private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
    func all() -> [String] { lock.lock(); defer { lock.unlock() }; return items }
}

enum LanScanner {
    /// عنوان IPv4 للواي فاي (en0)
    static func localIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            let ifa = cur.pointee
            if let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: ifa.ifa_name)
                if name == "en0" {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    let rc = getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                                         nil, 0, NI_NUMERICHOST)
                    if rc == 0 { return String(cString: host) }
                }
            }
            ptr = ifa.ifa_next
        }
        return nil
    }

    private static func lastOctet(_ ip: String) -> Int {
        let parts = ip.split(separator: ".")
        if let last = parts.last, let v = Int(last) { return v }
        return 0
    }

    /// يفحص الشبكة /24 بحثًا عن أجهزة تستمع على المنفذ 5555
    static func scan(port: UInt16 = 5555) async -> [String] {
        guard let me = localIPv4() else { return [] }
        let parts = me.split(separator: ".")
        guard parts.count == 4 else { return [] }
        let prefix = parts[0...2].joined(separator: ".")

        return await withCheckedContinuation { (cont: CheckedContinuation<[String], Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let box = ResultBox()
                let group = DispatchGroup()
                let sem = DispatchSemaphore(value: 48)
                for i in 1...254 {
                    let ip = "\(prefix).\(i)"
                    if ip == me { continue }
                    sem.wait()
                    group.enter()
                    DispatchQueue.global(qos: .userInitiated).async {
                        let s = TCPSocket()
                        do {
                            try s.connect(host: ip, port: port, timeout: 0.7)
                            box.add(ip)
                        } catch {
                            // لا شيء
                        }
                        s.close()
                        sem.signal()
                        group.leave()
                    }
                }
                group.wait()
                let sorted = box.all().sorted { lastOctet($0) < lastOctet($1) }
                cont.resume(returning: sorted)
            }
        }
    }
}
