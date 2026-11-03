import SwiftUI
import AppKit

@main
struct GPUCheckApp: App {
    @StateObject private var store: MonitorStore
    @StateObject private var idle: IdleGuardManager
    init() {
        let monitor = MonitorStore()
        _store = StateObject(wrappedValue: monitor)
        _idle = StateObject(wrappedValue: IdleGuardManager(store: monitor))
    }
    var body: some Scene {
        WindowGroup {
            ContentView(store: store, idle: idle)
                .frame(minWidth: 1080, minHeight: 740)
                .preferredColorScheme(.light)
                .task { store.start(); await captureRequestedWindowIfNeeded() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1320, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .newItem) {
                Button("刷新 GPU 数据") { store.refresh() }.keyboardShortcut("r")
            }
        }
        Settings {
            VStack(alignment: .leading, spacing: 18) {
                Text("GPUCheck").font(.title2.bold())
                Text("每 5 秒采集所有已添加服务器的 GPU 状态，历史记录在本机保存 30 天。应用关闭或 Mac 休眠期间不会采集，图表会保留空缺。")
                Text("通过系统 SSH 连接，支持 SSH 密钥、SSH Agent 与密码。密码仅存入 macOS 钥匙串。当前支持安装了 nvidia-smi 的 NVIDIA 服务器。")
                Button("打开本地数据目录") {
                    let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("GPUCheck")
                    NSWorkspace.shared.open(url)
                }
            }.padding(28).frame(width: 460)
        }
    }
}
