import Foundation
import SQLite3

@main struct HistoryRecoverySmoke {
    @MainActor static func main() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let server = Server(name: "Offline fixture", host: "127.0.0.1", port: 1)
        try JSONEncoder().encode([server]).write(to: folder.appendingPathComponent("servers.json"))
        let now = Date()
        var legacy: OpaquePointer?
        precondition(sqlite3_open(folder.appendingPathComponent("history.sqlite3").path, &legacy) == SQLITE_OK)
        precondition(sqlite3_exec(legacy, "CREATE TABLE samples (id TEXT PRIMARY KEY, server TEXT NOT NULL, gpu TEXT NOT NULL, timestamp REAL NOT NULL, utilization REAL, memory_used REAL, memory_total REAL, temperature REAL, power REAL);", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(legacy)
        do {
            let history = try HistoryRepository(url: folder.appendingPathComponent("history.sqlite3"))
            let samples = [
                HistorySample(timestamp: now.addingTimeInterval(-86400), serverID: server.id, gpuUUID: "GPU-before-reallocation", utilization: 50, memoryUsed: 70000, memoryTotal: 81920, temperature: 40, powerDraw: 200),
                HistorySample(timestamp: now.addingTimeInterval(-3600), serverID: server.id, gpuUUID: "GPU-after-reallocation", utilization: 0, memoryUsed: 4, memoryTotal: 81920, temperature: 30, powerDraw: 60)
            ]
            try history.insert(samples)
        }
        // No latest.json and an offline server must still expose persisted historical GPU UUIDs.
        let store = MonitorStore(directory: folder)
        let anchor = store.historyEndDate(serverID: server.id)
        precondition(abs(anchor.timeIntervalSince(now.addingTimeInterval(-3600))) < 1)
        let devices = store.historyDevices(serverID: server.id, since: now.addingTimeInterval(-7*86400), until: anchor)
        precondition(Set(devices.map(\.id)) == ["GPU-before-reallocation", "GPU-after-reallocation"])
        store.refresh()
        try await Task.sleep(nanoseconds: 2_000_000_000)
        precondition(store.errors[server.id] != nil)
        precondition(store.historyDevices(serverID: server.id, since: now.addingTimeInterval(-7*86400), until: anchor).count == 2)
        let rebooted = MonitorStore(directory: folder)
        precondition(rebooted.samples(serverID: server.id, gpuUUID: "GPU-before-reallocation", since: now.addingTimeInterval(-7*86400), until: anchor).count == 1)
        let settings = folder.appendingPathComponent("guard.json")
        let encoded = "[\"\(server.id)\",{\"enabled\":true,\"idleSeconds\":17950,\"window\":{\"gpuIDs\":[\"old-gpu\"],\"intervals\":[{\"seconds\":18000,\"loads\":[0]}]}}]"
        try Data(encoded.utf8).write(to: settings)
        let guardManager = IdleGuardManager(store: rebooted, settingsURL: settings)
        precondition(guardManager.states[server.id]?.idleSeconds == 0)
        guardManager.start()
        try await Task.sleep(nanoseconds: 100_000_000)
        precondition(guardManager.states[server.id]?.idleSeconds == 0)
        print("OFFLINE_RESTART_GPU_REALLOCATION_HISTORY_AND_FRESH_CONTINUOUS_TIMER_MIGRATION_OK")
    }
}
