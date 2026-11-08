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
                    Text("手动随时运行 · 自动按服务器独立设置").font(.system(size: 10)).foregroundStyle(Color.muted)
                }
                Spacer()
                if busy { ProgressView().controlSize(.small).padding(.trailing, 4) }
                Toggle("自动运行", isOn: Binding(get: { enabled }, set: { value in
                    Task { await changeEnabled(value) }
                }))
                .font(.system(size: 11, weight: .medium))
                .toggleStyle(.switch).controlSize(.small).tint(Color.accent)
                .disabled(busy)
                .help("全部 GPU 的实时利用率连续 5 小时均低于 20% 才自动运行")
            }
            Text("全部 GPU 的实时利用率连续 5 小时均低于 20% 时，自动高负载运行 5 分钟。任意一张达到 20% 即重新计时。也可手动立即开始。")
                .font(.system(size: 12)).foregroundStyle(Color.muted).lineSpacing(4)
            HStack(spacing: 10) {
                Button {
                    Task { await startNow() }
                } label: {
                    Label("立即开始", systemImage: "play.fill").font(.system(size: 11, weight: .medium))
                }.buttonStyle(.borderedProminent).tint(Color.accent)
                    .disabled(busy || isRunning)
                    .help("无需开启自动运行，立即启动一次最多 5 分钟的维护")
                Button {
                    Task { await stop() }
                } label: {
                    Label(state?.stopping == true ? "正在结束…" : "结束维护", systemImage: "stop.fill")
                        .font(.system(size: 11, weight: .medium))
                }.buttonStyle(.bordered).tint(.orange)
                    .disabled(!isRunning || state?.stopping == true)
                    .help("准备或运行期间均可结束本次维护")
                Text("自动运行关闭时，也可手动操作")
                    .font(.system(size: 10)).foregroundStyle(Color.muted)
            }
            HStack(alignment: .top, spacing: 9) {
                Circle().fill(statusColor).frame(width: 6, height: 6).padding(.top, 4)
                VStack(alignment: .leading, spacing: 5) {
                    Text(state?.status ?? "自动运行已关闭").font(.system(size: 11, weight: .semibold)).foregroundStyle(statusColor)
                    if let detail = state?.detail, !detail.isEmpty {
                        Text(detail).font(.system(size: 10)).foregroundStyle(Color.muted).lineSpacing(3).textSelection(.enabled)
                    }
                    if let until = state?.runningUntil, isRunning {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text("预计剩余 \(countdown(until.timeIntervalSince(context.date)))")
                                .font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(Color.orange).monospacedDigit()
                        }
                    } else if enabled || (state?.idleSeconds ?? 0) > 0 {
                        Text("连续低于 20% \(duration(state?.idleSeconds ?? 0)) / 5 小时")
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.muted)
                        if let peak = state?.currentLoads.max() {
                            Text(String(format: "当前单卡最高利用率 %.1f%% · 各卡均需 <20%%", peak))
                                .font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.muted)
                        }
                    }
                }
                Spacer(minLength: 10)
            }.padding(13).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.canvas, in: RoundedRectangle(cornerRadius: 10))
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle").padding(.top, 1)
                Text("每 5 秒逐卡检查实时利用率，不检查显存占用。任何一张达到或超过 20%，或断连、休眠、读数缺失，都会重新计时。自动启动前再次检查全部 GPU。维护按可用显存调整负载，每次最长 5 分钟；自动模式资源不足时 60 秒后复查，仍满足连续空闲条件才重试。")
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

    @MainActor private func startNow() async {
        guard !busy && !isRunning else { return }
        localBusy = true; error = nil
        defer { localBusy = false }
        do { try await manager.startNow(for: server) }
        catch { self.error = error.localizedDescription }
    }

    @MainActor private func stop() async {
        guard state?.stopping != true else { return }
        error = nil
        do { try await manager.stop(for: server) }
        catch { self.error = error.localizedDescription }
    }

    private func duration(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded(.down)))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 { return "\(hours) 小时 \(minutes) 分 \(seconds % 60) 秒" }
        if minutes > 0 { return "\(minutes) 分 \(seconds % 60) 秒" }
        return "\(seconds) 秒"
    }

    private func countdown(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded(.up)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
