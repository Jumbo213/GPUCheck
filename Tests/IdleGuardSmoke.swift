import Foundation

actor MockTransport {
    var launches = 0
    var automaticLaunches = 0
    var stops = 0
    var polls = 0
    var delayLaunch = false
    var delayPreflight = false
    var preflights = 0
    var preflightContinuation: CheckedContinuation<Data, Error>?
    var continuation: CheckedContinuation<Data, Error>?
    func delayed() { delayLaunch = true }
    func delayedEnvironment() { delayPreflight = true }
    func failEnvironment() {
        preflightContinuation?.resume(throwing: GPUCheckError("Mock environment check failed"))
        preflightContinuation = nil
    }
    func release() {
        continuation?.resume(returning: Data(#"{"ok":true,"status":"starting","remaining":300}"#.utf8))
        continuation = nil
    }
    func request(_ script: String) async throws -> Data {
        if script.contains("source=base64.b64decode") {
            launches += 1
            if script.contains("automatic=True") { automaticLaunches += 1 }
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
        preflights += 1
        if delayPreflight {
            return try await withCheckedThrowingContinuation { preflightContinuation = $0 }
        }
        return Data(#"{"ok":true,"status":"ready"}"#.utf8)
    }
}

@main struct IdleSmoke {
    static func check(_ value: Bool, _ message: String) { precondition(value, message) }

    @MainActor static func main() async throws {
        var timer = ContinuousIdleTimer()
        let origin = Date()
        let ids = ["a", "b"]
        timer.observe(gpuIDs: ids, loads: [0, 19.9], at: origin, limit: 18000)
        for index in 1..<900 {
            timer.observe(gpuIDs: ids, loads: [0, 19.9], at: origin.addingTimeInterval(Double(index * 20)), limit: 18000)
        }
        check(timer.seconds == 17980 && !timer.qualifies(requiredDuration: 18000), "Five hours must be complete")
        timer.observe(gpuIDs: ids, loads: [0, 19.9], at: origin.addingTimeInterval(18000), limit: 18000)
        check(timer.qualifies(requiredDuration: 18000), "All cards below threshold for five hours qualifies")
        timer.observe(gpuIDs: ids, loads: [0, 21], at: origin.addingTimeInterval(18005), limit: 18000)
        check(timer.seconds == 0 && !timer.qualifies(requiredDuration: 18000), "One busy card clears five hours even if other cards are idle")
        for value in [20.0, 21, 100, -1, Double.nan, Double.infinity] {
            timer.observe(gpuIDs: ids, loads: [0, value], at: origin.addingTimeInterval(18010), limit: 18000)
            check(timer.seconds == 0 && timer.lastSample == nil, "Threshold and invalid readings reset")
        }
        timer.observe(gpuIDs: ids, loads: [1, 2], at: origin.addingTimeInterval(18100), limit: 18000)
        timer.observe(gpuIDs: ids, loads: [1, 2], at: origin.addingTimeInterval(18105), limit: 18000)
        check(timer.seconds == 5, "New low period starts from zero")
        timer.observe(gpuIDs: ids, loads: [1, 2], at: origin.addingTimeInterval(18105), limit: 18000)
        check(timer.seconds == 5, "Repeated snapshot adds no time")
        timer.observe(gpuIDs: ids, loads: [1, 2], at: origin.addingTimeInterval(18140), limit: 18000)
        check(timer.seconds == 0, "Unknown gap breaks continuity")
        timer.observe(gpuIDs: ["new-card"], loads: [0], at: origin.addingTimeInterval(18145), limit: 18000)
        check(timer.seconds == 0 && timer.gpuIDs == ["new-card"], "GPU changes restart timer")
        print("REALTIME_EACH_CARD_STRICT_20_PERCENT_CONTINUOUS_5H_RESET_OK")

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

        let checkingMock = MockTransport()
        let checkingURL = folder.appendingPathComponent("checking.json")
        let checking = IdleGuardManager(store: store, settingsURL: checkingURL, transport: { _, script, _ in try await checkingMock.request(script) })
        try await checking.startNow(for: server)
        await checkingMock.delayedEnvironment()
        let enable = Task { try await checking.setEnabled(true, for: server) }
        for _ in 0..<100 {
            if await checkingMock.preflights == 1 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try await checking.stop(for: server)
        check(checking.states[server.id]?.busy == true && checking.states[server.id]?.isRunning == false, "Environment check remains busy after concurrent stop")
        do {
            try await checking.startNow(for: server)
            preconditionFailure("Pending environment check must block new launch")
        } catch {}
        await checkingMock.failEnvironment()
        do { try await enable.value; preconditionFailure("Environment check should fail") } catch {}
        await checking.refresh()
        let checkingRestored = IdleGuardManager(store: store, settingsURL: checkingURL)
        check(checking.states[server.id]?.busy == false && checkingRestored.states[server.id]?.isRunning == false, "Failed environment check must not restore a stopped task")
        check(await checkingMock.polls == 0, "Stopped task stays absent after failed environment check")
        print("CONCURRENT_ENVIRONMENT_CHECK_AND_STOP_NO_STATE_RESURRECTION_OK")

        let autoMock = MockTransport()
        let autoURL = folder.appendingPathComponent("auto.json")
        let automatic = IdleGuardManager(store: store, settingsURL: autoURL, idleDuration: 60, transport: { _, script, _ in try await autoMock.request(script) })
        try await automatic.setEnabled(true, for: server)
        let now = Date()
        func snapshot(_ time: Date, load: Double?) -> Snapshot {
            let gpu = GPUMetric(id: "GPU-test", index: 0, name: "Test", utilization: load, memoryUsed: 79000, memoryTotal: 81920, temperature: 30, powerDraw: 40, powerLimit: 400, fan: nil, clockGraphics: 800, clockMemory: 1000, pstate: "P0", details: [:], processes: [])
            return Snapshot(timestamp: time, gpus: [gpu], hostname: "Test", driverVersion: "Test", cudaVersion: "Test")
        }
        func feed(_ seconds: Double, _ loads: [Double?]) async {
            let timestamp = now.addingTimeInterval(seconds)
            let base = snapshot(timestamp, load: 0).gpus[0]
            var gpus: [GPUMetric] = []
            for (index, load) in loads.enumerated() {
                var gpu = base
                gpu.id = "GPU-\(index)"; gpu.index = index; gpu.utilization = load
                gpus.append(gpu)
            }
            store.snapshots[server.id] = Snapshot(timestamp: timestamp, gpus: gpus, hostname: "Test", driverVersion: "Test", cudaVersion: "Test")
            await automatic.refresh(now: timestamp)
        }
        await feed(0, [0, 19.9])
        await feed(20, [0, 19.9])
        check(automatic.states[server.id]?.idleSeconds == 20, "All cards low starts counting")
        await feed(40, [0, 21])
        let launchesBeforeThreshold = await autoMock.launches
        check(automatic.states[server.id]?.idleSeconds == 0 && launchesBeforeThreshold == 0, "Single busy card resets; a low cross-card/time average cannot trigger")
        let resetSaved = IdleGuardManager(store: store, settingsURL: autoURL, idleDuration: 60)
        check(resetSaved.states[server.id]?.idleSeconds == 0, "Busy reset persists immediately")
        await feed(60, [0, 0])
        await feed(80, [0, 0])
        await feed(100, [0, 0])
        await feed(120, [0, 20])
        check(automatic.states[server.id]?.isRunning == false && automatic.states[server.id]?.idleSeconds == 0, "Busy at threshold time blocks launch")
        await feed(125, [0, 0])
        await feed(130, [nil, 0])
        check(automatic.states[server.id]?.idleSeconds == 0, "Missing single-card reading clears continuity")
        await feed(135, [0, 0])
        await feed(155, [0, 0])
        store.errors[server.id] = "fixture disconnect"
        await automatic.refresh(now: now.addingTimeInterval(160))
        check(automatic.states[server.id]?.idleSeconds == 0, "Disconnect resets continuous timer")
        store.errors[server.id] = nil
        await feed(165, [0, 0])
        await feed(185, [0, 0])
        await feed(225, [0, 0])
        check(automatic.states[server.id]?.idleSeconds == 0, "Sleep gap resets continuous timer")
        await feed(230, [0, 0])
        await feed(250, [0, 0])
        await automatic.refresh(now: now.addingTimeInterval(275))
        check(automatic.states[server.id]?.idleSeconds == 0, "Stale snapshots cannot maintain continuity")
        await feed(280, [0, 19.9])
        await feed(300, [0, 19.9])
        await feed(320, [0, 19.9])
        let restored = IdleGuardManager(store: store, settingsURL: autoURL, idleDuration: 60)
        check(restored.states[server.id]?.idleSeconds == 40, "New continuous timer is saved")
        await automatic.refresh(now: now.addingTimeInterval(325))
        check(automatic.states[server.id]?.idleSeconds == 40 && automatic.states[server.id]?.isRunning == false, "Duplicate reads do not reach threshold")
        await feed(340, [0, 19.9])
        check(automatic.states[server.id]?.isRunning == true, "Only a complete uninterrupted low period launches")
        check(await autoMock.launches == 1, "Exactly one automatic launch")
        check(await autoMock.automaticLaunches == 1, "Automatic launch requests remote instantaneous recheck")
        try await automatic.stop(for: server)
        print("SINGLE_BUSY_CARD_BLOCKS_RESET_PERSISTENCE_OFFLINE_SLEEP_AND_CONTINUOUS_TRIGGER_OK")

        let exported = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: exported, withIntermediateDirectories: true)
        let token = "00C0C5DE-CFE7-4A88-A13B-D7692575447B"
        for (name, source) in [("runner.py",IdleGuardManager.remoteRunner),("launch.py",IdleGuardManager.launchScript(token: token)),("launch-auto.py",IdleGuardManager.launchScript(token: token, automatic: true)),("control.py",IdleGuardManager.controlScript(token: token, stop: true)),("preflight.py",IdleGuardManager.preflightScript)] {
            try source.write(to: exported.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
    }
}
