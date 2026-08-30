import Foundation

public enum MetricState<Value: Equatable>: Equatable {
    case unavailable(reason: String)
    case fresh(Value, observedAt: Date)
    case stale(Value, observedAt: Date, reason: String)
}

public struct LastGoodMetric<Value: Equatable> {
    private var value: Value?
    private var observedAt: Date?
    private var failureReason: String?
    private let unavailableReason: String

    public init(unavailableReason: String) {
        self.unavailableReason = unavailableReason
    }

    public mutating func record(_ value: Value, at date: Date) {
        self.value = value
        observedAt = date
        failureReason = nil
    }

    public mutating func recordFailure(reason: String) {
        failureReason = reason
    }

    public func state(at now: Date, staleAfter: TimeInterval) -> MetricState<Value> {
        guard let value, let observedAt else {
            return .unavailable(reason: failureReason ?? unavailableReason)
        }
        if now.timeIntervalSince(observedAt) >= staleAfter {
            return .stale(value, observedAt: observedAt, reason: failureReason ?? "stale")
        }
        return .fresh(value, observedAt: observedAt)
    }
}
