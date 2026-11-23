import Foundation

public struct TimeoutError: Error, CustomStringConvertible, Sendable {
    public var seconds: Double
    public var description: String { "Timed out after \(String(format: "%.0f", seconds)) s." }
}

/// Runs `operation` with a hard deadline.
///
/// Unlike a task-group race, this returns at the deadline even if the operation is stuck in a
/// blocking call that ignores cancellation: the operation is cancelled and abandoned.
/// Cancelling the calling task returns immediately with `CancellationError`.
public func withDeadline<T: Sendable>(seconds: Double,
                                      _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let state = DeadlineState<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            state.install(cont)
            let work = Task.detached {
                do { state.finish(.success(try await operation())) } catch { state.finish(.failure(error)) }
            }
            let timer = Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
                if !Task.isCancelled { state.finish(.failure(TimeoutError(seconds: seconds))) }
            }
            state.setTasks(work, timer)
        }
    } onCancel: {
        state.cancel()
    }
}

/// Lock-protected state so exactly one of {result, timeout, cancellation} resumes the continuation.
final class DeadlineState<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<T, Error>?
    private var work: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var finished = false
    private var cancelRequested = false

    func install(_ c: CheckedContinuation<T, Error>) {
        lock.lock()
        cont = c
        let cancelNow = cancelRequested
        lock.unlock()
        if cancelNow { finish(.failure(CancellationError())) }
    }

    func setTasks(_ w: Task<Void, Never>, _ t: Task<Void, Never>) {
        lock.lock()
        if finished {
            lock.unlock()
            w.cancel(); t.cancel()
            return
        }
        work = w; timer = t
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelRequested = true
        let installed = cont != nil
        lock.unlock()
        if installed { finish(.failure(CancellationError())) }
    }

    func finish(_ result: Result<T, Error>) {
        lock.lock()
        guard !finished, let c = cont else { lock.unlock(); return }
        finished = true
        cont = nil
        let w = work, t = timer
        work = nil; timer = nil
        lock.unlock()
        w?.cancel(); t?.cancel()
        c.resume(with: result)
    }
}
