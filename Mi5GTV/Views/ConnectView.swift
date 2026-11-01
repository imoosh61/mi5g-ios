import SwiftUI

struct ConnectView: View {
    @EnvironmentObject var tv: TVSession
    @State private var scanning = false
    @State private var found: [String] = []
    @State private var scanned = false
    @FocusState private var focused: Bool

    private var isBusy: Bool {
        return tv.state == .connecting || tv.state == .waitingApproval
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("عنوان التلفاز") {
                    TextField("مثال: 192.168.1.50", text: $tv.host)
                        .keyboardType(.numbersAndPunctuation)
                        .autocorrectionDisabled(true)
                        .focused($focused)
                        .environment(\.layoutDirection, .leftToRight)

                    Button {
                        focused = false
                        Task { await tv.connect() }
                    } label: {
                        HStack {
                            Text("اتصال")
                            Spacer()
                            if isBusy { ProgressView() }
                        }
                    }
                    .disabled(isBusy)

                    if tv.state == .connecting {
                        Text("جارٍ الاتصال بالتلفاز…").foregroundColor(.secondary)
                    }
                    if tv.state == .waitingApproval {
                        Text("وافق على النافذة الظاهرة على شاشة التلفاز: اختر «السماح دائمًا» ثم موافق.")
                            .foregroundColor(.orange)
                    }
                }

                Section("بحث تلقائي") {
                    Button {
                        Task {
                            scanning = true
                            found = await LanScanner.scan()
                            scanned = true
                            scanning = false
                        }
                    } label: {
                        HStack {
                            Text("ابحث عن تلفازات في الشبكة")
                            Spacer()
                            if scanning { ProgressView() }
                        }
                    }
                    .disabled(scanning || isBusy)

                    ForEach(found, id: \.self) { ip in
                        Button {
                            tv.host = ip
                        } label: {
                            HStack {
                                Text(ip).environment(\.layoutDirection, .leftToRight)
                                Spacer()
                                Image(systemName: "tv")
                            }
                        }
                    }
                    if scanned && found.isEmpty && !scanning {
                        Text("لم يُعثر على أجهزة. تأكد أن التصحيح عبر الشبكة مفعّل، وأن إذن الشبكة المحلية مسموح للتطبيق، ثم أدخل العنوان يدويًا.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }

                Section("تجهيز التلفاز (مرة واحدة)") {
                    Text("١. اتصل بنفس شبكة الواي فاي التي يتصل بها الجوال.\n٢. من إعدادات التلفاز: حول ← اضغط على «رقم الإصدار/Build» سبع مرات لتفعيل وضع المطور.\n٣. من خيارات المطور فعّل «تصحيح أخطاء USB» (أو التصحيح عبر الشبكة).\n٤. اعرف عنوان IP للتلفاز من إعدادات الشبكة.")
                        .font(.footnote)
                }
            }
            .navigationTitle("Mi5G TV")
        }
    }
}
