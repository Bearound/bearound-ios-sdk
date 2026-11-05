import Foundation

/// Bounded acquisition. All methods and injected callbacks run on the same serial context.
/// Platform, clocks, timers and durable persistence remain injectable I/O boundaries.
final class FreshLocationBurst<Context> {
    typealias Cancel = () -> Void
    private let elapsed: () -> TimeInterval
    private let wallTime: () -> TimeInterval
    private let eligible: () -> Bool
    private let captureContext: () -> Context?
    private let contextIsCurrent: (Context) -> Bool
    private var context: Context?
    private let schedule: (TimeInterval, @escaping () -> Void) -> Cancel
    private let request: (@escaping (DeviceLocation?) -> Void) -> Cancel
    private let enqueue: (DeviceLocation, Context, @escaping (Bool) -> Void) -> Void
    private var generation = 0
    private var running = false
    private var nextAllowed = -Double.infinity
    private var deadline = 0.0
    private var cancelRequest: Cancel?
    private var cancellations: [Cancel] = []
    private var count = 0
    private var firstTimestamp = 0.0
    private var lastTimestamp = 0.0
    private var burstStartedAt = 0.0
    private var burstWallTime = 0.0
    private var firstFixElapsed = 0.0

    init(elapsed: @escaping () -> TimeInterval, wallTime: @escaping () -> TimeInterval,
         eligible: @escaping () -> Bool,
         captureContext: @escaping () -> Context?, contextIsCurrent: @escaping (Context) -> Bool,
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Cancel,
         request: @escaping (@escaping (DeviceLocation?) -> Void) -> Cancel,
         enqueue: @escaping (DeviceLocation, Context, @escaping (Bool) -> Void) -> Void) {
        self.elapsed = elapsed; self.wallTime = wallTime; self.eligible = eligible
        self.captureContext = captureContext; self.contextIsCurrent = contextIsCurrent
        self.schedule = schedule; self.request = request; self.enqueue = enqueue
    }

    func start() {
        guard !running, eligible(), elapsed() >= nextAllowed,
              let context = captureContext(), contextIsCurrent(context) else { return }
        self.context = context
        burstStartedAt = elapsed(); burstWallTime = wallTime()
        running = true; count = 0; generation += 1
        let token = generation
        nextAllowed = elapsed() + 900
        deadline = elapsed() + 110
        cancellations.append(schedule(110) { [weak self] in
            guard let self, self.generation == token else { return }
            self.stop()
        })
        acquire(token)
    }

    func stop() {
        generation += 1; running = false; context = nil
        cancelRequest?(); cancelRequest = nil
        cancellations.forEach { $0() }; cancellations.removeAll()
    }

    private func acquire(_ token: Int) {
        guard token == generation, let context else { return }
        guard eligible(), contextIsCurrent(context), elapsed() < deadline, clockIsConsistent() else { stop(); return }
        let requestedAt = wallTime()
        let requestDeadline = elapsed() + 10
        var completed = false
        let timeout = schedule(10) { [weak self] in
            guard let self, self.generation == token else { return }
            self.stop()
        }
        cancellations.append(timeout)
        let cancel = request { [weak self] fix in
            guard let self, !completed, token == self.generation else { return }
            completed = true; timeout()
            self.cancelRequest?(); self.cancelRequest = nil
            guard self.elapsed() <= requestDeadline, self.elapsed() <= self.deadline,
                  self.eligible(), self.contextIsCurrent(context), let fix, self.valid(fix, requestedAt: requestedAt) else {
                self.stop(); return
            }
            let acquiredAt = self.elapsed()
            self.enqueue(fix, context) { [weak self] persisted in
                guard let self, token == self.generation else { return }
                guard persisted, self.eligible(), self.contextIsCurrent(context),
                      self.elapsed() < self.deadline, self.clockIsConsistent() else {
                    self.stop(); return
                }
                self.lastTimestamp = Double(fix.timestamp) / 1000
                if self.count == 0 { self.firstTimestamp = self.lastTimestamp; self.firstFixElapsed = acquiredAt }
                self.count += 1
                guard self.count < 3 else { self.stop(); return }
                // Dispatch deadlines are monotonic; wall-clock changes cannot trigger extra requests.
                self.cancellations.append(self.schedule(35) { [weak self] in self?.acquire(token) })
            }
        }
        if completed || token != generation { cancel() } else { cancelRequest = cancel }
    }

    private func clockIsConsistent() -> Bool {
        abs((wallTime() - burstWallTime) - (elapsed() - burstStartedAt)) <= 1
    }

    private func valid(_ fix: DeviceLocation, requestedAt: TimeInterval) -> Bool {
        let timestamp = Double(fix.timestamp) / 1000
        guard clockIsConsistent(), fix.latitude.isFinite, (-90...90).contains(fix.latitude),
              fix.longitude.isFinite, (-180...180).contains(fix.longitude),
              let accuracy = fix.accuracy, accuracy.isFinite, accuracy > 0, accuracy <= 50,
              timestamp >= requestedAt, timestamp <= wallTime(), wallTime() - timestamp <= 15 else { return false }
        return (count == 0 || (timestamp > lastTimestamp && timestamp - lastTimestamp <= 300)) &&
            (count != 2 || (timestamp - firstTimestamp >= 60 && elapsed() - firstFixElapsed >= 60))
    }
}
