import Contracts

/// The one "subtle progress after a while" gate every long operation in the app
/// shares, so they all agree on a single threshold band. Coarse by design: it
/// reports visible/cancellable, never a fraction.
public struct DelayedProgressGate: DelayedProgressGating {
    public let threshold: Duration

    public init(threshold: Duration = .milliseconds(500)) {
        self.threshold = threshold
    }

    public func indication(for state: OperationState) -> ProgressIndication {
        switch state {
        case .settled:
            return .hidden
        case let .running(elapsed, cancellable):
            guard elapsed >= threshold else { return .hidden }
            return ProgressIndication(isVisible: true, offersCancel: cancellable)
        }
    }
}
