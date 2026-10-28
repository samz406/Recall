import Foundation

public enum ModelCallCancellation {
    public static func isCancellation(_ error: Error) -> Bool {
        Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
    }
}

public extension LLMResponding {
    /// Wake the caller on cancellation even if an adapter ignores cooperative cancellation.
    /// The underlying request is cancelled too; late responses cannot reach the pipeline.
    func answerCancellably(to request: LLMRequest) async throws -> LLMAnswer {
        try Task.checkCancellation()
        let pending = PendingModelAnswer()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                guard pending.install(continuation) else { return }
                let worker = Task {
                    do {
                        try Task.checkCancellation(); try pending.checkActive()
                        let answer = try await self.answer(to: request)
                        try Task.checkCancellation()
                        pending.finish(.success(answer))
                    } catch {
                        pending.finish(.failure(ModelCallCancellation.isCancellation(error) ? CancellationError() : error))
                    }
                }
                pending.attach(worker)
            }
        }, onCancel: { pending.cancel() })
    }
}

/// The lock protects the continuation, worker ownership and terminal flag together.
/// Resume/cancel outside the lock, exactly once, including cancellation before install.
private final class PendingModelAnswer: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<LLMAnswer, Error>?
    private var worker: Task<Void, Never>?
    private var finished = false

    func install(_ value: CheckedContinuation<LLMAnswer, Error>) -> Bool {
        lock.lock()
        if finished { lock.unlock(); value.resume(throwing: CancellationError()); return false }
        continuation = value; lock.unlock(); return true
    }
    func attach(_ value: Task<Void, Never>) {
        lock.lock()
        if finished { lock.unlock(); value.cancel(); return }
        worker = value; lock.unlock()
    }
    func checkActive() throws {
        lock.lock(); let done = finished; lock.unlock()
        if done { throw CancellationError() }
    }
    func finish(_ result: Result<LLMAnswer, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true; let target = continuation; continuation = nil; worker = nil
        lock.unlock(); target?.resume(with: result)
    }
    func cancel() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true; let target = continuation; let operation = worker
        continuation = nil; worker = nil
        lock.unlock(); operation?.cancel(); target?.resume(throwing: CancellationError())
    }
}
