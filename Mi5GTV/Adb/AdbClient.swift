import Foundation

/// واجهة async فوق AdbConnection؛ كل الأوامر تمر عبر طابور تسلسلي واحد.
final class AdbClient: @unchecked Sendable {
    private let queue = DispatchQueue(label: "mi5g.adb.queue")
    private let conn = AdbConnection()

    func connect(host: String, onApproval: @escaping @Sendable () -> Void) async throws {
        try await perform { () -> Void in
            let key = try AdbKey()
            self.conn.close()
            try self.conn.connect(host: host, port: 5555, key: key, onApproval: onApproval)
        }
    }

    func disconnect() {
        queue.async { self.conn.close() }
    }

    func shell(_ command: String, timeout: TimeInterval = 30) async throws -> String {
        let data: Data = try await perform {
            try self.conn.run("shell:" + command, timeout: timeout)
        }
        return AdbClient.text(data)
    }

    func raw(_ service: String, timeout: TimeInterval = 60) async throws -> Data {
        return try await perform {
            try self.conn.run(service, timeout: timeout)
        }
    }

    static func text(_ data: Data) -> String {
        let s = String(decoding: data, as: UTF8.self)
        return s.replacingOccurrences(of: "\r\n", with: "\n")
    }

    private func perform<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            queue.async {
                do {
                    let value = try work()
                    cont.resume(returning: value)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }
}
