import SwiftUI

struct RemoteButton: View {
    @EnvironmentObject var tv: TVSession
    var symbol: String? = nil
    var label: String? = nil
    let code: String
    var size: CGFloat = 64
    var tint: Color = .primary

    var body: some View {
        Button {
            tv.pressKey(code)
        } label: {
            ZStack {
                Circle().fill(Color(.secondarySystemBackground))
                if let s = symbol {
                    Image(systemName: s).font(.title2)
                } else if let l = label {
                    Text(l).font(.headline)
                }
            }
            .frame(width: size, height: size)
            .foregroundColor(tint)
        }
        .buttonStyle(.plain)
    }
}

struct RemoteView: View {
    @EnvironmentObject var tv: TVSession
    @State private var text = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    HStack {
                        RemoteButton(symbol: "power", code: "KEYCODE_POWER", tint: .red)
                        Spacer()
                        RemoteButton(symbol: "gearshape.fill", code: "KEYCODE_SETTINGS")
                    }

                    VStack(spacing: 10) {
                        RemoteButton(symbol: "chevron.up", code: "KEYCODE_DPAD_UP", size: 72)
                        HStack(spacing: 10) {
                            RemoteButton(symbol: "chevron.left", code: "KEYCODE_DPAD_LEFT", size: 72)
                            RemoteButton(label: "OK", code: "KEYCODE_DPAD_CENTER", size: 84, tint: .accentColor)
                            RemoteButton(symbol: "chevron.right", code: "KEYCODE_DPAD_RIGHT", size: 72)
                        }
                        RemoteButton(symbol: "chevron.down", code: "KEYCODE_DPAD_DOWN", size: 72)
                    }
                    .padding(.vertical, 8)

                    HStack(spacing: 24) {
                        RemoteButton(symbol: "arrow.uturn.backward", code: "KEYCODE_BACK")
                        RemoteButton(symbol: "house.fill", code: "KEYCODE_HOME")
                        RemoteButton(symbol: "line.3.horizontal", code: "KEYCODE_MENU")
                    }

                    HStack(spacing: 24) {
                        RemoteButton(symbol: "speaker.wave.1.fill", code: "KEYCODE_VOLUME_DOWN")
                        RemoteButton(symbol: "speaker.slash.fill", code: "KEYCODE_VOLUME_MUTE")
                        RemoteButton(symbol: "speaker.wave.3.fill", code: "KEYCODE_VOLUME_UP")
                    }

                    HStack(spacing: 24) {
                        RemoteButton(symbol: "backward.fill", code: "KEYCODE_MEDIA_REWIND")
                        RemoteButton(symbol: "playpause.fill", code: "KEYCODE_MEDIA_PLAY_PAUSE")
                        RemoteButton(symbol: "forward.fill", code: "KEYCODE_MEDIA_FAST_FORWARD")
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("إرسال نص إلى التلفاز").font(.subheadline).foregroundColor(.secondary)
                        HStack {
                            TextField("اكتب هنا (إنجليزي وأرقام)", text: $text)
                                .textFieldStyle(.roundedBorder)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled(true)
                            Button("إرسال") {
                                let t = text
                                text = ""
                                Task { await tv.sendText(t) }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        RemoteButtonRow()
                    }
                }
                .padding()
            }
            .navigationTitle("الريموت")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct RemoteButtonRow: View {
    @EnvironmentObject var tv: TVSession

    var body: some View {
        HStack {
            Button("حذف حرف") { tv.pressKey("KEYCODE_DEL") }
                .buttonStyle(.bordered)
            Button("إدخال/Enter") { tv.pressKey("KEYCODE_ENTER") }
                .buttonStyle(.bordered)
            Spacer()
        }
    }
}
