import Foundation

struct Server: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var host: String
    var port: Int
    var user: String
    var identityPath: String

    init(id: UUID = UUID(), name: String, host: String, port: Int = 22, user: String = "root", identityPath: String = "") {
        self.id = id; self.name = name; self.host = host; self.port = port; self.user = user; self.identityPath = identityPath
    }

    var address: String { "\(user)@\(host):\(port)" }
}

struct GPUMetric: Identifiable, Codable, Sendable {
    var id: String
    var index: Int
    var name: String
    var utilization: Double?
    var memoryUsed: Double?
    var memoryTotal: Double?
    var temperature: Double?
    var powerDraw: Double?
    var powerLimit: Double?
    var fan: Double?
    var clockGraphics: Double?
    var clockMemory: Double?
    var pstate: String
    var details: [String: String]
    var processes: [GPUProcess]
    var uuid: String { id }
    var memoryFree: Double? { guard let total = memoryTotal, let used = memoryUsed else { return nil }; return max(0, total - used) }
    var memoryPercent: Double? { guard let total = memoryTotal, total > 0, let used = memoryUsed else { return nil }; return used / total * 100 }
}

struct GPUProcess: Identifiable, Codable, Sendable {
    var id: String
    var pid: Int
    var name: String
    var memoryUsed: Double?
    var gpuUUID: String
    var type: String
    var user: String
    var command: String
    var cwd: String
}

struct Snapshot: Codable, Sendable {
    var timestamp: Date
    var gpus: [GPUMetric]
    var hostname: String
    var driverVersion: String
    var cudaVersion: String
}

struct HistorySample: Identifiable, Codable, Sendable {
    var id: UUID = UUID()
    var timestamp: Date
    var serverID: UUID
    var gpuUUID: String
    var utilization: Double?
    var memoryUsed: Double?
    var memoryTotal: Double?
    var temperature: Double?
    var powerDraw: Double?
}

struct ProcessDetails: Sendable {
    var pid: Int
    var user: String
    var command: String
    var cwd: String
    var executable: String
    var files: [String]
    var note: String
}

extension ProcessDetails: Decodable {}

struct GPUCheckError: LocalizedError, Sendable {
    var message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}
