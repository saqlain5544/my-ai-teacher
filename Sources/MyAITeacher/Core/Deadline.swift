import Foundation

struct TimeoutError: LocalizedError, Sendable {
    let seconds: Double
    var errorDescription: String? { "Timed out after \(Int(seconds)) s." }
}

/// Runs `work` with a hard deadline. On expiry (or when the caller is cancelled) the work is cancelled and this returns
/// at once, even if the work ignores cancellation: a stuck network read or tool is abandoned, never awaited.
func withDeadline<T: Sendable>(seconds: Double, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
    let race = Race<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            race.attach(cont)
            race.add(Task { do { race.finish(.success(try await work())) } catch { race.finish(.failure(error)) } })
            race.add(Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1e9))
                if !Task.isCancelled { race.finish(.failure(TimeoutError(seconds: seconds))) }
            })
        }
    } onCancel: {
        race.finish(.failure(CancellationError()))
    }
}

/// First result wins; the losers are cancelled. Safe whichever of attach / add / finish happens first.
private final class Race<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<T, Error>?
    private var result: Result<T, Error>?
    private var tasks: [Task<Void, Never>] = []

    func attach(_ c: CheckedContinuation<T, Error>) {
        lock.lock()
        if let r = result { lock.unlock(); c.resume(with: r); return }
        cont = c
        lock.unlock()
    }
    func add(_ t: Task<Void, Never>) {
        lock.lock()
        let done = result != nil
        if !done { tasks.append(t) }
        lock.unlock()
        if done { t.cancel() }
    }
    func finish(_ r: Result<T, Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = r
        let c = cont, ts = tasks
        cont = nil; tasks = []
        lock.unlock()
        ts.forEach { $0.cancel() }
        c?.resume(with: r)
    }
}
