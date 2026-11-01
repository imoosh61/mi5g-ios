import SwiftUI
import UIKit

struct TVApp: Identifiable, Hashable {
    let id: String          // اسم الحزمة
    var isSystem: Bool
    var isDisabled: Bool
}

struct ShotItem: Identifiable {
    let id = UUID()
    let image: UIImage
}

struct MemInfo {
    var totalKB: Int
    var availKB: Int
}

struct StorageInfo {
    var totalKB: Int
    var usedKB: Int
}

@MainActor
final class TVSession: ObservableObject {
    enum State {
        case disconnected, connecting, waitingApproval, connected
    }

    enum AppAction {
        case open, forceStop, blockBackground, disable, enable, uninstall, clearData
    }

    @Published var state: State = .disconnected
    @Published var host: String = UserDefaults.standard.string(forKey: "lastHost") ?? ""
    @Published var errorMessage: String?
    @Published var toast: String?
    @Published var deviceName: String = ""

    @Published var apps: [TVApp] = []
    @Published var appsLoading = false

    @Published var mem: MemInfo?
    @Published var storage: StorageInfo?
    @Published var busy = false
    @Published var shot: ShotItem?

    private let client = AdbClient()

    // MARK: - الاتصال

    func connect() async {
        let ip = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ip.isEmpty else {
            errorMessage = "أدخل عنوان IP للتلفاز أولًا"
            return
        }
        state = .connecting
        errorMessage = nil
        do {
            try await client.connect(host: ip) { [weak self] in
                Task { @MainActor in
                    self?.state = .waitingApproval
                }
            }
            UserDefaults.standard.set(ip, forKey: "lastHost")
            state = .connected
            await refreshInfo()
        } catch {
            state = .disconnected
            errorMessage = error.localizedDescription
        }
    }

    func disconnect() {
        client.disconnect()
        state = .disconnected
        apps = []
        mem = nil
        storage = nil
    }

    private func reconnect() async -> Bool {
        let ip = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if ip.isEmpty { return false }
        do {
            try await client.connect(host: ip) { }
            return true
        } catch {
            return false
        }
    }

    private func isConnectionLost(_ error: Error) -> Bool {
        if let e = error as? AdbError {
            switch e {
            case .closed, .notConnected: return true
            default: return false
            }
        }
        return false
    }

    private func handle(_ error: Error) {
        errorMessage = error.localizedDescription
        if isConnectionLost(error) { state = .disconnected }
    }

    /// ينفّذ أمر shell ويعيد الناتج؛ يحاول إعادة الاتصال مرة واحدة إذا انقطع.
    @discardableResult
    func sh(_ command: String, timeout: TimeInterval = 30) async -> String? {
        do {
            return try await client.shell(command, timeout: timeout)
        } catch {
            if isConnectionLost(error) {
                let ok = await reconnect()
                if ok {
                    do {
                        return try await client.shell(command, timeout: timeout)
                    } catch {
                        handle(error)
                        return nil
                    }
                }
            }
            handle(error)
            return nil
        }
    }

    func notify(_ message: String) {
        toast = message
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if toast == message { toast = nil }
        }
    }

    static func quote(_ s: String) -> String {
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func refreshInfo() async {
        guard let out = await sh("getprop ro.product.manufacturer; getprop ro.product.model; getprop ro.build.version.release") else { return }
        let lines = out.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
        if lines.count >= 3 {
            deviceName = "\(lines[0]) \(lines[1]) (Android \(lines[2]))"
        } else if let first = lines.first {
            deviceName = first
        }
    }

    // MARK: - الريموت

    func pressKey(_ code: String) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task { _ = await sh("input keyevent \(code)", timeout: 10) }
    }

    func sendText(_ text: String) async {
        if text.isEmpty { return }
        let t = text.replacingOccurrences(of: " ", with: "%s")
        _ = await sh("input text \(TVSession.quote(t))", timeout: 15)
    }

    // MARK: - التطبيقات

    private func parsePackages(_ out: String) -> [String] {
        var result: [String] = []
        for line in out.split(separator: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("package:") {
                result.append(String(l.dropFirst(8)))
            }
        }
        return result
    }

    func loadApps(includeSystem: Bool) async {
        appsLoading = true
        defer { appsLoading = false }
        guard let userOut = await sh("pm list packages -3") else { return }
        let disabledOut = await sh("pm list packages -d") ?? ""
        let disabled = Set(parsePackages(disabledOut))
        let userPkgs = parsePackages(userOut)
        var result: [TVApp] = []
        for p in userPkgs {
            result.append(TVApp(id: p, isSystem: false, isDisabled: disabled.contains(p)))
        }
        if includeSystem {
            let sysOut = await sh("pm list packages -s") ?? ""
            let userSet = Set(userPkgs)
            for p in parsePackages(sysOut) where !userSet.contains(p) {
                result.append(TVApp(id: p, isSystem: true, isDisabled: disabled.contains(p)))
            }
        }
        apps = result.sorted { $0.id < $1.id }
    }

    private func report(_ out: String?, success: String) {
        guard let out = out else { return }
        let t = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.contains("Failure") || t.contains("Exception") || t.contains("Error") || t.contains("not found") {
            notify("فشل: " + String(t.prefix(80)))
        } else {
            notify(success)
        }
    }

    func perform(_ action: AppAction, on pkg: String) async {
        let q = TVSession.quote(pkg)
        switch action {
        case .open:
            let out = await sh("monkey -p \(q) -c android.intent.category.LEANBACK_LAUNCHER 1") ?? ""
            if out.contains("No activities found") {
                _ = await sh("monkey -p \(q) -c android.intent.category.LAUNCHER 1")
            }
            notify("تم الفتح على التلفاز")
        case .forceStop:
            let out = await sh("am force-stop \(q)")
            report(out, success: "تم الإيقاف الإجباري")
        case .blockBackground:
            let out = await sh("cmd appops set \(q) RUN_IN_BACKGROUND ignore")
            report(out, success: "تم منع العمل في الخلفية")
        case .disable:
            let out = await sh("pm disable-user --user 0 \(q)")
            report(out, success: "تم التجميد")
        case .enable:
            let out = await sh("pm enable \(q)")
            report(out, success: "تم التفعيل")
        case .uninstall:
            let out = await sh("pm uninstall --user 0 \(q)")
            report(out, success: "تم الحذف")
        case .clearData:
            let out = await sh("pm clear \(q)")
            report(out, success: "تم مسح بيانات التطبيق")
        }
    }

    // MARK: - الأدوات

    private func firstInt(_ line: String) -> Int? {
        for token in line.split(separator: " ") {
            if let v = Int(token) { return v }
        }
        return nil
    }

    func loadStats() async {
        if let m = await sh("cat /proc/meminfo") {
            var total: Int?
            var avail: Int?
            var free: Int?
            for line in m.split(separator: "\n") {
                let l = String(line)
                if l.hasPrefix("MemTotal:") { total = firstInt(l) }
                if l.hasPrefix("MemAvailable:") { avail = firstInt(l) }
                if l.hasPrefix("MemFree:") { free = firstInt(l) }
            }
            if let t = total, let a = avail ?? free {
                mem = MemInfo(totalKB: t, availKB: a)
            }
        }
        if let d = await sh("df /data") {
            let lines = d.split(separator: "\n").map { String($0) }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            if let last = lines.last {
                let tokens = last.split(separator: " ").map { String($0) }
                if tokens.count >= 4, let total = Int(tokens[1]), let used = Int(tokens[2]) {
                    storage = StorageInfo(totalKB: total, usedKB: used)
                }
            }
        }
    }

    func boost() async {
        busy = true
        defer { busy = false }
        _ = await sh("pm trim-caches 999999999999; am kill-all", timeout: 60)
        await loadStats()
        notify("تم تنظيف الذاكرة المؤقتة وإغلاق تطبيقات الخلفية")
    }

    func setAnimationScale(_ scale: String) async {
        let cmd = "settings put global window_animation_scale \(scale); settings put global transition_animation_scale \(scale); settings put global animator_duration_scale \(scale)"
        _ = await sh(cmd)
        notify("تم ضبط سرعة الحركة")
    }

    func castURL(_ raw: String) async {
        var url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.isEmpty { return }
        if !url.contains("://") { url = "https://" + url }
        let out = await sh("am start -a android.intent.action.VIEW -d \(TVSession.quote(url))")
        report(out, success: "تم فتح الرابط على التلفاز")
    }

    func reboot() async {
        _ = await sh("reboot", timeout: 10)
        notify("جارٍ إعادة تشغيل التلفاز")
        disconnect()
    }

    private static func fixCRLF(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        var out = [UInt8]()
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            if bytes[i] == 13 && i + 1 < bytes.count && bytes[i + 1] == 10 {
                out.append(10)
                i += 2
            } else {
                out.append(bytes[i])
                i += 1
            }
        }
        return Data(out)
    }

    func screenshot() async {
        busy = true
        defer { busy = false }
        do {
            var data: Data
            do {
                data = try await client.raw("exec:screencap -p", timeout: 60)
            } catch let e as AdbError {
                if case .rejected = e {
                    let d = try await client.raw("shell:screencap -p", timeout: 60)
                    data = TVSession.fixCRLF(d)
                } else {
                    throw e
                }
            }
            if let img = UIImage(data: data) {
                shot = ShotItem(image: img)
            } else {
                errorMessage = "تعذّر قراءة لقطة الشاشة (قد يمنعها التطبيق المعروض)"
            }
        } catch {
            handle(error)
        }
    }
}
