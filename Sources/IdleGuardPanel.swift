import SwiftUI

struct IdleGuardPanel: View {
    @ObservedObject var manager: IdleGuardManager
    let server: Server
    @State private var localBusy = false
    @State private var error: String?

    private var state: IdleGuardState? { manager.states[server.id] }
    private var enabled: Bool { state?.enabled ?? false }
    private var isRunning: Bool { state?.isRunning ?? false }
    private var busy: Bool { localBusy || (state?.busy ?? false) }

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack(spacing: 12) {
                Image(systemName: "bolt.shield")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(isRunning ? Color.orange : Color.accent)
                    .frame(width: 40, height: 40)
                    .background((isRunning ? Color.orange : Color.accent).opacity(0.075), in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 5) {
                    Text("空闲 GPU 维护").font(.system(size: 15, weight: .semibold))
                    Text("按服务器独立设置 · 默认关闭").font(.system(size: 10)).foregroundStyle(Color.muted)
                }
                Spacer()
                if busy { ProgressView().controlSize(.small).padding(.trailing, 4) }
                Toggle("自动运行", isOn: Binding(get: { enabled }, set: { value in
                    Task { await changeEnabled(value) }
                }))
                .font(.system(size: 11, weight: .medium))
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(Color.accent)
                .disabled(busy)
                .help("仅在这台服务器的全部 GPU 在线空闲累计 5 小时后自动运行")
            }
            Text("全部 GPU 在线空闲累计 5 小时后，以高负载运行 5 分钟。按各卡可用显存调整矩阵和填充大小。")
                .font(.system(size: 12)).foregroundStyle(Color.muted).lineSpacing(4)
            HStack(alignment: .top, spacing: 9) {
                Circle().fill(statusColor).frame(width: 6, height: 6).padding(.top, 4)
                VStack(alignment: .leading, spacing: 5) {
                    Text(state?.status ?? "已关闭").font(.system(size: 11, weight: .semibold)).foregroundStyle(statusColor)
                    if let detail = state?.detail, !detail.isEmpty {
                        Text(detail).font(.system(size: 10)).foregroundStyle(Color.muted).lineSpacing(3).textSelection(.enabled)
                    } else if !enabled {
                        Text("开启后开始检查空闲状态，满足条件才会启动维护。").font(.system(size: 10)).foregroundStyle(Color.muted)
                    }
                    if let until = state?.runningUntil, isRunning {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text("预计剩余 \(countdown(until.timeIntervalSince(context.date)))")
                                .font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(Color.orange).monospacedDigit()
                        }
                    } else if let since = state?.idleSince, enabled {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let elapsed = max(0, context.date.timeIntervalSince(since))
                            Text("已累计在线空闲 \(duration(elapsed)) · 距离启动 \(duration(max(0, 5 * 3600 - elapsed)))")
                                .font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.muted).monospacedDigit()
                        }
                    } else if enabled && (state?.idleSeconds ?? 0) > 0 {
                        Text("已累计在线空闲 \(duration(state?.idleSeconds ?? 0))，恢复采样后继续").font(.system(size: 10)).foregroundStyle(Color.muted)
                    }
                }
                Spacer(minLength: 10)
                if isRunning {
                    Button {
                        Task { await stop() }
                    } label: {
                        Label("停止维护", systemImage: "stop.fill").font(.system(size: 11, weight: .medium))
                    }.buttonStyle(.bordered).tint(.orange).disabled(busy)
                }
            }.padding(13).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.canvas, in: RoundedRectangle(cornerRadius: 10))
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle").padding(.top, 1)
                Text("空闲条件：全部 GPU 利用率 ≤2% 的在线时间累计 5 小时；不检查显存占用或已有进程。断连与休眠暂停计时，重连继续；短暂小负载暂停计时；高于 2% 持续 15 秒或达到 10% 时清零。显存不足时 60 秒后重试。")
                    .lineSpacing(3)
            }.font(.system(size: 10)).foregroundStyle(Color.muted)
            if let error {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 11)).foregroundStyle(.red).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(11)
                    .background(Color.red.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
            }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading).cardStyle()
    }

    private var statusColor: Color {
        if isRunning { return .orange }
        return enabled ? .aqua : .muted
    }

    @MainActor private func changeEnabled(_ value: Bool) async {
        guard !busy else { return }
        localBusy = true; error = nil
        defer { localBusy = false }
        do { try await manager.setEnabled(value, for: server) }
        catch { self.error = error.localizedDescription }
    }

    @MainActor private func stop() async {
        guard !busy else { return }
        localBusy = true; error = nil
        defer { localBusy = false }
        do { try await manager.stop(for: server) }
        catch { self.error = error.localizedDescription }
    }

    private func duration(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded(.down)))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 { return "\(hours) 小时 \(minutes) 分钟" }
        return "\(minutes) 分钟"
    }

    private func countdown(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded(.up)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
