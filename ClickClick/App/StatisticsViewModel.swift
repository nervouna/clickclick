import Foundation
import Observation

@MainActor
@Observable
final class StatisticsViewModel {
    private(set) var snapshot: StatisticsViewSnapshot?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var granularity: TrendGranularity
    private(set) var selectedDeviceID: UUID?

    @ObservationIgnored private let reader: any StatisticsSnapshotReading
    @ObservationIgnored private let now: @MainActor @Sendable () -> Date
    @ObservationIgnored private let didPublish: (@MainActor @Sendable (StatisticsSnapshot) -> Void)?
    @ObservationIgnored private var workingSnapshot: StatisticsSnapshot?
    @ObservationIgnored private var isVisible = false
    @ObservationIgnored private var needsReload = true
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var latestRevisionSeen: Int64 = 0
    @ObservationIgnored private var bufferedResults: [Int64: FlushResult] = [:]
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var boundaryTask: Task<Void, Never>?

    init(
        reader: any StatisticsSnapshotReading,
        granularity: TrendGranularity = .hour,
        selectedDeviceID: UUID? = nil,
        now: @escaping @MainActor @Sendable () -> Date = { Date() },
        didPublish: (@MainActor @Sendable (StatisticsSnapshot) -> Void)? = nil
    ) {
        self.reader = reader
        self.granularity = granularity
        self.selectedDeviceID = selectedDeviceID
        self.now = now
        self.didPublish = didPublish
    }

    var bufferedRevisionCountForDiagnostics: Int { bufferedResults.count }

    func setVisible(_ visible: Bool) {
        guard isVisible != visible else { return }
        isVisible = visible

        if visible {
            let query = makeQuery()
            if let workingSnapshot,
               workingSnapshot.query == query,
               !needsReload {
                publish(workingSnapshot)
                scheduleBoundary(for: query)
            } else {
                reload(for: query)
            }
        } else {
            cancelLoad()
            boundaryTask?.cancel()
            boundaryTask = nil
            bufferedResults.removeAll(keepingCapacity: false)
            if isLoading { isLoading = false }
        }
    }

    func setGranularity(_ value: TrendGranularity) {
        guard granularity != value else { return }
        granularity = value
        querySelectionDidChange()
    }

    func selectDevice(_ id: UUID?) {
        guard selectedDeviceID != id else { return }
        selectedDeviceID = id
        querySelectionDidChange()
    }

    func retry() {
        needsReload = true
        guard isVisible else { return }
        reload(for: makeQuery())
    }

    func invalidateAndReload() {
        needsReload = true
        guard isVisible else { return }
        reload(for: makeQuery())
    }

    func consume(_ result: FlushResult) {
        guard result.revision > (workingSnapshot?.revision ?? 0) else { return }
        latestRevisionSeen = max(latestRevisionSeen, result.revision)

        // A hidden statistics window will issue a consistent full read when it
        // is shown again. Retaining every intervening delta would be unbounded
        // and provides no value because there is no visible snapshot to patch.
        guard isVisible else {
            needsReload = true
            bufferedResults.removeAll(keepingCapacity: false)
            return
        }

        bufferedResults[result.revision] = result

        if isLoading {
            // Count flushes are deliberately buffered. Restarting a long read
            // every two seconds could otherwise prevent its first result from
            // ever becoming visible.
            if result.invalidation.scope == .full, isVisible {
                needsReload = true
                reload(for: makeQuery())
            }
            return
        }

        guard let workingSnapshot,
              workingSnapshot.query == makeQuery() else {
            needsReload = true
            if isVisible { reload(for: makeQuery()) }
            return
        }

        guard result.revision == workingSnapshot.revision + 1 else {
            needsReload = true
            if isVisible { reload(for: workingSnapshot.query) }
            return
        }

        guard result.invalidation.scope == .counts else {
            needsReload = true
            if isVisible { reload(for: workingSnapshot.query) }
            return
        }

        guard let updated = workingSnapshot.applying(result) else {
            needsReload = true
            if isVisible { reload(for: workingSnapshot.query) }
            return
        }

        self.workingSnapshot = updated
        bufferedResults.removeValue(forKey: result.revision)
        needsReload = false

        // Advancing an unrelated revision is internal bookkeeping. Publishing
        // it would needlessly invalidate the entire statistics hierarchy.
        if isVisible, workingSnapshot.affectsVisibleContent(in: result) {
            publish(updated)
        }
    }

    private func querySelectionDidChange() {
        needsReload = true
        boundaryTask?.cancel()
        boundaryTask = nil
        guard isVisible else { return }
        reload(for: makeQuery())
    }

    private func reload(for query: StatisticsQuery) {
        guard isVisible else {
            needsReload = true
            return
        }

        cancelLoad()
        generation &+= 1
        let requestGeneration = generation
        let reader = self.reader
        if !isLoading { isLoading = true }
        if errorMessage != nil { errorMessage = nil }

        loadTask = Task { [weak self] in
            do {
                let loaded = try await reader.snapshot(for: query)
                guard !Task.isCancelled else { return }
                self?.finishLoading(
                    loaded,
                    query: query,
                    generation: requestGeneration
                )
            } catch is CancellationError {
                // A newer query or a hidden window owns the state now.
            } catch {
                guard !Task.isCancelled else { return }
                self?.finishLoading(
                    error: error,
                    query: query,
                    generation: requestGeneration
                )
            }
        }
    }

    private func finishLoading(
        _ loaded: StatisticsSnapshot,
        query: StatisticsQuery,
        generation requestGeneration: UInt64
    ) {
        guard isVisible, requestGeneration == generation else { return }
        let currentQuery = makeQuery()
        guard query == currentQuery else {
            needsReload = true
            if isLoading { isLoading = false }
            loadTask = nil
            reload(for: currentQuery)
            return
        }

        var caughtUp = loaded
        bufferedResults = bufferedResults.filter { $0.key > loaded.revision }

        while let result = bufferedResults[caughtUp.revision + 1] {
            guard result.invalidation.scope == .counts,
                  let updated = caughtUp.applying(result) else {
                break
            }
            caughtUp = updated
            bufferedResults.removeValue(forKey: result.revision)
        }

        latestRevisionSeen = max(latestRevisionSeen, loaded.revision)
        guard caughtUp.revision >= latestRevisionSeen else {
            // One reload resolves either a full invalidation or a missing
            // revision. Keep the old public snapshot visible in the meantime.
            workingSnapshot = caughtUp
            needsReload = true
            if isLoading { isLoading = false }
            loadTask = nil
            reload(for: query)
            return
        }

        workingSnapshot = caughtUp
        needsReload = false
        if isLoading { isLoading = false }
        if errorMessage != nil { errorMessage = nil }
        publish(caughtUp)
        scheduleBoundary(for: query)
        loadTask = nil
    }

    private func finishLoading(
        error: Error,
        query: StatisticsQuery,
        generation requestGeneration: UInt64
    ) {
        guard isVisible, requestGeneration == generation else { return }
        let currentQuery = makeQuery()
        guard query == currentQuery else {
            needsReload = true
            if isLoading { isLoading = false }
            loadTask = nil
            reload(for: currentQuery)
            return
        }
        if isLoading { isLoading = false }
        needsReload = true
        let message = error.localizedDescription
        if errorMessage != message { errorMessage = message }
        loadTask = nil
    }

    private func publish(_ value: StatisticsSnapshot) {
        if snapshot != value {
            snapshot = value
            didPublish?(value)
        }
    }

    private func cancelLoad() {
        generation &+= 1
        loadTask?.cancel()
        loadTask = nil
        reader.interrupt()
    }

    private func scheduleBoundary(for query: StatisticsQuery) {
        boundaryTask?.cancel()
        guard isVisible else {
            boundaryTask = nil
            return
        }

        let delay = max(0.05, query.rangeEnd.timeIntervalSince(now()))
        boundaryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled, let self, self.isVisible else { return }
            let nextQuery = self.makeQuery()
            guard nextQuery != query else {
                self.scheduleBoundary(for: query)
                return
            }
            self.needsReload = true
            self.reload(for: nextQuery)
        }
    }

    private func makeQuery() -> StatisticsQuery {
        StatisticsQuery(
            granularity: granularity,
            deviceID: selectedDeviceID,
            now: now(),
            calendar: .autoupdatingCurrent
        )
    }
}
