import Foundation

public struct LocalOperationTimeout: LocalizedError, Sendable {
    public let stage: String
    public var errorDescription: String? { RecallLocalization.both(
        "\(stage)等待超时，已有回顾已保留。请稍后重试。",
        "Timed out while \(stage). Saved reviews are preserved. Please retry.") }
}

/// Bounds local queue waits as well as cancellation. An uncooperative worker cannot keep
/// its caller suspended or publish a late result; no task group waits for it on exit.
public enum LocalOperation {
    public static func run<Value: Sendable>(stage: String, timeout: Duration? = .seconds(15),
        operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        let pending = PendingLocalOperation<Value>()
        let result: Value = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                guard pending.install(continuation) else { return }
                let worker = Task.detached(priority: Task.currentPriority) {
                    do {
                        try Task.checkCancellation(); try pending.checkActive()
                        let value = try await operation()
                        try Task.checkCancellation()
                        pending.finish(.success(value))
                    } catch { pending.finish(.failure(error)) }
                }
                pending.attach(worker)
                if let timeout {
                    let timer = Task.detached {
                        do { try await Task.sleep(for: timeout) } catch { return }
                        pending.finish(.failure(LocalOperationTimeout(stage: stage)))
                    }
                    pending.attach(timer)
                }
            }
        }, onCancel: { pending.finish(.failure(CancellationError())) })
        try Task.checkCancellation()
        return result
    }
}

private final class PendingLocalOperation<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var tasks: [Task<Void, Never>] = []
    private var finished = false
    func install(_ value: CheckedContinuation<Value, Error>) -> Bool {
        lock.lock()
        if finished { lock.unlock(); value.resume(throwing: CancellationError()); return false }
        continuation = value; lock.unlock(); return true
    }
    func attach(_ task: Task<Void, Never>) {
        lock.lock()
        if finished { lock.unlock(); task.cancel(); return }
        tasks.append(task); lock.unlock()
    }
    func checkActive() throws {
        lock.lock(); let done = finished; lock.unlock()
        if done { throw CancellationError() }
    }
    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true; let target = continuation; let workers = tasks
        continuation = nil; tasks = []; lock.unlock()
        workers.forEach { $0.cancel() }; target?.resume(with: result)
    }
}
