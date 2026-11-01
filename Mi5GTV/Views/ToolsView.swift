import SwiftUI

struct StatRow: View {
    let title: String
    let used: Int
    let total: Int

    private func gb(_ kb: Int) -> String {
        return String(format: "%.1f GB", Double(kb) / 1_048_576.0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline)
            ProgressView(value: Double(min(used, total)), total: Double(max(total, 1)))
            Text("\(gb(used)) / \(gb(total))")
                .font(.caption)
                .foregroundColor(.secondary)
                .environment(\.layoutDirection, .leftToRight)
        }
    }
}

struct ShotSheet: View {
    let item: ShotItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Image(uiImage: item.image)
                    .resizable()
                    .scaledToFit()
                    .padding()
            }
            .navigationTitle("لقطة الشاشة")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("إغلاق") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    ShareLink(
                        item: Image(uiImage: item.image),
                        preview: SharePreview("لقطة التلفاز", image: Image(uiImage: item.image))
                    )
                }
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
    }
}

struct ToolsView: View {
    @EnvironmentObject var tv: TVSession
    @State private var url = ""
    @State private var anim = 0
    @State private var confirmReboot = false

    var body: some View {
        NavigationStack {
            Form {
                Section("حالة التلفاز") {
                    if !tv.deviceName.isEmpty {
                        Text(tv.deviceName)
                            .font(.subheadline)
                            .environment(\.layoutDirection, .leftToRight)
                    }
                    if let m = tv.mem {
                        StatRow(title: "الذاكرة العشوائية (RAM)", used: max(m.totalKB - m.availKB, 0), total: m.totalKB)
                    }
                    if let s = tv.storage {
                        StatRow(title: "مساحة التخزين", used: s.usedKB, total: s.totalKB)
                    }
                    Button("تحديث") { Task { await tv.loadStats() } }
                }

                Section("تسريع") {
                    Button {
                        Task { await tv.boost() }
                    } label: {
                        HStack {
                            Text("تنظيف الكاش وإغلاق تطبيقات الخلفية")
                            Spacer()
                            if tv.busy { ProgressView() }
                        }
                    }
                    .disabled(tv.busy)

                    Picker("سرعة حركة القوائم", selection: $anim) {
                        Text("عادي 1x").tag(0)
                        Text("سريع 0.5x").tag(1)
                        Text("فوري 0x").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: anim) { newValue in
                        let scale = newValue == 0 ? "1" : (newValue == 1 ? "0.5" : "0")
                        Task { await tv.setAnimationScale(scale) }
                    }
                }

                Section("إرسال رابط للتلفاز") {
                    TextField("https://…", text: $url)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .environment(\.layoutDirection, .leftToRight)
                    Button("افتح الرابط على التلفاز") {
                        let u = url
                        Task { await tv.castURL(u) }
                    }
                    .disabled(url.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                Section("أخرى") {
                    Button("التقاط صورة لشاشة التلفاز") {
                        Task { await tv.screenshot() }
                    }
                    .disabled(tv.busy)

                    Button("إعادة تشغيل التلفاز", role: .destructive) {
                        confirmReboot = true
                    }
                    Button("قطع الاتصال") { tv.disconnect() }
                }

                Section("عن التطبيق") {
                    Text("نسخة iOS تجريبية مستوحاة من مشروع Mi5G TV (ترخيص MIT) ومشروع Clean Your TV. الاتصال عبر ADB على المنفذ 5555 فقط.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("الأدوات")
            .task { await tv.loadStats() }
            .sheet(item: $tv.shot) { item in
                ShotSheet(item: item)
            }
            .confirmationDialog("إعادة تشغيل التلفاز؟", isPresented: $confirmReboot, titleVisibility: .visible) {
                Button("إعادة التشغيل", role: .destructive) {
                    Task { await tv.reboot() }
                }
                Button("إلغاء", role: .cancel) { }
            }
        }
    }
}
