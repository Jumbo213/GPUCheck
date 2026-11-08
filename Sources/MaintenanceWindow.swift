import Foundation

struct UtilizationInterval: Codable {
    var seconds: TimeInterval
    var loads: [Double]
}

struct MaintenanceWindow: Codable {
    var gpuIDs: [String] = []
    var intervals: [UtilizationInterval] = []

    init(gpuIDs: [String] = [], intervals: [UtilizationInterval] = []) {
        self.gpuIDs = gpuIDs
        self.intervals = intervals
    }

    private enum CodingKeys: CodingKey { case gpuIDs, intervals }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let ids = try values.decode([String].self, forKey: .gpuIDs)
        let samples = try values.decode([UtilizationInterval].self, forKey: .intervals)
        let valid = !ids.isEmpty && ids.count == Set(ids).count && samples.allSatisfy {
            $0.seconds.isFinite && $0.seconds > 0 && $0.loads.count == ids.count &&
            $0.loads.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 100 }
        }
        self.init(gpuIDs: valid ? ids : [], intervals: valid ? samples : [])
    }

    var duration: TimeInterval { intervals.reduce(0) { $0 + $1.seconds } }

    var averages: [Double] {
        let seconds = duration
        guard seconds > 0, !gpuIDs.isEmpty else { return [] }
        var totals = Array(repeating: 0.0, count: gpuIDs.count)
        for interval in intervals {
            for index in totals.indices { totals[index] += interval.loads[index] * interval.seconds }
        }
        return totals.map { $0 / seconds }
    }

    func qualifies(requiredDuration: TimeInterval) -> Bool {
        let values = averages
        return duration >= requiredDuration - 0.001 && values.count == gpuIDs.count && !values.isEmpty && values.allSatisfy { $0 < 20 }
    }

    mutating func append(gpuIDs ids: [String], loads: [Double], seconds: TimeInterval, limit: TimeInterval) {
        guard !ids.isEmpty, ids.count == Set(ids).count, ids.count == loads.count,
              loads.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 100 }),
              seconds.isFinite, seconds > 0, limit.isFinite, limit > 0 else { return }
        if gpuIDs != ids { self = MaintenanceWindow(gpuIDs: ids) }
        if intervals.last?.loads == loads {
            intervals[intervals.count - 1].seconds += seconds
        } else {
            intervals.append(UtilizationInterval(seconds: seconds, loads: loads))
        }
        var excess = duration - limit
        while excess > 0, !intervals.isEmpty {
            let removed = min(excess, intervals[0].seconds)
            intervals[0].seconds -= removed
            excess -= removed
            if intervals[0].seconds <= 0 { intervals.removeFirst() }
        }
    }
}
