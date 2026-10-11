import Foundation
import Observation

@MainActor
@Observable
final class StatisticsViewModel {
    private(set) var snapshot: StatisticsSnapshot?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var granularity: TrendGranularity
    private(set) var selectedDeviceID: UUID?

    @ObservationIgnored private let reader: any StatisticsSnapshotReading
    @ObservationIgnored private let now: @MainActor @Sendable () -> Date
    @ObservationIgnored private let didPublish: (@MainActor @Sendable (StatisticsSnapshot) -> Void)?
    @ObservationIgnored private var isVisible = false
    /// The database may have changed since the last load started.
    @ObservationIgnored private var needsReload = false
    /// The next load replaces content the user is looking at (first load, new
    /// selection, retry), so it shows the loading indicator. Background
    /// reloads after data changes do not.
    @ObservationIgnored private var showsLoading = true
    @ObservationIgnored private var generation: UInt64 = 0
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

    func setVisible(_ visible: Bool) {
        guard isVisible != visible else { return }
        isVisible = visible

        if visible {
            let query = makeQuery()
            if needsReload || snapshot?.query != query {
                reload()
            } else {
                scheduleBoundary(for: query)
            }
        } else {
            if loadTask != nil { needsReload = true }
            cancelLoad()
            boundaryTask?.cancel()
            boundaryTask = nil
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
        showsLoading = true
        invalidateAndReload()
    }

    func invalidateAndReload() {
        needsReload = true
        guard isVisible else { return }
        reload()
    }

    /// Called after the database changed. A hidden window reloads when shown. A
    /// load that is already running is never restarted, so a steady stream of
    /// changes cannot starve it; one more load follows when it finishes.
    func dataDidChange() {
        needsReload = true
        guard isVisible, loadTask == nil else { return }
        reload()
    }

    private func querySelectionDidChange() {
        showsLoading = true
        boundaryTask?.cancel()
        boundaryTask = nil
        guard isVisible else { return }
        reload()
    }

    private func reload() {
        cancelLoad()
        needsReload = false
        let requestGeneration = generation
        let query = makeQuery()
        let reader = self.reader
        if isLoading != showsLoading { isLoading = showsLoading }

        loadTask = Task { [weak self] in
            do {
                let loaded = try await reader.snapshot(for: query)
                guard !Task.isCancelled else { return }
                self?.finishLoading(loaded, query: query, generation: requestGeneration)
            } catch is CancellationError {
                // A newer query or a hidden window owns the state now.
            } catch {
                guard !Task.isCancelled else { return }
                self?.finishLoading(error: error, generation: requestGeneration)
            }
        }
    }

    private func finishLoading(
        _ loaded: StatisticsSnapshot,
        query: StatisticsQuery,
        generation requestGeneration: UInt64
    ) {
        guard isVisible, requestGeneration == generation else { return }
        loadTask = nil
        guard query == makeQuery() else {
            // The bucket rolled over while the read was running.
            reload()
            return
        }

        showsLoading = false
        if isLoading { isLoading = false }
        if errorMessage != nil { errorMessage = nil }
        publish(loaded)
        scheduleBoundary(for: query)
        if needsReload { reload() }
    }

    private func finishLoading(error: Error, generation requestGeneration: UInt64) {
        guard isVisible, requestGeneration == generation else { return }
        loadTask = nil
        needsReload = true
        if isLoading { isLoading = false }
        let message = error.localizedDescription
        if errorMessage != message { errorMessage = message }
    }

    private func publish(_ value: StatisticsSnapshot) {
        guard snapshot != value else { return }
        snapshot = value
        didPublish?(value)
    }

    private func cancelLoad() {
        generation &+= 1
        guard let loadTask else { return }
        loadTask.cancel()
        self.loadTask = nil
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
            guard self.makeQuery() != query else {
                self.scheduleBoundary(for: query)
                return
            }
            self.reload()
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
