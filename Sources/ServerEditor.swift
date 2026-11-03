import SwiftUI
import AppKit

struct ServerEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: MonitorStore
    let existing: Server?
    let onSuccess: (String) -> Void
    @State private var name = ""
    @State private var host = ""
    @State private var port = "22"
    @State private var user = "root"
    @State private var identityPath = ""
    @State private var password = ""
    @State private var usePassword = false
    @State private var testing = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                Image(systemName: "server.rack").font(.system(size: 25)).foregroundStyle(Color.accent).frame(width: 52,height: 52).background(Color.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 5) {
                    Text(existing == nil ? "添加服务器" : "编辑服务器").font(.system(size: 22, weight: .bold))
                    Text("连接成功后，立即开始 GPU 监控。").font(.system(size: 12)).foregroundStyle(Color.muted)
                }
                Spacer()
            }
            VStack(alignment: .leading, spacing: 16) {
                field("服务器名称", hint: "例如：训练服务器 A") { TextField("给服务器起一个名字", text: $name) }
                HStack(alignment: .top, spacing: 16) {
                    field("主机地址", hint: "IP、域名或 SSH 配置别名") { TextField("gpu.example.com", text: $host) }
                    field("SSH 端口", hint: "1–65535") { TextField("22", text: $port) }.frame(width: 115)
                }
                field("用户名", hint: nil) { TextField("root", text: $user) }
                VStack(alignment: .leading, spacing: 7) {
                    Text("SSH 私钥（可选）").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.muted)
                    HStack { TextField("留空使用 ~/.ssh/config、默认密钥或 Agent", text: $identityPath).textFieldStyle(.roundedBorder); Button("选择…") { chooseKey() } }
                }
                DisclosureGroup("SSH 密码（可选）", isExpanded: $usePassword) {
                    field("密码", hint: existing == nil ? "仅存入 macOS 钥匙串，不写入配置文件" : "留空保留已保存的密码；未保存时使用密钥") { SecureField("SSH 登录密码", text: $password) }.padding(.top, 8)
                }.font(.system(size: 12))
            }.disabled(testing)
            if let error {
                HStack(alignment: .top, spacing: 8) { Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red); Text(error).textSelection(.enabled).fixedSize(horizontal: false,vertical: true) }.font(.system(size: 11)).foregroundStyle(Color.red).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Color.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
            }
            InfoNote(text: "使用系统 SSH 进行连接，无需在服务器安装代理。首次连接会记录主机指纹；服务器需要提供 nvidia-smi。")
            HStack {
                if testing { ProgressView().controlSize(.small); Text("正在验证 SSH 与 GPU…").font(.system(size: 11)).foregroundStyle(Color.muted) }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(testing)
                Button(existing == nil ? "连接并添加" : "验证并保存") { Task { await submit() } }.buttonStyle(.borderedProminent).tint(Color.accent).keyboardShortcut(.defaultAction).disabled(testing || host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(30).frame(width: 540).foregroundStyle(Color.ink).background(Color.white)
            .onAppear { if let server = existing { name = server.name; host = server.host; port = String(server.port); user = server.user; identityPath = server.identityPath } }
    }
    func field<V: View>(_ label: String, hint: String?, @ViewBuilder content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.muted)
            content().textFieldStyle(.roundedBorder)
            if let hint {
                Text(hint).font(.system(size: 10)).foregroundStyle(Color.muted.opacity(0.8))
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    func chooseKey() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false; panel.showsHiddenFiles = true; panel.message = "选择用于连接服务器的 SSH 私钥"; panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        if panel.runModal() == .OK, let url = panel.url { identityPath = url.path }
    }
    @MainActor func submit() async {
        guard let number = Int(port), (1...65535).contains(number) else { error = "\(existing == nil ? "添加失败" : "保存失败")：请输入 1–65535 之间的端口。"; return }
        testing = true; error = nil
        let server = Server(id: existing?.id ?? UUID(), name: name.trimmingCharacters(in: .whitespacesAndNewlines), host: host.trimmingCharacters(in: .whitespacesAndNewlines), port: number, user: user.trimmingCharacters(in: .whitespacesAndNewlines), identityPath: identityPath.trimmingCharacters(in: .whitespacesAndNewlines))
        do {
            let credential = password.isEmpty ? nil : password
            if existing == nil { try await store.addServer(server, password: credential) } else { try await store.updateServer(server, password: credential) }
            testing = false; dismiss(); onSuccess(existing == nil ? "添加成功：\(server.name)" : "已保存：\(server.name)")
        } catch { testing = false; self.error = "\(existing == nil ? "添加失败" : "保存失败")：\(error.localizedDescription)" }
    }
}
