import Foundation
import ReaderCore

/// One writer, with at most one pending snapshot. Revisions are assigned on the
/// main actor; encoding and the atomic write never run on the main actor.
@MainActor final class LibraryPersistence {
    typealias Writer = @Sendable (LibraryState, URL) throws -> Void
    private struct Snapshot: Sendable {
        let revision: UInt64
        let state: LibraryState
        let reportError: Bool
    }
    private let url: URL
    private let writer: Writer
    private var requested: LibraryState?
    private var pending: Snapshot?
    private var task: Task<Void, Never>?
    private var completedRevision: UInt64 = 0
    private var savedRevision: UInt64 = 0
    private var lastResult: Result<Void, Error> = .success(())
    private var waiters: [(UInt64, CheckedContinuation<Result<Void, Error>, Never>)] = []
    private(set) var revision: UInt64 = 0
    var onError: ((Error) -> Void)?

    init(url: URL, writer: @escaping Writer = { try $0.save(to: $1) }) { self.url = url; self.writer = writer }
    func setBaseline(_ state: LibraryState) { precondition(task == nil); requested = state }

    @discardableResult func submit(_ state: LibraryState, reportError: Bool = true, retryFailed: Bool = false) -> UInt64 {
        if requested == state {
            let failed: Bool = { if case .failure = lastResult { return true }; return false }()
            if !retryFailed || task != nil || !failed { return revision }
        }
        revision += 1; requested = state
        pending = Snapshot(revision: revision, state: state, reportError: reportError)
        if task == nil {
            task = Task { [self] in
                while let snapshot = pending {
                    pending = nil
                    let writer = self.writer, url = self.url
                    let result = await Task.detached(priority: .utility) { Result { try writer(snapshot.state, url) } }.value
                    completedRevision = snapshot.revision; lastResult = result
                    if case .success = result { savedRevision = snapshot.revision }
                    let completed = waiters.filter { $0.0 <= snapshot.revision }
                    waiters.removeAll { $0.0 <= snapshot.revision }
                    for waiter in completed { waiter.1.resume(returning: result) }
                    if case .failure(let error) = result, snapshot.reportError, snapshot.revision == revision { onError?(error) }
                }
                task = nil
            }
        }
        return revision
    }
    func wait(for revision: UInt64) async -> Result<Void, Error> {
        if revision <= savedRevision { return .success(()) }
        if revision <= completedRevision { return lastResult }
        return await withCheckedContinuation { waiters.append((revision, $0)) }
    }
    func flush(_ state: LibraryState, retryFailed: Bool = false) async -> Result<Void, Error> {
        let target = submit(state, reportError: false, retryFailed: retryFailed)
        return await wait(for: target)
    }
}
