import Foundation
import Combine

/// 60-second per-turn timer used in multiplayer. Solo mode uses `elapsedSeconds`
/// on GameState directly; this class is irrelevant there.
@MainActor
public final class ShotClock: ObservableObject {
    public nonisolated static let defaultBudget: TimeInterval = 60

    @Published public private(set) var remaining: TimeInterval
    @Published public private(set) var isRunning: Bool = false
    /// Fires once when remaining hits zero; the view layer triggers auto-pass.
    public var onExpire: (@MainActor () -> Void)?

    private let budget: TimeInterval
    private var deadline: Date?
    private var timer: Timer?

    public init(budget: TimeInterval = ShotClock.defaultBudget) {
        self.budget = budget
        self.remaining = budget
    }

    public func start() {
        stop()
        deadline = Date().addingTimeInterval(budget)
        remaining = budget
        isRunning = true
        // 10Hz tick so the UI countdown reads smooth without burning CPU.
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    public func stop() {
        timer?.invalidate(); timer = nil
        isRunning = false
    }

    public func reset() {
        stop(); remaining = budget; deadline = nil
    }

    private func tick() {
        guard let deadline else { return }
        let r = max(0, deadline.timeIntervalSinceNow)
        remaining = r
        if r <= 0 {
            stop()
            onExpire?()
        }
    }
}
