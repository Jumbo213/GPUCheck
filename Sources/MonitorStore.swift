import Foundation
import Combine
import SQLite3

@MainActor
final class MonitorStore: ObservableObject {
    @Published var servers: [Server] = []
    @Published var selectedServerID: UUID? {
        didSet {
            if let selectedServerID { UserDefaults.standard.set(selectedServerID.uuidString, forKey: "GPUCheck.selectedServerID") }
        }
    }
    @Published var snapshots: [UUID: Snapshot] = [:]
    @Published var errors: [UUID: String] = [:]
    @Published var connecting = false
    @Published var history: [HistorySample] = []
    @Published var lastUpdated: [UUID: Date] = [:]
    @Published var refreshing = false
    @Published var storageWarning: String?
    private var inFlight: Set<UUID> = []
    private var pollTask: Task<Void, Never>?
    private let client = SSHClient()
    private var repository: HistoryRepository?
    private let configURL: URL
    private var lastPrune = Date.distantPast
    private var deviceCache: [String: [HistoryDevice]] = [:]
    private var chartCache: [String: [HistorySample]] = [:]
    private var lastSnapshotPersistence: [UUID: Date] = [:]
    private var cachedLatestURL: URL { configURL.deletingLastPathComponent().appendingPathComponent("latest.json") }

    var selectedServer: Server? { servers.first { $0.id == selectedServerID } }
    var selectedSnapshot: Snapshot? { guard let selectedServerID else { return nil }; return snapshots[selectedServerID] }

    init(directory: URL = SSHClient.applicationDirectory) {
        configURL = directory.appendingPathComponent("servers.json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if FileManager.default.fileExists(atPath: configURL.path) {
                let data = try Data(contentsOf: configURL)
                servers = try JSONDecoder().decode([Server].self, from: data)
            } else {
                servers = []
                try persistServers(servers)
            }
            repository = try HistoryRepository(url: directory.appendingPathComponent("history.sqlite3"))
            try repository?.prune(before: Date().addingTimeInterval(-30 * 86400))
            history = repository?.recent(since: Date().addingTimeInterval(-3600)) ?? []
            if let data = try? Data(contentsOf: cachedLatestURL) {
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
                if let cached = try? decoder.decode([UUID: Snapshot].self, from: data) {
                    snapshots = cached.filter { id, _ in servers.contains { $0.id == id } }
                    for (id, snapshot) in snapshots {
                        try repository?.registerDevices(snapshot, serverID: id)
                        lastUpdated[id] = snapshot.timestamp
                        errors[id] = "正在重新连接；当前显示上次采集的数据。"
                    }
                }
            }
        } catch {
            storageWarning = "本地记录读取失败：\(error.localizedDescription)"
        }
        let saved = UserDefaults.standard.string(forKey: "GPUCheck.selectedServerID").flatMap(UUID.init(uuidString:))
        selectedServerID = servers.contains(where: { $0.id == saved }) ? saved : servers.first?.id
    }

    deinit { pollTask?.cancel() }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard self != nil else { return }
                self?.refresh()
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
            }
        }
    }

    func refresh() { Task { await poll() } }

    private func poll() async {
        let targets = servers.filter { !inFlight.contains($0.id) }
        guard !targets.isEmpty else { return }
        inFlight.formUnion(targets.map(\.id))
        refreshing = true
        defer { refreshing = !inFlight.isEmpty }
        await withTaskGroup(of: (Server, Result<Snapshot, Error>).self) { group in
            for server in targets {
                group.addTask { [client] in
                    do { return (server, .success(try await client.fetch(server))) }
                    catch { return (server, .failure(error)) }
                }
            }
            for await (server, result) in group {
                inFlight.remove(server.id)
                guard servers.contains(server) else { continue }
                switch result {
                case .success(let snapshot): record(snapshot, for: server)
                case .failure(let error): errors[server.id] = error.localizedDescription
                }
            }
        }
        if Date().timeIntervalSince(lastPrune) > 3600 {
            do { try repository?.prune(before: Date().addingTimeInterval(-30 * 86400)); lastPrune = Date() }
            catch { storageWarning = "历史清理失败：\(error.localizedDescription)" }
        }
    }

    func addServer(_ server: Server, password: String?) async throws {
        guard !connecting else { throw GPUCheckError("正在测试另一个连接，请稍候。") }
        try SSHClient.validate(server)
        guard !servers.contains(where: { $0.id == server.id }) else { throw GPUCheckError("此服务器已经存在。") }
        connecting = true; defer { connecting = false }
        let previousPassword = try SSHKeychain.read(account: server.id.uuidString)
        let changedPassword = password.map { !$0.isEmpty } ?? false
        if let password, !password.isEmpty { try SSHKeychain.save(password, account: server.id.uuidString) }
        do {
            let snapshot = try await client.fetch(server)
            let updated = servers + [server]
            try persistServers(updated)
            servers = updated; selectedServerID = server.id
            record(snapshot, for: server)
        } catch {
            if changedPassword { restorePassword(previousPassword, for: server) }
            throw error
        }
    }

    func updateServer(_ server: Server, password: String?) async throws {
        guard !connecting else { throw GPUCheckError("正在测试另一个连接，请稍候。") }
        try SSHClient.validate(server)
        guard servers.contains(where: { $0.id == server.id }) else { throw GPUCheckError("服务器已被移除。") }
        connecting = true; defer { connecting = false }
        let previousPassword = try SSHKeychain.read(account: server.id.uuidString)
        let changedPassword = password.map { !$0.isEmpty } ?? false
        if let password, !password.isEmpty { try SSHKeychain.save(password, account: server.id.uuidString) }
        do {
            let snapshot = try await client.fetch(server)
            guard let currentIndex = servers.firstIndex(where: { $0.id == server.id }) else { throw GPUCheckError("服务器已被移除。") }
            var updated = servers; updated[currentIndex] = server
            try persistServers(updated); servers = updated
            record(snapshot, for: server)
        } catch {
            if changedPassword { restorePassword(previousPassword, for: server) }
            throw error
        }
    }

    private func restorePassword(_ password: String?, for server: Server) {
        if let password { try? SSHKeychain.save(password, account: server.id.uuidString) }
        else { SSHKeychain.delete(account: server.id.uuidString) }
    }

    @discardableResult
    func removeServer(_ server: Server) -> Bool {
        let updated = servers.filter { $0.id != server.id }
        do {
            try persistServers(updated)
            servers = updated; snapshots[server.id] = nil; errors[server.id] = nil; lastUpdated[server.id] = nil
            if selectedServerID == server.id { selectedServerID = servers.first?.id }
            SSHKeychain.delete(account: server.id.uuidString)
            // Historic measurements remain available on disk for their normal 30-day retention.
            return true
        } catch { errors[server.id] = "无法保存服务器列表：\(error.localizedDescription)"; return false }
    }

    func inspectProcess(_ process: GPUProcess, server: Server) async throws -> ProcessDetails {
        try await client.inspect(process, server: server)
    }

    func historyEndDate(serverID: UUID) -> Date {
        if errors[serverID] == nil, snapshots[serverID] != nil { return Date() }
        let latest = max(lastUpdated[serverID] ?? .distantPast, repository?.latestDate(serverID: serverID) ?? .distantPast)
        return latest == .distantPast ? Date() : latest
    }

    func historyDevices(serverID: UUID, since: Date, until: Date) -> [HistoryDevice] {
        let key = "\(serverID)|\(Int(since.timeIntervalSince1970 / 30))|\(Int(until.timeIntervalSince1970 / 30))"
        if let cached = deviceCache[key] { return cached }
        let values = repository?.devices(serverID: serverID, since: since, until: until) ?? []
        if deviceCache.count > 100 { deviceCache.removeAll(keepingCapacity: true) }
        deviceCache[key] = values
        return values
    }

    func samples(serverID: UUID, gpuUUID: String, since: Date, until: Date = Date()) -> [HistorySample] {
        let key = "\(serverID)|\(gpuUUID)|\(Int(since.timeIntervalSince1970 / 30))|\(Int(until.timeIntervalSince1970 / 30))"
        if let cached = chartCache[key] { return cached }
        let values = repository?.samples(serverID: serverID, gpuUUID: gpuUUID, since: since, until: until) ?? history.filter { $0.serverID == serverID && $0.gpuUUID == gpuUUID && $0.timestamp >= since && $0.timestamp <= until }
        if chartCache.count > 100 { chartCache.removeAll(keepingCapacity: true) }
        chartCache[key] = values
        return values
    }

    private func record(_ snapshot: Snapshot, for server: Server) {
        deviceCache.removeAll(keepingCapacity: true)
        chartCache.removeAll(keepingCapacity: true)
        snapshots[server.id] = snapshot; errors[server.id] = nil; lastUpdated[server.id] = snapshot.timestamp
        let samples = snapshot.gpus.map { gpu in
            HistorySample(timestamp: snapshot.timestamp, serverID: server.id, gpuUUID: gpu.id, utilization: gpu.utilization, memoryUsed: gpu.memoryUsed, memoryTotal: gpu.memoryTotal, temperature: gpu.temperature, powerDraw: gpu.powerDraw)
        }
        do { try repository?.insert(samples); try repository?.registerDevices(snapshot, serverID: server.id) }
        catch { storageWarning = "历史记录保存失败：\(error.localizedDescription)" }
        history.removeAll { $0.timestamp < Date().addingTimeInterval(-3600) }
        history.append(contentsOf: samples)
        if Date().timeIntervalSince(lastSnapshotPersistence[server.id] ?? .distantPast) >= 30 {
            do {
                // Preserve hardware identities for offline history; never cache command lines or file lists.
                var cached = snapshots
                for id in cached.keys {
                    guard var value = cached[id] else { continue }
                    for index in value.gpus.indices { value.gpus[index].processes = [] }
                    cached[id] = value
                }
                let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970
                try encoder.encode(cached).write(to: cachedLatestURL, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cachedLatestURL.path)
                lastSnapshotPersistence[server.id] = Date()
            } catch { storageWarning = "最近设备信息保存失败：\(error.localizedDescription)" }
        }
    }

    private func persistServers(_ values: [Server]) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(values).write(to: configURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
    }
}

final class HistoryRepository {
    private var database: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        if sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            if let database { sqlite3_close(database) }; database = nil
            throw GPUCheckError("无法打开本地历史数据库。")
        }
        sqlite3_busy_timeout(database, 3000)
        try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
        try execute("CREATE TABLE IF NOT EXISTS samples (id TEXT PRIMARY KEY, server TEXT NOT NULL, gpu TEXT NOT NULL, timestamp REAL NOT NULL, utilization REAL, memory_used REAL, memory_total REAL, temperature REAL, power REAL);")
        try execute("CREATE INDEX IF NOT EXISTS sample_lookup ON samples(server,gpu,timestamp); CREATE INDEX IF NOT EXISTS sample_time ON samples(timestamp);")
        try execute("CREATE INDEX IF NOT EXISTS sample_server_time ON samples(server,timestamp,gpu);")
        try execute("CREATE TABLE IF NOT EXISTS gpu_devices (server TEXT NOT NULL, gpu TEXT NOT NULL, gpu_index INTEGER, name TEXT, PRIMARY KEY(server,gpu));")
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    deinit { if let database { sqlite3_close(database) } }

    func insert(_ values: [HistorySample]) throws {
        guard !values.isEmpty else { return }
        try execute("BEGIN IMMEDIATE;")
        do {
            let statement = try prepare("INSERT INTO samples VALUES(?,?,?,?,?,?,?,?,?);")
            defer { sqlite3_finalize(statement) }
            for sample in values {
                sqlite3_reset(statement); sqlite3_clear_bindings(statement)
                bind(sample.id.uuidString, 1, statement); bind(sample.serverID.uuidString, 2, statement); bind(sample.gpuUUID, 3, statement)
                sqlite3_bind_double(statement, 4, sample.timestamp.timeIntervalSince1970)
                bind(sample.utilization, 5, statement); bind(sample.memoryUsed, 6, statement); bind(sample.memoryTotal, 7, statement)
                bind(sample.temperature, 8, statement); bind(sample.powerDraw, 9, statement)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw GPUCheckError("写入历史记录失败。") }
            }
            try execute("COMMIT;")
        } catch { try? execute("ROLLBACK;"); throw error }
    }

    func prune(before: Date) throws {
        let statement = try prepare("DELETE FROM samples WHERE timestamp < ?;"); defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, before.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw GPUCheckError("历史清理失败。") }
    }

    func recent(since: Date) -> [HistorySample] {
        guard let statement = try? prepare("SELECT id,server,gpu,timestamp,utilization,memory_used,memory_total,temperature,power FROM samples WHERE timestamp >= ? ORDER BY timestamp LIMIT 30000;") else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, since.timeIntervalSince1970)
        var result: [HistorySample] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let server = UUID(uuidString: string(statement, 1)) else { continue }
            result.append(HistorySample(id: UUID(uuidString: string(statement, 0)) ?? UUID(), timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)), serverID: server, gpuUUID: string(statement, 2), utilization: number(statement, 4), memoryUsed: number(statement, 5), memoryTotal: number(statement, 6), temperature: number(statement, 7), powerDraw: number(statement, 8)))
        }
        return result
    }

    func registerDevices(_ snapshot: Snapshot, serverID: UUID) throws {
        let statement = try prepare("INSERT INTO gpu_devices VALUES(?,?,?,?) ON CONFLICT(server,gpu) DO UPDATE SET gpu_index=excluded.gpu_index,name=excluded.name;")
        defer { sqlite3_finalize(statement) }
        for gpu in snapshot.gpus {
            sqlite3_reset(statement); sqlite3_clear_bindings(statement)
            bind(serverID.uuidString, 1, statement); bind(gpu.id, 2, statement)
            sqlite3_bind_int(statement, 3, Int32(gpu.index)); bind(gpu.name, 4, statement)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw GPUCheckError("设备历史信息保存失败。") }
        }
    }

    func latestDate(serverID: UUID) -> Date? {
        guard let statement = try? prepare("SELECT MAX(timestamp) FROM samples WHERE server=?;") else { return nil }
        defer { sqlite3_finalize(statement) }; bind(serverID.uuidString, 1, statement)
        guard sqlite3_step(statement) == SQLITE_ROW, let time = number(statement, 0) else { return nil }
        return Date(timeIntervalSince1970: time)
    }

    func devices(serverID: UUID, since: Date, until: Date) -> [HistoryDevice] {
        let sql = "SELECT s.gpu,d.gpu_index,d.name,MAX(s.memory_total),MAX(s.timestamp) FROM samples s LEFT JOIN gpu_devices d ON d.server=s.server AND d.gpu=s.gpu WHERE s.server=? AND s.timestamp>=? AND s.timestamp<=? GROUP BY s.gpu ORDER BY MAX(s.timestamp) DESC,s.gpu;"
        guard let statement = try? prepare(sql) else { return [] }
        defer { sqlite3_finalize(statement) }
        bind(serverID.uuidString, 1, statement)
        sqlite3_bind_double(statement, 2, since.timeIntervalSince1970); sqlite3_bind_double(statement, 3, until.timeIntervalSince1970)
        var values: [HistoryDevice] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            values.append(HistoryDevice(id: string(statement, 0), index: number(statement, 1).map(Int.init), name: string(statement, 2), memoryTotal: number(statement, 3), lastSeen: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))))
        }
        return values
    }

    func samples(serverID: UUID, gpuUUID: String, since: Date, until: Date = Date()) -> [HistorySample] {
        // Aggregate long ranges while preserving chronology; no forward-fill across outages.
        let duration = max(1, until.timeIntervalSince(since))
        let bucket = max(1, ceil(duration.rounded() / 1500))
        let sql = "SELECT MIN(id),MIN(timestamp),AVG(utilization),AVG(memory_used),MAX(memory_total),AVG(temperature),AVG(power) FROM samples WHERE server=? AND gpu=? AND timestamp>=? AND timestamp<=? GROUP BY CAST(timestamp/? AS INTEGER) ORDER BY MIN(timestamp);"
        guard let statement = try? prepare(sql) else { return [] }
        defer { sqlite3_finalize(statement) }
        bind(serverID.uuidString, 1, statement); bind(gpuUUID, 2, statement)
        sqlite3_bind_double(statement, 3, since.timeIntervalSince1970); sqlite3_bind_double(statement, 4, until.timeIntervalSince1970); sqlite3_bind_double(statement, 5, bucket)
        var result: [HistorySample] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(HistorySample(id: UUID(uuidString: string(statement, 0)) ?? UUID(), timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)), serverID: serverID, gpuUUID: gpuUUID, utilization: number(statement, 2), memoryUsed: number(statement, 3), memoryTotal: number(statement, 4), temperature: number(statement, 5), powerDraw: number(statement, 6)))
        }
        return result
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw GPUCheckError("数据库操作失败：\(database.map { String(cString: sqlite3_errmsg($0)) } ?? "database closed")") }
    }
    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw GPUCheckError("无法读取历史数据库。") }
        return statement
    }
    private func bind(_ value: String, _ index: Int32, _ statement: OpaquePointer) { _ = value.withCString { sqlite3_bind_text(statement, index, $0, -1, transient) } }
    private func bind(_ value: Double?, _ index: Int32, _ statement: OpaquePointer) {
        if let value { sqlite3_bind_double(statement, index, value) } else { sqlite3_bind_null(statement, index) }
    }
    private func string(_ statement: OpaquePointer, _ index: Int32) -> String { sqlite3_column_text(statement, index).map { String(cString: $0) } ?? "" }
    private func number(_ statement: OpaquePointer, _ index: Int32) -> Double? { sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : sqlite3_column_double(statement, index) }
}
