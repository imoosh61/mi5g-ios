import Foundation
import Darwin

enum AdbError: LocalizedError {
    case connectFailed(String)
    case timeout
    case closed
    case protocolError(String)
    case rejected(String)
    case notConnected

    var errorDescription: String? {
        switch self {
        case .connectFailed(let m): return "تعذّر الاتصال: \(m)"
        case .timeout: return "انتهت المهلة، لم يرد التلفاز"
        case .closed: return "انقطع الاتصال بالتلفاز"
        case .protocolError(let m): return "خطأ في البروتوكول: \(m)"
        case .rejected(let m): return "رفض التلفاز الطلب: \(m)"
        case .notConnected: return "غير متصل بالتلفاز"
        }
    }
}

/// مقبس TCP بسيط مبني على واجهات Darwin (حظر مع مهلة عبر poll).
final class TCPSocket {
    private var fd: Int32 = -1

    var isOpen: Bool { return fd >= 0 }

    func connect(host: String, port: UInt16, timeout: TimeInterval) throws {
        close()
        let s = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        if s < 0 { throw AdbError.connectFailed("socket") }

        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        if inet_pton(AF_INET, host, &addr.sin_addr) != 1 {
            Darwin.close(s)
            throw AdbError.connectFailed("عنوان IP غير صالح")
        }

        let flags = fcntl(s, F_GETFL, 0)
        _ = fcntl(s, F_SETFL, flags | O_NONBLOCK)

        let r = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                Darwin.connect(s, sp, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if r != 0 {
            if errno != EINPROGRESS {
                let msg = String(cString: strerror(errno))
                Darwin.close(s)
                throw AdbError.connectFailed(msg)
            }
            var pfd = pollfd(fd: s, events: Int16(POLLOUT), revents: 0)
            let pr = poll(&pfd, 1, Int32(timeout * 1000))
            if pr == 0 {
                Darwin.close(s)
                throw AdbError.timeout
            }
            if pr < 0 {
                Darwin.close(s)
                throw AdbError.connectFailed("poll")
            }
            var soError: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(s, SOL_SOCKET, SO_ERROR, &soError, &len)
            if soError != 0 {
                let msg = String(cString: strerror(soError))
                Darwin.close(s)
                throw AdbError.connectFailed(msg)
            }
        }

        _ = fcntl(s, F_SETFL, flags)
        fd = s
    }

    func sendAll(_ data: Data) throws {
        guard fd >= 0 else { throw AdbError.closed }
        let total = data.count
        if total == 0 { return }
        let handle = fd
        var sent = 0
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            while sent < total {
                let n = Darwin.send(handle, base + sent, total - sent, 0)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw AdbError.closed
                }
                if n == 0 { throw AdbError.closed }
                sent += n
            }
        }
    }

    func recvExact(_ count: Int, timeout: TimeInterval) throws -> Data {
        guard fd >= 0 else { throw AdbError.closed }
        var out = Data()
        out.reserveCapacity(count)
        var buf = [UInt8](repeating: 0, count: min(max(count, 1), 65536))
        let deadline = Date().addingTimeInterval(timeout)

        while out.count < count {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { throw AdbError.timeout }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let waitMs = Int32(min(remaining, 3600.0) * 1000.0)
            let pr = poll(&pfd, 1, waitMs)
            if pr == 0 { continue }
            if pr < 0 {
                if errno == EINTR { continue }
                throw AdbError.closed
            }
            let want = min(buf.count, count - out.count)
            let n = Darwin.recv(fd, &buf, want, 0)
            if n < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw AdbError.closed
            }
            if n == 0 { throw AdbError.closed }
            out.append(contentsOf: buf[0..<n])
        }
        return out
    }

    func close() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    deinit { close() }
}
