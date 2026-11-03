import SwiftUI
import Charts

private enum HistoryMetric: String, CaseIterable {
    case load = "利用率", memory = "显存", temp = "温度", power = "功耗"
    var unit: String { switch self { case .load: return "%"; case .memory: return "GiB"; case .temp: return "°C"; case .power: return "W" } }
    func value(_ sample: HistorySample) -> Double? { switch self { case .load: return sample.utilization; case .memory: return sample.memoryUsed.map { $0 / 1024 }; case .temp: return sample.temperature; case .power: return sample.powerDraw } }
}
private struct ChartPoint: Identifiable {
    let id: UUID; let date: Date; let value: Double; let label: String; let segment: String
}
struct HistoryChartCard: View {
    @ObservedObject var store: MonitorStore
    let server: Server
    let snapshot: Snapshot
    let compact: Bool
    @State private var metric: HistoryMetric = .load
    @State private var range: TimeInterval = 900
    @State private var selectedGPU = "all"
    @State private var hoverDate: Date?
    private let ranges: [(String,TimeInterval)] = [("15 分钟",900),("1 小时",3600),("6 小时",21600),("24 小时",86400),("7 天",604800),("30 天",2592000)]
    var since: Date { Date().addingTimeInterval(-range) }
    private var points: [ChartPoint] {
        var result: [ChartPoint] = []
        for gpu in snapshot.gpus where selectedGPU == "all" || selectedGPU == gpu.id {
            let samples = store.samples(serverID: server.id, gpuUUID: gpu.id, since: since)
            let expected = max(5, range / 1500)
            var last: Date?
            var segment = 0
            for sample in samples {
                guard let value = metric.value(sample), value.isFinite else { segment += 1; last = nil; continue }
                if let previous = last, sample.timestamp.timeIntervalSince(previous) > max(20, expected * 2.5) { segment += 1 }
                result.append(ChartPoint(id: sample.id, date: sample.timestamp, value: value, label: "GPU \(gpu.index)", segment: "\(gpu.id)-\(segment)"))
                last = sample.timestamp
            }
        }
        return result
    }
    var body: some View {
        let data = points
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(compact ? "运行趋势" : "GPU 历史运行情况").font(.system(size: 16, weight: .bold))
                    Text("\(metric.rawValue) · \(metric.unit)").font(.system(size: 10)).foregroundStyle(Color.muted)
                }
                Spacer()
                Picker("指标", selection: $metric) { ForEach(HistoryMetric.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).frame(width: 252)
                Picker("时间范围", selection: $range) { ForEach(ranges, id: \.1) { Text($0.0).tag($0.1) } }.labelsHidden().frame(width: 108)
            }
            if !compact {
                HStack {
                    Picker("显示设备", selection: $selectedGPU) {
                        Text("全部 GPU").tag("all")
                        ForEach(snapshot.gpus) { gpu in Text("GPU \(gpu.index) · \(gpu.name)").tag(gpu.id) }
                    }.frame(maxWidth: 350)
                    Spacer()
                    Text("\(data.count) 个采样点").font(.system(size: 10)).foregroundStyle(Color.muted)
                }
            }
            if data.isEmpty {
                VStack(spacing: 10) { Image(systemName: "chart.xyaxis.line").font(.system(size: 26)).foregroundStyle(Color.accent.opacity(0.5)); Text("正在积累历史数据").font(.system(size: 12, weight: .medium)); Text("连接后每 5 秒记录一次，稍后即可查看趋势。").font(.system(size: 11)).foregroundStyle(Color.muted) }.frame(maxWidth: .infinity).frame(height: compact ? 150 : 290)
            } else {
                chart(data).frame(height: compact ? 165 : 310)
            }
            HStack(spacing: 18) {
                ForEach(snapshot.gpus.filter { selectedGPU == "all" || selectedGPU == $0.id }) { gpu in
                    HStack(spacing: 5) { Circle().fill(gpuColors[gpu.index % gpuColors.count]).frame(width: 6, height: 6); Text("GPU \(gpu.index)").font(.system(size: 10)).foregroundStyle(Color.muted) }
                }
                Spacer()
                if let hoverDate, let nearest = data.min(by: { abs($0.date.timeIntervalSince(hoverDate)) < abs($1.date.timeIntervalSince(hoverDate)) }) {
                    Text("\(nearest.date.formatted(date: .omitted, time: .standard)) · \(nearest.label)  \(numeric(nearest.value, decimals: 1)) \(metric.unit)").font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.muted)
                } else { Text("鼠标移入图表查看采样").font(.system(size: 10)).foregroundStyle(Color.muted.opacity(0.7)) }
            }
        }.padding(22).cardStyle().onChange(of: server.id) { _, _ in selectedGPU = "all"; hoverDate = nil }
    }
    private func chart(_ data: [ChartPoint]) -> some View {
        Chart {
            ForEach(data) { point in
                LineMark(x: .value("时间", point.date), y: .value(metric.rawValue, point.value), series: .value("连续区间", point.segment))
                    .foregroundStyle(by: .value("GPU", point.label)).lineStyle(StrokeStyle(lineWidth: 2)).interpolationMethod(.linear)
                if data.count <= snapshot.gpus.count * 2 { PointMark(x: .value("时间", point.date), y: .value(metric.rawValue, point.value)).foregroundStyle(by: .value("GPU",point.label)).symbolSize(20) }
            }
            if let hoverDate { RuleMark(x: .value("选中",hoverDate)).foregroundStyle(Color.muted.opacity(0.3)).lineStyle(StrokeStyle(lineWidth: 1,dash:[3,3])) }
        }
        .chartForegroundStyleScale(domain: snapshot.gpus.map { "GPU \($0.index)" }, range: snapshot.gpus.map { gpuColors[$0.index % gpuColors.count] })
        .chartLegend(.hidden)
        .chartXScale(domain: since...Date())
        .chartYScale(domain: 0...yMaximum(data))
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: compact ? 5 : 7)) { _ in AxisGridLine().foregroundStyle(Color.line.opacity(0.35)); AxisValueLabel(format: range > 86400 ? .dateTime.month().day().hour() : .dateTime.hour().minute()).font(.system(size: 9)).foregroundStyle(Color.muted) } }
        .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in AxisGridLine(stroke: StrokeStyle(dash:[3,4])).foregroundStyle(Color.line); AxisValueLabel().font(.system(size: 9)).foregroundStyle(Color.muted) } }
        .chartXSelection(value: $hoverDate)
    }
    private func yMaximum(_ data: [ChartPoint]) -> Double {
        if metric == .load { return 100 }
        if metric == .memory { return max(1,snapshot.gpus.compactMap(\.memoryTotal).max().map { $0 / 1024 } ?? 1) }
        if metric == .temp { return max(80, (data.map(\.value).max() ?? 80) * 1.1) }
        return max(100, (data.map(\.value).max() ?? 100) * 1.2)
    }
}
