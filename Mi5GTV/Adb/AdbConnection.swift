import Foundation

private enum Cmd {
    static let CNXN: UInt32 = 0x4e584e43
    static let AUTH: UInt32 = 0x48545541
    static let OPEN: UInt32 = 0x4e45504f
    static let OKAY: UInt32 = 0x59414b4f
    static let CLSE: UInt32 = 0x45534c43
    static let WRTE: UInt32 = 0x45545257
    static let STLS: UInt32 = 0x534c5453
}

struct AdbMessage {
    var command: UInt32
    var arg0: UInt32
    var arg1: UInt32
    var payload: Data
}

/// اتصال ADB واحد (بدون TLS) على المنفذ 5555. غير آمن للاستخدام المتزامن؛
/// يُستخدم دائمًا من طابور تسلسلي واحد (انظر AdbClient).
final class AdbConnection {
    private let sock = TCPSocket()
    private var nextId: UInt32 = 1
    private let version: UInt32 = 0x01000000
    private let maxPayload: UInt32 = 1024 * 1024
    private(set) var banner = ""

    var isOpen: Bool { return sock.isOpen }

    func close() { sock.close() }

    // MARK: - Frames

    private func send(_ cmd: UInt32, _ a0: UInt32, _ a1: UInt32, _ payload: Data = Data()) throws {
        var frame = Data()
        func put(_ v: UInt32) {
            frame.append(UInt8(v & 0xff))
            frame.append(UInt8((v >> 8) & 0xff))
            frame.append(UInt8((v >> 16) & 0xff))
            frame.append(UInt8((v >> 24) & 0xff))
        }
        var checksum: UInt32 = 0
        for byte in payload { checksum = checksum &+ UInt32(byte) }
        put(cmd)
        put(a0)
        put(a1)
        put(UInt32(payload.count))
        put(checksum)
        put(~cmd)
        frame.append(payload)
        try sock.sendAll(frame)
    }

    private func readMessage(timeout: TimeInterval) throws -> AdbMessage {
        let h = try sock.recvExact(24, timeout: timeout)
        let b = [UInt8](h)
        func u32(_ o: Int) -> UInt32 {
            let b0 = UInt32(b[o])
            let b1 = UInt32(b[o + 1]) << 8
            let b2 = UInt32(b[o + 2]) << 16
            let b3 = UInt32(b[o + 3]) << 24
            return b0 | b1 | b2 | b3
        }
        let cmd = u32(0)
        if u32(20) != ~cmd { throw AdbError.protocolError("رأس رسالة غير صالح") }
        let len = Int(u32(12))
        if len > 2 * 1024 * 1024 { throw AdbError.protocolError("رسالة كبيرة جدًا") }
        var payload = Data()
        if len > 0 { payload = try sock.recvExact(len, timeout: max(timeout, 10)) }
        return AdbMessage(command: cmd, arg0: u32(4), arg1: u32(8), payload: payload)
    }

    // MARK: - Handshake

    func connect(host: String, port: UInt16, key: AdbKey, onApproval: (() -> Void)?) throws {
        sock.close()
        do {
            try sock.connect(host: host, port: port, timeout: 5)
            try send(Cmd.CNXN, version, maxPayload, Data("host::".utf8) + Data([0]))

            var sentSignature = false
            var sentKey = false
            while true {
                // بعد إرسال المفتاح ننتظر المستخدم ليضغط "سماح" على التلفاز
                let wait: TimeInterval = sentKey ? 90 : 10
                let msg = try readMessage(timeout: wait)
                switch msg.command {
                case Cmd.CNXN:
                    banner = String(decoding: msg.payload, as: UTF8.self)
                    return
                case Cmd.AUTH:
                    guard msg.arg0 == 1 else { throw AdbError.protocolError("رد مصادقة غير متوقع") }
                    if !sentSignature {
                        let sig = try key.sign(token: msg.payload)
                        try send(Cmd.AUTH, 2, 0, sig)
                        sentSignature = true
                    } else if !sentKey {
                        let pub = try key.androidPublicKey(name: "mi5g@ios")
                        try send(Cmd.AUTH, 3, 0, pub)
                        sentKey = true
                        onApproval?()
                    } else {
                        throw AdbError.rejected("رُفض مفتاح التطبيق")
                    }
                case Cmd.STLS:
                    throw AdbError.protocolError("التلفاز يطلب TLS وهذا غير مدعوم في هذه النسخة")
                default:
                    continue
                }
            }
        } catch {
            sock.close()
            throw error
        }
    }

    // MARK: - Streams

    /// يفتح خدمة (مثل shell:ls أو exec:screencap -p) ويقرأ ناتجها كاملًا حتى الإغلاق.
    func run(_ service: String, timeout: TimeInterval = 30) throws -> Data {
        guard sock.isOpen else { throw AdbError.notConnected }
        let local = nextId
        nextId = nextId &+ 1
        try send(Cmd.OPEN, local, 0, Data(service.utf8) + Data([0]))

        var remote: UInt32 = 0
        var opened = false
        var out = Data()
        let deadline = Date().addingTimeInterval(timeout)

        do {
            while true {
                let left = deadline.timeIntervalSinceNow
                if left <= 0 { throw AdbError.timeout }
                let m = try readMessage(timeout: left)
                switch m.command {
                case Cmd.OKAY:
                    if m.arg1 == local {
                        remote = m.arg0
                        opened = true
                    }
                case Cmd.WRTE:
                    if m.arg1 == local {
                        remote = m.arg0
                        opened = true
                        out.append(m.payload)
                        try send(Cmd.OKAY, local, remote)
                    }
                case Cmd.CLSE:
                    if m.arg1 == local {
                        if !opened { throw AdbError.rejected(service) }
                        try? send(Cmd.CLSE, local, remote)
                        return out
                    }
                default:
                    break
                }
            }
        } catch {
            if opened { try? send(Cmd.CLSE, local, remote) }
            throw error
        }
    }
}
