import SwiftUI
import Charts
import AppKit

extension Color {
    static let ink = Color(red: 0.10, green: 0.14, blue: 0.23)
    static let muted = Color(red: 0.48, green: 0.52, blue: 0.60)
    static let canvas = Color(red: 0.965, green: 0.973, blue: 0.988)
    static let accent = Color(red: 0.29, green: 0.36, blue: 0.91)
    static let aqua = Color(red: 0.04, green: 0.65, blue: 0.64)
    static let line = Color(red: 0.90, green: 0.92, blue: 0.95)
}
let gpuColors: [Color] = [.accent, .aqua, Color(red: 0.88, green: 0.56, blue: 0.23), Color(red: 0.62, green: 0.39, blue: 0.86), .pink, .blue, .green, .orange]
func numeric(_ value: Double?, decimals: Int = 0) -> String { value.map { String(format: "%.*f", decimals, $0) } ?? "—" }
func memoryGB(_ value: Double?) -> String { numeric(value.map { $0 / 1024 }, decimals: 1) }
func mean(_ items: [Double]) -> Double? { items.isEmpty ? nil : items.reduce(0,+) / Double(items.count) }
func total(_ items: [Double]) -> Double? { items.isEmpty ? nil : items.reduce(0,+) }
func powerRatio(_ gpus: [GPUMetric]) -> Double { guard let limit = total(gpus.compactMap(\.powerLimit)), limit > 0, let draw = total(gpus.compactMap(\.powerDraw)) else { return 0 }; return draw / limit }

enum AppPage: String, CaseIterable {
    case overview = "运行概览", history = "历史趋势", processes = "进程与文件", servers = "服务器管理"
    var icon: String { switch self { case .overview: return "square.grid.2x2"; case .history: return "chart.xyaxis.line"; case .processes: return "terminal"; case .servers: return "server.rack" } }
    var subtitle: String { switch self { case .overview: return "让每一份算力，清晰可见。"; case .history: return "回看负载变化，掌握运行节奏。"; case .processes: return "查看 GPU 正在运行的任务与相关文件。"; case .servers: return "连接你的算力，随时切换。" } }
}
struct ServerEditorItem: Identifiable { var id = UUID(); var server: Server? }
struct GPUSelection: Identifiable { let id = UUID(); let gpu: GPUMetric; let snapshot: Snapshot }
struct ProcessSelection: Identifiable { let id = UUID(); let process: GPUProcess; let server: Server }

struct ContentView: View {
    @ObservedObject var store: MonitorStore
    @ObservedObject var idle: IdleGuardManager
    @State private var page: AppPage = .overview
    @State private var editor: ServerEditorItem?
    @State private var gpuSelection: GPUSelection?
    @State private var processSelection: ProcessSelection?
    @State private var toast: String?
    @State private var removeTarget: Server?
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(spacing: 0) {
                header
                Divider().overlay(Color.line)
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if let warning = store.storageWarning { InfoNote(text: warning) }
                        if page != .servers { serverSwitcher; connectionBanner }
                        switch page {
                        case .overview: overview
                        case .history: historyPage
                        case .processes: processPage
                        case .servers: serverPage
                        }
                    }.padding(28)
                }.background(Color.canvas)
            }
        }
        .font(.system(size: 13)).foregroundStyle(Color.ink)
        .background(Color.white)
        .onAppear {
            idle.start()
            let args = ProcessInfo.processInfo.arguments
            if let index = args.firstIndex(of: "--screenshot-page"), index + 1 < args.count {
                switch args[index + 1] {
                case "processes": page = .processes
                case "history": page = .history
                case "servers": page = .servers
                default: break
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Label(toast, systemImage: toast.hasPrefix("无法") ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .medium)).padding(.horizontal, 20).padding(.vertical, 13)
                    .background(Color.ink, in: Capsule()).foregroundStyle(.white).shadow(color: .black.opacity(0.12), radius: 16, y: 5)
                    .padding(.bottom, 24).transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(item: $editor) { item in
            ServerEditor(store: store, existing: item.server) { message in showToast(message) }
        }
        .sheet(item: $gpuSelection) { selection in GPUDetailsView(gpu: selection.gpu, snapshot: selection.snapshot) }
        .sheet(item: $processSelection) { selection in ProcessDetailsView(store: store, process: selection.process, server: selection.server) }
        .confirmationDialog("移除“\(removeTarget?.name ?? "")”？", isPresented: Binding(get: { removeTarget != nil }, set: { if !$0 { removeTarget = nil } }), titleVisibility: .visible) {
            Button("移除服务器", role: .destructive) { if let server = removeTarget { Task { await removeServer(server) } }; removeTarget = nil }
        } message: { Text("移除后将停止采集该服务器的数据。") }
    }
    var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                if let icon = NSImage(named: "AppIcon") {
                    Image(nsImage: icon).resizable().frame(width: 42, height: 42).clipShape(RoundedRectangle(cornerRadius: 11))
                } else { Image(systemName: "cpu").font(.system(size: 25)).foregroundStyle(Color.accent).frame(width: 42, height: 42) }
                VStack(alignment: .leading, spacing: 3) {
                    Text("GPUCheck").font(.system(size: 20, weight: .bold, design: .rounded))
                    Text("GPU MONITOR").font(.system(size: 8, weight: .semibold)).tracking(2).foregroundStyle(Color.muted)
                }
            }.padding(.top, 38).padding(.bottom, 40).padding(.horizontal, 22)
            Text("工作空间").font(.system(size: 10, weight: .medium)).foregroundStyle(Color.muted).padding(.horizontal, 26).padding(.bottom, 13)
            ForEach(AppPage.allCases, id: \.self) { item in
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { page = item }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: item.icon).font(.system(size: 15, weight: .medium)).frame(width: 20)
                        Text(item.rawValue).fontWeight(page == item ? .semibold : .medium)
                        Spacer()
                        if page == item { Circle().fill(Color.accent).frame(width: 5, height: 5) }
                    }.padding(.horizontal, 15).frame(height: 44)
                        .foregroundStyle(page == item ? Color.accent : Color.muted)
                        .background(page == item ? Color.accent.opacity(0.085) : .clear, in: RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain).padding(.horizontal, 13).padding(.bottom, 5)
            }
            Spacer()
            VStack(alignment: .leading, spacing: 11) {
                HStack { Circle().fill(Color.aqua).frame(width: 6, height: 6); Text("本机持续采集").font(.system(size: 11, weight: .semibold)) }
                Text("5 秒刷新 · 保留 30 天\n关闭应用或休眠时暂停采集")
                    .font(.system(size: 10)).foregroundStyle(Color.muted).lineSpacing(4)
                HStack(spacing: 5) { Image(systemName: "lock.shield"); Text("通过 SSH 安全连接") }.font(.system(size: 10)).foregroundStyle(Color.muted)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Color.canvas, in: RoundedRectangle(cornerRadius: 12)).padding(16)
            HStack { Text("GPUCheck \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.1")"); Spacer(); Text("macOS") }.font(.system(size: 10)).foregroundStyle(Color.muted.opacity(0.7)).padding(.horizontal, 22).padding(.bottom, 20)
        }.frame(width: 214).background(Color.white).overlay(alignment: .trailing) { Rectangle().fill(Color.line).frame(width: 1) }
    }
    var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                Text(page.rawValue).font(.system(size: 25, weight: .bold))
                Text(page.subtitle).font(.system(size: 12)).foregroundStyle(Color.muted)
            }
            Spacer()
            Button { store.refresh() } label: { Image(systemName: "arrow.clockwise").font(.system(size: 14, weight: .medium)).frame(width: 36, height: 36).background(Color.canvas, in: RoundedRectangle(cornerRadius: 10)) }
                .buttonStyle(.plain).help("立即刷新所有服务器 ⌘R")
            Button { editor = ServerEditorItem(server: nil) } label: {
                Label("添加服务器", systemImage: "plus").font(.system(size: 12, weight: .semibold)).padding(.horizontal, 15).frame(height: 36)
            }.buttonStyle(.plain).foregroundStyle(.white).background(Color.accent, in: RoundedRectangle(cornerRadius: 10))
        }.padding(.horizontal, 28).padding(.top, 28).padding(.bottom, 22).background(.white)
    }
    var serverSwitcher: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(store.servers) { server in
                    let active = store.selectedServerID == server.id
                    Button { withAnimation(.easeInOut(duration: 0.18)) { store.selectedServerID = server.id } } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "server.rack").font(.system(size: 17)).foregroundStyle(active ? Color.accent : Color.muted)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(server.name).font(.system(size: 12, weight: .semibold))
                                Text("\(server.host):\(String(server.port))").font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.muted)
                            }
                            Circle().fill(store.errors[server.id] != nil ? Color.orange : (store.snapshots[server.id] != nil ? Color.aqua : Color.muted)).frame(width: 6, height: 6).padding(.leading, 12)
                        }.padding(.horizontal, 15).padding(.vertical, 11)
                            .background(active ? Color.white : Color.white.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(active ? Color.accent.opacity(0.55) : Color.line, lineWidth: 1))
                    }.buttonStyle(.plain)
                }
            }.padding(1)
        }
    }
    @ViewBuilder var connectionBanner: some View {
        if let server = store.selectedServer {
            if let error = store.errors[server.id] {
                HStack(alignment: .top, spacing: 11) {
                    Image(systemName: "wifi.exclamationmark").foregroundStyle(.orange).font(.system(size: 18))
                    VStack(alignment: .leading, spacing: 5) {
                        Text("连接暂时中断").fontWeight(.semibold)
                        Text(error).font(.system(size: 11)).foregroundStyle(Color.muted).textSelection(.enabled)
                        if let date = store.lastUpdated[server.id] { Text("以下为缓存数据 · 最后采集 \(date.formatted(date: .omitted, time: .standard))").font(.system(size: 10)).foregroundStyle(.orange) }
                    }
                    Spacer()
                    Button("编辑连接") { editor = ServerEditorItem(server: server) }.buttonStyle(.borderless)
                }.padding(16).background(Color.orange.opacity(0.065), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }
    @ViewBuilder var overview: some View {
        if let snapshot = store.selectedSnapshot {
            snapshotHeading(snapshot)
            let gpus = snapshot.gpus
            HStack(spacing: 14) {
                MetricCard(title: "平均 GPU 利用率", value: numeric(mean(gpus.compactMap(\.utilization))), unit: "%", icon: "waveform.path", color: .accent, progress: (mean(gpus.compactMap(\.utilization)) ?? 0) / 100, footnote: "\(gpus.count) 张 GPU 实时均值")
                MetricCard(title: "显存使用", value: memoryGB(total(gpus.compactMap(\.memoryUsed))), unit: "GiB", icon: "memorychip", color: .aqua, progress: (total(gpus.compactMap(\.memoryUsed)) ?? 0) / max(1,total(gpus.compactMap(\.memoryTotal)) ?? 1), footnote: "总容量 \(memoryGB(total(gpus.compactMap(\.memoryTotal)))) GiB")
                MetricCard(title: "最高温度", value: numeric(gpus.compactMap(\.temperature).max()), unit: "°C", icon: "thermometer.medium", color: Color(red: 0.88, green: 0.56, blue: 0.23), progress: (gpus.compactMap(\.temperature).max() ?? 0) / 100, footnote: "当前各卡最高温度")
                MetricCard(title: "总功耗", value: numeric(total(gpus.compactMap(\.powerDraw))), unit: "W", icon: "bolt", color: Color(red: 0.62, green: 0.39, blue: 0.86), progress: powerRatio(gpus), footnote: "功耗上限 \(numeric(total(gpus.compactMap(\.powerLimit)))) W")
            }
            if let server = store.selectedServer { HistoryChartCard(store: store, server: server, snapshot: snapshot, compact: true) }
            HStack { Text("GPU 设备").font(.system(size: 16, weight: .bold)); Text("\(gpus.count) 张").font(.system(size: 11)).foregroundStyle(Color.muted); Spacer(); Text("点击设备查看完整参数").font(.system(size: 11)).foregroundStyle(Color.muted) }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14),GridItem(.flexible(), spacing: 14)], spacing: 14) {
                ForEach(gpus) { gpu in GPUCard(gpu: gpu, isStale: store.selectedServerID.flatMap { store.errors[$0] } != nil) { gpuSelection = GPUSelection(gpu: gpu, snapshot: snapshot) } }
            }
            if let server = store.selectedServer { IdleGuardPanel(manager: idle, server: server) }
        } else { waitingView }
    }
    func snapshotHeading(_ snapshot: Snapshot) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(store.selectedServer?.name ?? "服务器").font(.system(size: 18, weight: .bold))
                    StatusPill(text: store.selectedServerID.flatMap { store.errors[$0] } == nil ? "已连接" : "数据已过期", color: store.selectedServerID.flatMap { store.errors[$0] } == nil ? .aqua : .orange)
                }
                Text("\(snapshot.hostname)  ·  NVIDIA 驱动 \(snapshot.driverVersion)  ·  CUDA \(snapshot.cudaVersion)").font(.system(size: 11)).foregroundStyle(Color.muted).textSelection(.enabled)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 5) {
                HStack(spacing: 5) { Circle().fill(Color.aqua).frame(width: 5, height: 5); Text("实时监控").font(.system(size: 10, weight: .medium)) }.foregroundStyle(Color.aqua)
                Text("更新于 \(snapshot.timestamp.formatted(date: .omitted, time: .standard))").font(.system(size: 10)).foregroundStyle(Color.muted)
            }
        }
    }
    @ViewBuilder var historyPage: some View {
        if let server = store.selectedServer, let snapshot = store.selectedSnapshot {
            snapshotHeading(snapshot)
            HistoryChartCard(store: store, server: server, snapshot: snapshot, compact: false)
            InfoNote(text: "历史数据保存在这台 Mac，保留最近 30 天。仅在应用运行且服务器连接正常时采集；离线和休眠期间留空，不补造数据。")
        } else { waitingView }
    }
    @ViewBuilder var processPage: some View {
        if let server = store.selectedServer, let snapshot = store.selectedSnapshot {
            snapshotHeading(snapshot)
            ProcessListView(snapshot: snapshot) { process in processSelection = ProcessSelection(process: process, server: server) }
            InfoNote(text: "显存占用由 NVIDIA 驱动报告。点击进程可读取其启动命令、工作目录和当前打开的文件；已关闭的文件与已加载后关闭的模型权重无法追溯。")
        } else { waitingView }
    }
    var serverPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("我的服务器").font(.system(size: 18, weight: .bold)); Text("\(store.servers.count) 台").foregroundStyle(Color.muted); Spacer() }
            ForEach(store.servers) { server in
                HStack(spacing: 18) {
                    Image(systemName: "server.rack").font(.system(size: 25)).foregroundStyle(Color.accent).frame(width: 56, height: 56).background(Color.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 7) {
                        HStack { Text(server.name).font(.system(size: 15, weight: .semibold)); StatusPill(text: store.errors[server.id] != nil ? "连接失败" : (store.snapshots[server.id] == nil ? "连接中" : "已连接"), color: store.errors[server.id] != nil ? .orange : .aqua) }
                        Text("\(server.user)@\(server.host):\(String(server.port))").font(.system(size: 12, design: .monospaced)).foregroundStyle(Color.muted).textSelection(.enabled)
                        if let snapshot = store.snapshots[server.id] { Text("\(snapshot.gpus.count) 张 GPU · \(snapshot.gpus.first?.name ?? "")").font(.system(size: 11)).foregroundStyle(Color.muted) }
                    }
                    Spacer()
                    Button("查看") { store.selectedServerID = server.id; page = .overview }.buttonStyle(.bordered)
                    Button { editor = ServerEditorItem(server: server) } label: { Image(systemName: "pencil") }.buttonStyle(.bordered).help("重命名或编辑连接")
                    Button { removeTarget = server } label: { Image(systemName: "trash") }.buttonStyle(.bordered).foregroundStyle(Color.muted).help("移除服务器")
                }.padding(20).cardStyle()
            }
            if store.servers.isEmpty { EmptyPanel(icon: "server.rack", title: "添加你的第一台服务器", message: "输入 SSH 连接信息，连接成功后即可开始采集。") }
            if !store.servers.isEmpty {
                Text("可选自动化").font(.system(size: 16, weight: .bold)).padding(.top, 8)
                ForEach(store.servers) { server in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(server.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.muted)
                        IdleGuardPanel(manager: idle, server: server)
                    }
                }
            }
            InfoNote(text: "添加和编辑时会先连接服务器并检查 NVIDIA GPU。支持密钥、SSH Agent 和密码认证；密码保存到 macOS 钥匙串。")
        }
    }
    var waitingView: some View {
        EmptyPanel(icon: store.servers.isEmpty ? "server.rack" : "antenna.radiowaves.left.and.right", title: store.servers.isEmpty ? "还没有服务器" : "正在获取 GPU 数据", message: store.servers.isEmpty ? "点击右上角“添加服务器”开始使用。" : "首次连接需要片刻；若连接失败，上方会显示具体原因。")
            .frame(minHeight: 370)
    }
    func showToast(_ message: String) {
        withAnimation { toast = message }
        Task { try? await Task.sleep(nanoseconds: 3_000_000_000); withAnimation { toast = nil } }
    }
    @MainActor func removeServer(_ server: Server) async {
        do {
            try await idle.setEnabled(false, for: server)
            if store.removeServer(server) { showToast("已移除服务器") }
            else { showToast("无法移除：服务器列表未保存") }
        } catch { showToast("无法移除：\(error.localizedDescription)") }
    }
}

extension View {
    func cardStyle() -> some View { self.background(Color.white, in: RoundedRectangle(cornerRadius: 15)).overlay(RoundedRectangle(cornerRadius: 15).stroke(Color.line.opacity(0.8), lineWidth: 1)) }
}
struct StatusPill: View {
    let text: String; let color: Color
    var body: some View { HStack(spacing: 4) { Circle().fill(color).frame(width: 4, height: 4); Text(text).font(.system(size: 9, weight: .medium)) }.padding(.horizontal, 8).padding(.vertical, 4).foregroundStyle(color).background(color.opacity(0.08), in: Capsule()) }
}
struct InfoNote: View {
    let text: String
    var body: some View { HStack(alignment: .top, spacing: 8) { Image(systemName: "info.circle").padding(.top, 1); Text(text).lineSpacing(4) }.font(.system(size: 11)).foregroundStyle(Color.muted).frame(maxWidth: .infinity, alignment: .leading).padding(15).background(Color.accent.opacity(0.035), in: RoundedRectangle(cornerRadius: 10)) }
}
struct EmptyPanel: View {
    let icon: String; let title: String; let message: String
    var body: some View { VStack(spacing: 14) { Image(systemName: icon).font(.system(size: 34, weight: .light)).foregroundStyle(Color.accent.opacity(0.55)).padding(.bottom, 4); Text(title).font(.system(size: 17, weight: .semibold)); Text(message).font(.system(size: 12)).foregroundStyle(Color.muted).multilineTextAlignment(.center).frame(maxWidth: 470) }.frame(maxWidth: .infinity).padding(44).cardStyle() }
}
struct MetricCard: View {
    let title: String; let value: String; let unit: String; let icon: String; let color: Color; let progress: Double; let footnote: String
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(Color.muted); Spacer(); Image(systemName: icon).font(.system(size: 14)).foregroundStyle(color) }
            HStack(alignment: .firstTextBaseline, spacing: 5) { Text(value).font(.system(size: 31, weight: .semibold, design: .rounded)).monospacedDigit(); Text(unit).font(.system(size: 12)).foregroundStyle(Color.muted) }
            VStack(alignment: .leading, spacing: 9) {
                GeometryReader { geo in ZStack(alignment: .leading) { Capsule().fill(color.opacity(0.09)); Capsule().fill(color.opacity(0.8)).frame(width: max(0,geo.size.width * min(1,max(0,progress)))) } }.frame(height: 4)
                Text(footnote).font(.system(size: 10)).foregroundStyle(Color.muted)
            }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).cardStyle()
    }
}
