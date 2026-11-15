import Foundation

struct PersonaWorkDeferred: Error {}

/// Foreground requests never wait for optional persona work. One background request at a time;
/// starting any foreground model call cancels it, leaving its durable checkpoint queued.
actor ModelRequestPriority {
    static let shared = ModelRequestPriority()
    private var foreground = 0
    private var background: Task<LLMAnswer, Error>?

    func foregroundAnswer(_ operation: @Sendable () async throws -> LLMAnswer) async throws -> LLMAnswer {
        foreground += 1; background?.cancel()
        defer { foreground -= 1 }
        return try await operation()
    }
    func backgroundAnswer(_ operation: @escaping @Sendable () async throws -> LLMAnswer) async throws -> LLMAnswer {
        guard foreground == 0, background == nil else { throw PersonaWorkDeferred() }
        let task = Task(priority: .utility) {
            try await withThrowingTaskGroup(of: LLMAnswer.self) { group in
                group.addTask { try await operation() }
                group.addTask { try await Task.sleep(for: .seconds(45)); throw URLError(.timedOut) }
                defer { group.cancelAll() }
                return try await group.next()!
            }
        }
        background = task
        defer { background = nil }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
}
