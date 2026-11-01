import SwiftUI

struct PendingAction: Identifiable {
    let id = UUID()
    let app: TVApp
    let action: TVSession.AppAction
}

struct AppsView: View {
    @EnvironmentObject var tv: TVSession
    @State private var search = ""
    @State private var showSystem = false
    @State private var selected: TVApp?
    @State private var pending: PendingAction?

    private var filtered: [TVApp] {
        if search.isEmpty { return tv.apps }
        return tv.apps.filter { $0.id.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("إظهار تطبيقات النظام", isOn: $showSystem)
                }
                Section(footer: Text("العدد: \(filtered.count)")) {
                    if tv.appsLoading && tv.apps.isEmpty {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    }
                    ForEach(filtered) { app in
                        Button {
                            selected = app
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(app.id)
                                        .font(.subheadline)
                                        .foregroundColor(.primary)
                                    if app.isDisabled {
                                        Text("مجمّد").font(.caption).foregroundColor(.orange)
                                    } else if app.isSystem {
                                        Text("تطبيق نظام").font(.caption).foregroundColor(.secondary)
                                    }
                                }
                                .environment(\.layoutDirection, .leftToRight)
                                Spacer()
                            }
                        }
                    }
                }
            }
            .searchable(text: $search)
            .navigationTitle("التطبيقات")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        Task { await tv.loadApps(includeSystem: showSystem) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .task { await tv.loadApps(includeSystem: showSystem) }
            .onChange(of: showSystem) { _ in
                Task { await tv.loadApps(includeSystem: showSystem) }
            }
            .confirmationDialog(
                selected?.id ?? "",
                isPresented: Binding(
                    get: { selected != nil },
                    set: { newValue in if !newValue { selected = nil } }
                ),
                titleVisibility: .visible,
                presenting: selected
            ) { app in
                Button("فتح على التلفاز") { run(.open, app) }
                Button("إيقاف إجباري") { run(.forceStop, app) }
                Button("منع العمل في الخلفية") { run(.blockBackground, app) }
                if app.isDisabled {
                    Button("تفعيل") { run(.enable, app, reload: true) }
                } else {
                    Button("تجميد (تعطيل)") { run(.disable, app, reload: true) }
                }
                Button("مسح بيانات التطبيق", role: .destructive) {
                    pending = PendingAction(app: app, action: .clearData)
                }
                Button("حذف", role: .destructive) {
                    pending = PendingAction(app: app, action: .uninstall)
                }
                Button("إلغاء", role: .cancel) { }
            }
            .alert(
                "تأكيد",
                isPresented: Binding(
                    get: { pending != nil },
                    set: { newValue in if !newValue { pending = nil } }
                ),
                presenting: pending
            ) { p in
                Button("نعم، نفّذ", role: .destructive) {
                    run(p.action, p.app, reload: true)
                }
                Button("إلغاء", role: .cancel) { }
            } message: { p in
                Text("سيتم تنفيذ هذا الإجراء على \(p.app.id). قد لا يمكن التراجع عنه، وحذف تطبيقات النظام قد يسبب مشاكل في التلفاز.")
            }
        }
    }

    private func run(_ action: TVSession.AppAction, _ app: TVApp, reload: Bool = false) {
        Task {
            await tv.perform(action, on: app.id)
            if reload { await tv.loadApps(includeSystem: showSystem) }
        }
    }
}
