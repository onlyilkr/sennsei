import Foundation

/// "Latest wins" loading: starting a load cancels the previous one, and only the newest load may apply its
/// result, so a slow older load can never overwrite a newer one.
@MainActor
public final class LatestLoader<Value: Sendable> {
    private var generation = 0
    private var task: Task<Void, Never>?

    public init() {}

    public func load(
        produce: @escaping @MainActor @Sendable () async -> Value,
        apply: @escaping @MainActor @Sendable (Value) -> Void
    ) {
        task?.cancel()
        generation += 1
        let mine = generation
        task = Task { [weak self] in
            let value = await produce()
            guard let self, !Task.isCancelled, self.generation == mine else { return }
            apply(value)
        }
    }

    /// Drops the pending load; nothing it produces will be applied.
    public func cancel() {
        task?.cancel()
        task = nil
        generation += 1
    }

    var isIdleForTests: Task<Void, Never>? { task }
}
