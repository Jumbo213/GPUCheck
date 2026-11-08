import Foundation

actor MockTransport {
    var launches = 0
    var stops = 0
    var polls = 0
    var delayLaunch = false
    var continuation: CheckedContinuation<Data, Error>?
    func delayed() { delayLaunch = true }
    func release() {
        continuation?.resume(returning: Data(#"{"ok":true,"status":"starting","remaining":300}"#.utf8))
        continuation = nil
    }
    func request(_ script: String) async throws -> Data {
        if script.contains("source=base64.b64decode") {
            launches += 1
            if delayLaunch {
                return try await withCheckedThrowingContinuation { continuation = $0 }
            }
            return Data(#"{"ok":true,"status":"starting","remaining":300}"#.utf8)
        }
        if script.contains("stop=True") {
            stops += 1
            return Data(#"{"ok":true,"status":"stopped"}"#.utf8)
        }
        if script.contains("stop=False") {
            polls += 1
            return Data(#"{"ok":true,"status":"running","remaining":250}"#.utf8)
        }
        return Data(#"{"ok":true,"status":"ready"}"#.utf8)
    }
}

@main struct IdleSmoke {
    static func check(_ value: Bool, _ message: String) { precondition(value, message) }

    @MainActor static func main() async throws {
        var window = MaintenanceWindow()
        window.append(gpuIDs: ["a", "b"], loads: [10, 0], seconds: 5400, limit: 6000)
        check(!window.qualifies(requiredDuration: 6000), "Requires a full window")
        window.append(gpuIDs: ["a", "b"], loads: [90, 0], seconds: 600, limit: 6000)
        check(window.averages == [18, 0] && window.qualifies(requiredDuration: 6000), "Weighted spike remains eligible")
        window.append(gpuIDs: ["a", "b"], loads: [30, 0], seconds: 6000, limit: 6000)
        check(window.duration == 6000 && window.averages == [30, 0] && !window.qualifies(requiredDuration: 6000), "Rolling window and each-card policy")
        window.append(gpuIDs: ["a", "b"], loads: [20, 0], seconds: 6000, limit: 6000)
        check(!window.qualifies(requiredDuration: 6000), "Exactly 20% does not qualify")
        window.append(gpuIDs: ["a", "b"], loads: [19.9, 19.9], seconds: 6000, limit: 6000)
        check(window.qualifies(requiredDuration: 6000), "Strictly below 20% qualifies")
        for invalid in [-1.0, 101, Double.nan, Double.infinity] {
            window.append(gpuIDs: ["a", "b"], loads: [invalid, 0], seconds: 10, limit: 6000)
        }
        check(window.averages == [19.9, 19.9], "Invalid readings do not enter average")
        window.append(gpuIDs: ["c"], loads: [0], seconds: 5, limit: 6000)
        check(window.duration == 5 && window.gpuIDs == ["c"], "Device changes reset sampling")
        let malformed = try JSONDecoder().decode(MaintenanceWindow.self, from: Data(#"{"gpuIDs":["a","b"],"intervals":[{"seconds":5,"loads":[0]}]}"#.utf8))
        check(malformed.duration == 0, "Invalid persisted intervals safely reset")
        print("ROLLING_TIME_WEIGHTED_PER_GPU_STRICT_20_PERCENT_AND_DEVICE_CHANGE_OK")

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let server = Server(name: "Isolated fixture", host: "gpu.example.com", port: 22)
        try JSONEncoder().encode([server]).write(to: folder.appendingPathComponent("servers.json"))
        let store = MonitorStore(directory: folder)
        let mock = MockTransport()
        let manager = IdleGuardManager(store: store, settingsURL: folder.appendingPathComponent("manual.json"), transport: { _, script, _ in try await mock.request(script) })
        try await manager.startNow(for: server)
        check(manager.states[server.id]?.enabled == false && manager.states[server.id]?.isRunning == true, "Manual start without automatic mode")
        do {
            try await manager.startNow(for: server)
            preconditionFailure("Duplicate start must fail")
        } catch {}
        await manager.refresh()
        let counts = await (mock.launches, mock.stops, mock.polls)
        check(counts == (1, 0, 1), "Auto disabled must not stop manual run")
        try await manager.stop(for: server)
        check(manager.states[server.id]?.isRunning == false && manager.states[server.id]?.busy == false, "Manual stop clears state")
        print("MANUAL_START_WITH_AUTO_OFF_DUPLICATE_REJECTION_AND_STOP_OK")

        let delayed = MockTransport()
        await delayed.delayed()
        let preparing = IdleGuardManager(store: store, settingsURL: folder.appendingPathComponent("preparing.json"), transport: { _, script, _ in try await delayed.request(script) })
        let launch = Task { try await preparing.startNow(for: server) }
        for _ in 0..<100 {
            if await delayed.launches == 1 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        check(preparing.states[server.id]?.busy == true && preparing.states[server.id]?.isRunning == true, "Stop available during preparation")
        try await preparing.stop(for: server)
        await delayed.release()
        try await launch.value
        let cancelledCounts = await (delayed.launches, delayed.stops)
        check(cancelledCounts == (1, 1) && preparing.states[server.id]?.isRunning == false && preparing.states[server.id]?.busy == false, "Late launch reply cannot revive cancelled run")
        let restoredManual = IdleGuardManager(store: store, settingsURL: folder.appendingPathComponent("preparing.json"))
        check(restoredManual.states[server.id]?.isRunning == false, "Cancellation persists")
        print("CANCEL_DURING_PREPARATION_LATE_REPLY_AND_RESTART_OK")

        let autoMock = MockTransport()
        let autoURL = folder.appendingPathComponent("auto.json")
        let automatic = IdleGuardManager(store: store, settingsURL: autoURL, idleDuration: 60, transport: { _, script, _ in try await autoMock.request(script) })
        try await automatic.setEnabled(true, for: server)
        let now = Date()
        func snapshot(_ time: Date, load: Double?) -> Snapshot {
            let gpu = GPUMetric(id: "GPU-test", index: 0, name: "Test", utilization: load, memoryUsed: 79000, memoryTotal: 81920, temperature: 30, powerDraw: 40, powerLimit: 400, fan: nil, clockGraphics: 800, clockMemory: 1000, pstate: "P0", details: [:], processes: [])
            return Snapshot(timestamp: time, gpus: [gpu], hostname: "Test", driverVersion: "Test", cudaVersion: "Test")
        }
        // Three online intervals of 20 s: (0 + 10 + 40) / 3 = 16.67%.
        // A one-hour disconnect between the first and second intervals adds no time.
        store.snapshots[server.id] = snapshot(now, load: 0)
        await automatic.refresh(now: now)
        store.snapshots[server.id] = snapshot(now.addingTimeInterval(20), load: 0)
        await automatic.refresh(now: now.addingTimeInterval(20))
        store.errors[server.id] = "fixture disconnect"
        await automatic.refresh(now: now.addingTimeInterval(25))
        check(automatic.states[server.id]?.idleSeconds == 20, "Disconnect preserves coverage")
        store.errors[server.id] = nil
        store.snapshots[server.id] = snapshot(now.addingTimeInterval(3600), load: 10)
        await automatic.refresh(now: now.addingTimeInterval(3600))
        store.snapshots[server.id] = snapshot(now.addingTimeInterval(3605), load: 10)
        await automatic.refresh(now: now.addingTimeInterval(3605))
        store.snapshots[server.id] = snapshot(now.addingTimeInterval(3625), load: 10)
        await automatic.refresh(now: now.addingTimeInterval(3625))
        check(automatic.states[server.id]?.idleSeconds == 40, "No offline or resume gap credited")
        let restored = IdleGuardManager(store: store, settingsURL: autoURL, idleDuration: 60)
        check(restored.states[server.id]?.idleSeconds == 20, "Last saved sampling checkpoint persists across restart")
        store.snapshots[server.id] = snapshot(now.addingTimeInterval(3645), load: 40)
        await automatic.refresh(now: now.addingTimeInterval(3645))
        check(automatic.states[server.id]?.isRunning == true, "Full low-mean window starts despite current 40% utilization and high VRAM")
        check(await autoMock.launches == 1, "Exactly one automatic launch")
        try await automatic.stop(for: server)
        print("AVERAGE_AUTO_TRIGGER_HIGH_CURRENT_LOAD_OFFLINE_PAUSE_AND_PERSISTENCE_OK")

        let exported = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: exported, withIntermediateDirectories: true)
        let token = "00C0C5DE-CFE7-4A88-A13B-D7692575447B"
        for (name, source) in [("runner.py",IdleGuardManager.remoteRunner),("launch.py",IdleGuardManager.launchScript(token: token)),("control.py",IdleGuardManager.controlScript(token: token, stop: true)),("preflight.py",IdleGuardManager.preflightScript)] {
            try source.write(to: exported.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
    }
}
