import SwiftUI

/// Add a playlist: Xtream (server, user, password) or an M3U link. Checked against the server before saving.
struct SetupView: View {
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var kind: SourceKind = .xtream
    @State private var name = ""
    @State private var server = ""
    @State private var user = ""
    @State private var pass = ""
    @State private var m3u = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                VStack(spacing: 6) {
                    Text("شاشة").font(.largeTitle.bold()).foregroundStyle(Theme.accent)
                    Text("أضف قائمة التشغيل الخاصة بك").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            Picker("النوع", selection: $kind) {
                Text("Xtream").tag(SourceKind.xtream)
                Text("رابط M3U").tag(SourceKind.m3u)
            }.pickerStyle(.segmented)
            Section("الاسم (اختياري)") { TextField("مثلًا: البيت", text: $name) }
            if kind == .xtream {
                Section("الحساب") {
                    TextField("الخادم http://…", text: $server).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .environment(\.layoutDirection, .leftToRight)
                    TextField("اسم المستخدم", text: $user).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .environment(\.layoutDirection, .leftToRight)
                    SecureField("كلمة المرور", text: $pass).environment(\.layoutDirection, .leftToRight)
                }
            } else {
                Section("الرابط") {
                    TextField("https://…/playlist.m3u", text: $m3u).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .environment(\.layoutDirection, .leftToRight)
                }
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
            Section {
                Button { Task { await add() } } label: {
                    HStack { Spacer(); if busy { ProgressView() } else { Text("إضافة").bold() }; Spacer() }
                }.disabled(busy || (kind == .xtream ? (server.isEmpty || user.isEmpty || pass.isEmpty) : m3u.isEmpty))
            }
            Section { Text("كلمة المرور تُحفظ في سلسلة مفاتيح الآيفون فقط.").font(.footnote).foregroundStyle(.secondary) }
        }
        .navigationTitle("إضافة قائمة")
    }

    private func add() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            if kind == .xtream { try await library.addXtream(name: name, server: server, user: user, pass: pass) }
            else { try await library.addM3U(name: name, url: m3u) }
            dismiss()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
