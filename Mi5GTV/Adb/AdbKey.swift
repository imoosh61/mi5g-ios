import Foundation
import Security

enum KeyError: LocalizedError {
    case generate(String)
    case invalid
    case sign(String)

    var errorDescription: String? {
        switch self {
        case .generate(let m): return "تعذّر إنشاء مفتاح التشفير: \(m)"
        case .invalid: return "مفتاح التشفير غير صالح"
        case .sign(let m): return "تعذّر توقيع رمز المصادقة: \(m)"
        }
    }
}

/// مفتاح RSA-2048 خاص بالتطبيق يُستخدم لمصادقة ADB. يُحفظ في مجلد التطبيق
/// حتى يبقى التلفاز يتذكّر "السماح دائمًا".
final class AdbKey {
    private let privateKey: SecKey
    private let publicKey: SecKey

    init() throws {
        let url = AdbKey.fileURL()
        var loaded: SecKey? = nil
        if let data = try? Data(contentsOf: url) {
            loaded = AdbKey.importPrivate(data)
        }
        let priv: SecKey
        if let k = loaded {
            priv = k
        } else {
            let attrs: [String: Any] = [
                kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                kSecAttrKeySizeInBits as String: 2048
            ]
            var err: Unmanaged<CFError>?
            guard let k = SecKeyCreateRandomKey(attrs as CFDictionary, &err) else {
                let msg = err?.takeRetainedValue().localizedDescription ?? "unknown"
                throw KeyError.generate(msg)
            }
            priv = k
            var err2: Unmanaged<CFError>?
            if let cf = SecKeyCopyExternalRepresentation(k, &err2) {
                let ext = cf as Data
                try? ext.write(to: url, options: .atomic)
            }
        }
        guard let pub = SecKeyCopyPublicKey(priv) else { throw KeyError.invalid }
        self.privateKey = priv
        self.publicKey = pub
    }

    private static func fileURL() -> URL {
        let fm = FileManager.default
        let dir = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                               appropriateFor: nil, create: true)) ?? fm.temporaryDirectory
        return dir.appendingPathComponent("adbkey.der")
    }

    private static func importPrivate(_ data: Data) -> SecKey? {
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate
        ]
        var err: Unmanaged<CFError>?
        return SecKeyCreateWithData(data as CFData, attrs as CFDictionary, &err)
    }

    /// يوقّع رمز AUTH (20 بايت) بصيغة PKCS#1 v1.5 فوق SHA-1 DigestInfo، وهو ما يتحقق منه adbd.
    func sign(token: Data) throws -> Data {
        var err: Unmanaged<CFError>?
        guard let sig = SecKeyCreateSignature(privateKey, .rsaSignatureDigestPKCS1v15SHA1,
                                              token as CFData, &err) else {
            let msg = err?.takeRetainedValue().localizedDescription ?? "unknown"
            throw KeyError.sign(msg)
        }
        return sig as Data
    }

    /// المفتاح العام بصيغة أندرويد: base64(struct) + " name" + NUL
    func androidPublicKey(name: String) throws -> Data {
        var err: Unmanaged<CFError>?
        guard let cf = SecKeyCopyExternalRepresentation(publicKey, &err) else { throw KeyError.invalid }
        let der = [UInt8](cf as Data)
        let parsed = try AdbKey.parseRSAPublic(der)
        let nBE = parsed.n
        if nBE.count != 256 { throw KeyError.invalid }

        let words = 64
        let nLE = Array(nBE.reversed())

        // modulus كلمات 32-بت (little-endian) + كلمة إضافية صفرية
        var nw = [UInt32](repeating: 0, count: words + 1)
        for k in 0..<words {
            let b0 = UInt32(nLE[4 * k])
            let b1 = UInt32(nLE[4 * k + 1]) << 8
            let b2 = UInt32(nLE[4 * k + 2]) << 16
            let b3 = UInt32(nLE[4 * k + 3]) << 24
            nw[k] = b0 | b1 | b2 | b3
        }

        // rr = 2^4096 mod n  (بالتضعيف المتكرر)
        var x = [UInt32](repeating: 0, count: words + 1)
        x[0] = 1
        for _ in 0..<(2 * words * 32) {
            var carry: UInt32 = 0
            for k in 0...words {
                let nextCarry = x[k] >> 31
                x[k] = (x[k] << 1) | carry
                carry = nextCarry
            }
            if AdbKey.geq(x, nw) { AdbKey.subtract(&x, nw) }
        }

        // n0inv = -(n^-1) mod 2^32
        let n0 = nw[0]
        var inv = n0
        for _ in 0..<5 {
            let t = n0 &* inv
            inv = inv &* (2 &- t)
        }
        let n0inv = 0 &- inv

        var out = Data()
        func put(_ v: UInt32) {
            out.append(UInt8(v & 0xff))
            out.append(UInt8((v >> 8) & 0xff))
            out.append(UInt8((v >> 16) & 0xff))
            out.append(UInt8((v >> 24) & 0xff))
        }
        put(UInt32(words))
        put(n0inv)
        for k in 0..<words { put(nw[k]) }
        for k in 0..<words { put(x[k]) }
        put(parsed.e)

        var line = out.base64EncodedString()
        line += " " + name
        var result = Data(line.utf8)
        result.append(0)
        return result
    }

    private static func geq(_ a: [UInt32], _ b: [UInt32]) -> Bool {
        var k = a.count - 1
        while k >= 0 {
            if a[k] != b[k] { return a[k] > b[k] }
            k -= 1
        }
        return true
    }

    private static func subtract(_ a: inout [UInt32], _ b: [UInt32]) {
        var borrow: UInt64 = 0
        for k in 0..<a.count {
            let av = UInt64(a[k])
            let bv = UInt64(b[k]) + borrow
            if av >= bv {
                a[k] = UInt32(av - bv)
                borrow = 0
            } else {
                a[k] = UInt32(av + (UInt64(1) << 32) - bv)
                borrow = 1
            }
        }
    }

    /// يقرأ RSAPublicKey من DER: SEQUENCE { INTEGER n, INTEGER e }
    private static func parseRSAPublic(_ b: [UInt8]) throws -> (n: [UInt8], e: UInt32) {
        var i = 0

        func readLen() throws -> Int {
            guard i < b.count else { throw KeyError.invalid }
            let first = Int(b[i])
            i += 1
            if first < 0x80 { return first }
            let cnt = first & 0x7f
            guard cnt > 0, cnt <= 4, i + cnt <= b.count else { throw KeyError.invalid }
            var v = 0
            for _ in 0..<cnt {
                v = (v << 8) | Int(b[i])
                i += 1
            }
            return v
        }

        func expect(_ tag: UInt8) throws {
            guard i < b.count, b[i] == tag else { throw KeyError.invalid }
            i += 1
        }

        try expect(0x30)
        _ = try readLen()
        try expect(0x02)
        let nLen = try readLen()
        guard nLen > 0, i + nLen <= b.count else { throw KeyError.invalid }
        var n = Array(b[i..<(i + nLen)])
        i += nLen
        while let f = n.first, f == 0 { n.removeFirst() }

        try expect(0x02)
        let eLen = try readLen()
        guard eLen > 0, eLen <= 4, i + eLen <= b.count else { throw KeyError.invalid }
        var e: UInt32 = 0
        for k in 0..<eLen {
            e = (e << 8) | UInt32(b[i + k])
        }
        return (n, e)
    }
}
