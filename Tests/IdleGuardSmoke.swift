import Foundation
@main struct IdleSmoke {
    @MainActor static func main() async throws {
        let id = "GPU-test"
        let empty = GPUMetric(id: id, index: 0, name: "Test", utilization: 0, memoryUsed: 100, memoryTotal: 81920, temperature: 30, powerDraw: 40, powerLimit: 400, fan: nil, clockGraphics: 800, clockMemory: 1000, pstate: "P0", details: [:], processes: [])
        var snap = Snapshot(timestamp: Date(), gpus: [empty], hostname: "Test", driverVersion: "Test", cudaVersion: "Test")
        precondition(IdleGuardManager.isIdle(snap))
        var candidate = GPUProcess(id: "candidate", pid: 1, name: "candidate", memoryUsed: nil, gpuUUID: id, type: "设备句柄（容器）", user: "root", command: "", cwd: "")
        snap.gpus[0].processes = [candidate]
        precondition(IdleGuardManager.isIdle(snap))
        for kind in ["C", "G", "M", "宿主机 / C"] {
            candidate.type = kind; snap.gpus[0].processes = [candidate]
            precondition(IdleGuardManager.isIdle(snap))
        }
        for memory: Double? in [1024, 79000, nil] {
            snap.gpus[0] = empty; snap.gpus[0].memoryUsed = memory
            snap.gpus[0].processes = [candidate]
            precondition(IdleGuardManager.isIdle(snap))
        }
        snap.gpus[0] = empty; snap.gpus[0].utilization = 2
        precondition(IdleGuardManager.isIdle(snap))
        snap.gpus[0] = empty; snap.gpus[0].utilization = 2.1
        precondition(!(IdleGuardManager.isIdle(snap)))
        snap.gpus[0] = empty; snap.gpus[0].utilization = nil
        precondition(!(IdleGuardManager.isIdle(snap)))
        for invalid in [-1.0, Double.nan, Double.infinity] {
            snap.gpus[0] = empty; snap.gpus[0].utilization = invalid
            precondition(!IdleGuardManager.isIdle(snap))
        }
        snap.gpus = [empty, empty]; snap.gpus[1].utilization = 3
        precondition(!IdleGuardManager.isIdle(snap))
        snap.gpus = []
        precondition(!IdleGuardManager.isIdle(snap))
        let now = Date()
        precondition(!(IdleGuardManager.thresholdReached(idleSince: now.addingTimeInterval(-17999), now: now)))
        precondition(IdleGuardManager.thresholdReached(idleSince: now.addingTimeInterval(-18000), now: now))
        precondition(!(IdleGuardManager.thresholdReached(idleSince: nil, now: now)))
        print("UTILIZATION_ONLY_HIGH_OR_UNKNOWN_VRAM_EXISTING_PROCESSES_AND_5H_THRESHOLD_OK")
        let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let token = "00C0C5DE-CFE7-4A88-A13B-D7692575447B"
        for (name, source) in [("runner.py",IdleGuardManager.remoteRunner),("launch.py",IdleGuardManager.launchScript(token: token)),("control.py",IdleGuardManager.controlScript(token: token, stop: true)),("preflight.py",IdleGuardManager.preflightScript)] {
            try source.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
    }
}
