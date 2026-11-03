import SwiftUI
import AppKit

private func gpuColor(_ index: Int) -> Color { gpuColors[abs(index) % gpuColors.count] }

struct GPUCard: View {
    let gpu: GPUMetric
    let isStale: Bool
    let action: () -> Void
    private var color: Color { gpuColor(gpu.index) }
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 19) {
                HStack(spacing: 12) {
                    Image(systemName: "cpu").font(.system(size: 20)).foregroundStyle(color)
                        .frame(width: 43, height: 43).background(color.opacity(0.075), in: RoundedRectangle(cornerRadius: 11))
                    VStack(alignment: .leading, spacing: 5) {
                        Text("GPU \(gpu.index)").font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
                        Text(gpu.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    if isStale { StatusPill(text: "缓存", color: .orange) }
                    Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .medium)).foregroundStyle(Color.muted)
                }
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(numeric(gpu.utilization)).font(.system(size: 32, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("%").font(.system(size: 14)).foregroundStyle(Color.muted)
                    Text("GPU 利用率").font(.system(size: 10)).foregroundStyle(Color.muted).padding(.leading, 5)
                    Spacer()
                    Text(gpu.pstate).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(Color.muted)
                }
                VStack(spacing: 9) {
                    bar(value: (gpu.utilization ?? 0) / 100, color: color)
                    HStack {
                        Label("显存", systemImage: "memorychip").font(.system(size: 10)).foregroundStyle(Color.muted)
                        Spacer()
                        Text("\(memoryGB(gpu.memoryUsed)) / \(memoryGB(gpu.memoryTotal)) GiB").font(.system(size: 10, weight: .medium, design: .monospaced))
                    }.padding(.top, 4)
                    bar(value: (gpu.memoryPercent ?? 0) / 100, color: .aqua)
                }
                Divider().overlay(Color.line)
                HStack(spacing: 20) {
                    footMetric("thermometer.medium", numeric(gpu.temperature) + " °C", color: .orange)
                    footMetric("bolt", numeric(gpu.powerDraw) + " W", color: color)
                    Spacer(minLength: 0)
                    Text("\(gpu.processes.count) 个进程").font(.system(size: 10)).foregroundStyle(Color.muted)
                }
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading).cardStyle()
                .contentShape(RoundedRectangle(cornerRadius: 15))
        }.buttonStyle(.plain).help("查看 GPU \(gpu.index) 的完整参数")
    }
    private func bar(value: Double, color: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(color.opacity(0.09))
                Capsule().fill(color.opacity(0.83)).frame(width: geo.size.width * min(1, max(0, value)))
            }
        }.frame(height: 5)
    }
    private func footMetric(_ icon: String, _ value: String, color: Color) -> some View {
        HStack(spacing: 5) { Image(systemName: icon).foregroundStyle(color); Text(value).monospacedDigit() }
            .font(.system(size: 11, weight: .medium))
    }
}

struct GPUDetailsView: View {
    let gpu: GPUMetric
    let snapshot: Snapshot
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var showRaw = false
    private var fields: [String] {
        gpu.details.keys.filter { key in
            (showRaw || !key.hasPrefix("原始 / ")) && (search.isEmpty || key.localizedCaseInsensitiveContains(search) || (gpu.details[key] ?? "").localizedCaseInsensitiveContains(search))
        }.sorted()
    }
    var body: some View {
        VStack(spacing: 0) {
            InspectionHeader(title: "GPU \(gpu.index) · 设备参数", subtitle: gpu.name, dismiss: { dismiss() })
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 12) {
                        smallMetric("GPU 利用率", numeric(gpu.utilization) + " %", color: gpuColor(gpu.index))
                        smallMetric("显存使用", memoryGB(gpu.memoryUsed) + " GiB", color: .aqua)
                        smallMetric("温度", numeric(gpu.temperature) + " °C", color: .orange)
                        smallMetric("功耗", numeric(gpu.powerDraw) + " W", color: .purple)
                    }
                    VStack(spacing: 0) {
                        DetailField(label: "GPU UUID", value: gpu.uuid)
                        DetailField(label: "服务器", value: snapshot.hostname)
                        DetailField(label: "驱动 / CUDA", value: "\(snapshot.driverVersion) / \(snapshot.cudaVersion)")
                        DetailField(label: "显存总容量", value: "\(memoryGB(gpu.memoryTotal)) GiB")
                        DetailField(label: "图形 / 显存时钟", value: "\(numeric(gpu.clockGraphics)) / \(numeric(gpu.clockMemory)) MHz")
                        DetailField(label: "风扇 / 性能状态", value: "\(numeric(gpu.fan)) % / \(gpu.pstate)")
                        DetailField(label: "采集时间", value: snapshot.timestamp.formatted(date: .abbreviated, time: .standard), divider: false)
                    }.padding(.horizontal, 16).cardStyle()
                    HStack {
                        Text("详细参数").font(.system(size: 15, weight: .semibold))
                        Spacer()
                        Toggle("显示全部原始字段", isOn: $showRaw).toggleStyle(.checkbox).font(.system(size: 11))
                    }
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(Color.muted)
                        TextField("搜索参数名称或数值", text: $search).textFieldStyle(.plain)
                        if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Color.muted) }.buttonStyle(.plain) }
                    }.padding(11).background(Color.white, in: RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.line))
                    if fields.isEmpty {
                        Text("没有匹配的参数").font(.system(size: 12)).foregroundStyle(Color.muted).padding(20)
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(fields, id: \.self) { key in DetailField(label: key, value: gpu.details[key] ?? "—", divider: key != fields.last) }
                        }.padding(.horizontal, 16).cardStyle()
                    }
                    InfoNote(text: "参数来自 NVIDIA 驱动。部分设备不支持风扇、ECC、功耗等读数，会显示 N/A 或 —。CUDA 版本为驱动支持的最高版本。")
                }.padding(24)
            }.background(Color.canvas)
        }.frame(width: 820, height: 690).foregroundStyle(Color.ink).background(.white)
    }
    private func smallMetric(_ label: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(label).font(.system(size: 10)).foregroundStyle(Color.muted)
            Text(value).font(.system(size: 20, weight: .semibold, design: .rounded)).foregroundStyle(color).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16).cardStyle()
    }
}

struct ProcessListView: View {
    let snapshot: Snapshot
    let onInspect: (GPUProcess) -> Void
    @State private var search = ""
    private var processes: [GPUProcess] {
        var seen = Set<String>()
        return snapshot.gpus.flatMap(\.processes).filter { seen.insert($0.id).inserted }.filter {
            search.isEmpty || "\($0.pid) \($0.name) \($0.user) \($0.command) \($0.cwd)".localizedCaseInsensitiveContains(search)
        }.sorted { ($0.memoryUsed ?? -1) > ($1.memoryUsed ?? -1) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Text("GPU 进程").font(.system(size: 16, weight: .bold))
                Text("\(snapshot.gpus.flatMap(\.processes).count) 条记录").font(.system(size: 11)).foregroundStyle(Color.muted)
                Spacer()
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Color.muted)
                    TextField("搜索 PID、用户、命令、路径", text: $search).textFieldStyle(.plain)
                }.font(.system(size: 11)).padding(10).frame(width: 250).background(Color.white, in: RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.line))
            }
            if processes.isEmpty {
                EmptyPanel(icon: "terminal", title: search.isEmpty ? "当前没有 GPU 进程" : "没有匹配的进程", message: search.isEmpty ? "驱动未报告正在占用 GPU 的进程。" : "试试 PID、用户名或启动命令中的关键词。")
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Text("任务 / 启动命令").frame(maxWidth: .infinity, alignment: .leading)
                        Text("用户").frame(width: 70, alignment: .leading)
                        Text("GPU").frame(width: 64, alignment: .leading)
                        Text("显存 ↓").frame(width: 86, alignment: .trailing)
                        Color.clear.frame(width: 22)
                    }.font(.system(size: 10, weight: .medium)).foregroundStyle(Color.muted).padding(.horizontal, 20).padding(.vertical, 15)
                    Divider().overlay(Color.line)
                    ForEach(processes) { process in
                        processRow(process)
                        if process.id != processes.last?.id { Divider().overlay(Color.line).padding(.horizontal, 20) }
                    }
                }.cardStyle()
            }
            if snapshot.gpus.flatMap(\.processes).contains(where: { $0.type.contains("容器") || $0.type.contains("句柄") }) {
                InfoNote(text: "驱动进程的 PID 可能来自宿主机；容器设备句柄仅表示进程打开了 NVIDIA 设备，不一定正在计算，显存归属无法确认。")
            }
        }
    }
    private func processRow(_ process: GPUProcess) -> some View {
        let gpu = snapshot.gpus.first { $0.uuid == process.gpuUUID }
        return Button { onInspect(process) } label: {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(process.name.split(separator: "/").last.map(String.init) ?? process.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Text("PID \(String(process.pid))").font(.system(size: 9, design: .monospaced)).foregroundStyle(Color.muted)
                        Text(process.type).font(.system(size: 8, weight: .medium)).foregroundStyle(Color.muted).padding(.horizontal, 5).padding(.vertical, 2).background(Color.canvas, in: Capsule())
                    }
                    Text(process.command.isEmpty ? process.name : process.command).font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.muted).lineLimit(1).truncationMode(.middle)
                    if !process.cwd.isEmpty { Text(process.cwd).font(.system(size: 9, design: .monospaced)).foregroundStyle(Color.muted.opacity(0.85)).lineLimit(1).truncationMode(.middle) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Text(process.user.isEmpty ? "—" : process.user).font(.system(size: 10)).lineLimit(1).frame(width: 70, alignment: .leading)
                Text(gpu.map { "GPU \($0.index)" } ?? "—").font(.system(size: 10, weight: .medium)).foregroundStyle(gpuColor(gpu?.index ?? 0)).frame(width: 64, alignment: .leading)
                Text("\(memoryGB(process.memoryUsed)) GiB").font(.system(size: 11, weight: .medium, design: .monospaced)).frame(width: 86, alignment: .trailing)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .medium)).foregroundStyle(Color.muted).frame(width: 10)
            }.padding(.horizontal, 20).padding(.vertical, 17).contentShape(Rectangle())
        }.buttonStyle(.plain).help("查看进程命令、目录及当前打开的文件")
    }
}

struct ProcessDetailsView: View {
    @ObservedObject var store: MonitorStore
    let process: GPUProcess
    let server: Server
    @Environment(\.dismiss) private var dismiss
    @State private var details: ProcessDetails?
    @State private var error: String?
    @State private var loading = true
    @State private var fileSearch = ""
    private var files: [String] { (details?.files ?? []).filter { fileSearch.isEmpty || $0.localizedCaseInsensitiveContains(fileSearch) } }
    var body: some View {
        VStack(spacing: 0) {
            InspectionHeader(title: "进程 \(String(process.pid))", subtitle: "\(server.name) · \(process.name)", dismiss: { dismiss() })
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if loading {
                        HStack(spacing: 12) { ProgressView().controlSize(.small); Text("正在读取进程与文件信息…").font(.system(size: 12)).foregroundStyle(Color.muted) }.frame(maxWidth: .infinity).padding(55)
                    } else if let error {
                        VStack(alignment: .leading, spacing: 14) {
                            Label("读取失败", systemImage: "exclamationmark.triangle").font(.system(size: 15, weight: .semibold)).foregroundStyle(.orange)
                            Text(error).font(.system(size: 12)).foregroundStyle(Color.muted).textSelection(.enabled)
                            Button("重新读取") { Task { await load() } }.buttonStyle(.bordered)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(22).cardStyle()
                    } else if let details {
                        VStack(spacing: 0) {
                            DetailField(label: "PID / 用户", value: "\(String(details.pid)) / \(details.user)")
                            DetailField(label: "可执行文件", value: details.executable)
                            DetailField(label: "工作目录", value: details.cwd, divider: false)
                        }.padding(.horizontal, 16).cardStyle()
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("完整启动命令").font(.system(size: 13, weight: .semibold))
                                Spacer()
                                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(details.command, forType: .string) } label: { Label("复制", systemImage: "doc.on.doc").font(.system(size: 10)) }.buttonStyle(.borderless)
                            }
                            Text(details.command.isEmpty ? "无法读取" : details.command).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).lineSpacing(5).frame(maxWidth: .infinity, alignment: .leading)
                        }.padding(18).cardStyle()
                        HStack {
                            Text("当前打开或映射的文件").font(.system(size: 14, weight: .semibold))
                            Text("\(details.files.count) 项").font(.system(size: 11)).foregroundStyle(Color.muted)
                            Spacer()
                            HStack(spacing: 6) { Image(systemName: "magnifyingglass").foregroundStyle(Color.muted); TextField("筛选路径", text: $fileSearch).textFieldStyle(.plain) }.font(.system(size: 11)).padding(9).frame(width: 235).background(Color.white, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.line))
                        }
                        if files.isEmpty {
                            Text(fileSearch.isEmpty ? "没有可读取的文件描述符，或进程已结束。" : "没有匹配的文件路径。").font(.system(size: 12)).foregroundStyle(Color.muted).frame(maxWidth: .infinity, alignment: .leading).padding(20).cardStyle()
                        } else {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(files.enumerated()), id: \.offset) { index, path in
                                    HStack(alignment: .top, spacing: 10) {
                                        Image(systemName: "doc.text").font(.system(size: 11)).foregroundStyle(Color.muted).padding(.top, 1)
                                        Text(path).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                    }.padding(.vertical, 11)
                                    if index < files.count - 1 { Divider().overlay(Color.line) }
                                }
                            }.padding(.horizontal, 16).cardStyle()
                        }
                        if !details.note.isEmpty { InfoNote(text: details.note) }
                    }
                    InfoNote(text: "这里展示远端 /proc 中当前可读取的文件描述符与内存映射文件（包括共享库）。模型权重和数据文件若已读入后关闭且未保留映射，通常不会出现在列表；文件路径也不代表该文件单独占用了多少 GPU 显存。")
                }.padding(24)
            }.background(Color.canvas)
        }.frame(width: 820, height: 690).foregroundStyle(Color.ink).background(.white)
            .task { await load() }
    }
    @MainActor private func load() async {
        loading = true; error = nil
        do { details = try await store.inspectProcess(process, server: server) }
        catch { self.error = error.localizedDescription }
        loading = false
    }
}

private struct InspectionHeader: View {
    let title: String
    let subtitle: String
    let dismiss: () -> Void
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.system(size: 21, weight: .bold))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(Color.muted).lineLimit(1)
            }
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.muted).frame(width: 30, height: 30).background(Color.canvas, in: Circle()) }.buttonStyle(.plain).keyboardShortcut(.cancelAction)
        }.padding(24).background(Color.white).overlay(alignment: .bottom) { Rectangle().fill(Color.line).frame(height: 1) }
    }
}

private struct DetailField: View {
    let label: String
    let value: String
    var divider = true
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 20) {
                Text(label).font(.system(size: 11)).foregroundStyle(Color.muted).frame(width: 215, alignment: .leading)
                Text(value.isEmpty ? "—" : value).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.vertical, 12)
            if divider { Divider().overlay(Color.line) }
        }
    }
}
