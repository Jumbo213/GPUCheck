import Foundation

struct ContinuousIdleTimer: Codable {
    var gpuIDs: [String] = []
    var seconds: TimeInterval = 0
    var lastSample: Date?

    mutating func reset() {
        seconds = 0
        lastSample = nil
    }

    @discardableResult
    mutating func observe(gpuIDs ids: [String], loads: [Double], at timestamp: Date, limit: TimeInterval) -> Bool {
        guard !ids.isEmpty, ids.count == Set(ids).count, ids.count == loads.count,
              loads.allSatisfy({ $0.isFinite && $0 >= 0 && $0 < 20 }),
              timestamp.timeIntervalSinceReferenceDate.isFinite, limit.isFinite, limit > 0 else {
            reset()
            return false
        }
        if gpuIDs != ids { gpuIDs = ids; reset() }
        if let previous = lastSample {
            let gap = timestamp.timeIntervalSince(previous)
            if gap >= 0 && gap <= 20 && seconds.isFinite && seconds >= 0 {
                seconds = min(limit, seconds + gap)
            } else {
                reset()
            }
        } else {
            seconds = 0
        }
        lastSample = timestamp
        return true
    }

    func qualifies(requiredDuration: TimeInterval) -> Bool {
        lastSample != nil && !gpuIDs.isEmpty && seconds.isFinite && seconds >= requiredDuration
    }
}
