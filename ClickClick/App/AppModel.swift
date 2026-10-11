import AppKit
import Foundation
import Observation
import ServiceManagement

@MainActor
@Observable
final class AppModel {
    private(set) var permissionState: InputPermissionState
    private(set) var dashboard = DashboardSnapshot()
    private(set) var errorMessage: String?
    private(set) var statisticsViewModel: StatisticsViewModel?
    private(set) var isPaused = false
    var showingOnboarding: Bool

    private(set) var launchAtLogin: Bool
    private(set) var hideZeroCountDevices: Bool

    private var engine: StatisticsEngine?
    private var monitor: CoreHIDInputMonitor?
    private var bootstrapTask: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var dashboardLocalDay = TimeBuckets.localDay(for: Date())
    @ObservationIgnored private var dashboardRevision: Int64 = 0
    @ObservationIgnored private var dashboardRefreshGeneration: UInt64 = 0
    private let preferences: UserDefaults

    private static let hideZeroCountDevicesKey = "hideZeroCountDevices"

    init(databaseURL: URL? = nil, preferences: UserDefaults = .standard) {
        self.preferences = preferences
        let initialPermissionState = InputPermission.currentState()
        permissionState = initialPermissionState
        showingOnboarding = initialPermissionState == .notRequested
        launchAtLogin = SMAppService.mainApp.status == .enabled
        hideZeroCountDevices = preferences.object(forKey: Self.hideZeroCountDevicesKey) as? Bool ?? true

        do {
            let url = try databaseURL ?? Self.defaultDatabaseURL()
            bootstrapTask = Task { [weak self] in
                await self?.bootstrap(databaseURL: url)
            }
        } catch {
            permissionState = .failed(error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    var visibleDevices: [KeyboardDevice] {
        dashboard.visibleDevices(hideZeroCount: hideZeroCountDevices)
    }

    var visibleTodayDeviceCounts: [DeviceCount] {
        let visibleIDs = Set(visibleDevices.map(\.id))
        return dashboard.visibleTodayCounts(hideZeroCount: hideZeroCountDevices)
            .filter { visibleIDs.contains($0.deviceID) }
    }

    func enableCounting() async {
        guard let monitor else { return }
        permissionState = await monitor.requestPermission()
        showingOnboarding = false
        if permissionState == .denied {
            InputPermission.openSystemSettings()
        }
        await refreshDashboard()
    }

    func openPermissionSettings() {
        InputPermission.openSystemSettings()
    }

    func recheckPermission() async {
        guard let monitor else {
            permissionState = InputPermission.currentState()
            return
        }
        permissionState = await monitor.refreshPermission()
        await refreshDashboard()
    }

    func applicationDidBecomeActive() async {
        await recheckPermission()
    }

    func clockOrWakeDidChange() async {
        await flushPendingCounts()
        await refreshDashboard()
        statisticsViewModel?.invalidateAndReload()
    }

    func togglePaused() async {
        isPaused.toggle()
        await monitor?.setPaused(isPaused)
    }

    func renameDevice(_ id: UUID, to name: String) async {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, let engine else { return }
        do {
            let result = try await engine.renameDevice(id: id, name: trimmedName)
            statisticsViewModel?.consume(result)
            await refreshDashboard()
        } catch {
            report(error)
        }
    }

    func hideDevice(_ id: UUID, hidden: Bool) async {
        guard let engine else { return }
        do {
            let result = try await engine.setDeviceHidden(id: id, hidden: hidden)
            let selectionChanged = hidden && clearStatisticsSelection(if: id)
            if !selectionChanged {
                statisticsViewModel?.consume(result)
            }
            await refreshDashboard()
        } catch {
            report(error)
        }
    }

    func mergeDevice(_ source: UUID, into target: UUID) async {
        guard let engine else { return }
        do {
            let result = try await engine.mergeDevice(source: source, target: target)
            let selectionChanged = clearStatisticsSelection()
            if !selectionChanged {
                statisticsViewModel?.consume(result)
            }
            await refreshDashboard()
        } catch {
            report(error)
        }
    }

    func deleteDevice(_ id: UUID) async {
        guard let engine else { return }
        do {
            let result = try await engine.deleteDevice(id: id)
            await monitor?.deviceWasDeleted(id)
            let selectionChanged = clearStatisticsSelection(if: id)
            if !selectionChanged {
                statisticsViewModel?.consume(result)
            }
            await refreshDashboard()
        } catch {
            report(error)
        }
    }

    func clearAllCounts() async {
        guard let engine else { return }
        do {
            let result = try await engine.clearAllCounts()
            let selectionChanged = hideZeroCountDevices && clearStatisticsSelection()
            if !selectionChanged {
                statisticsViewModel?.consume(result)
            }
            await refreshDashboard()
        } catch {
            report(error)
        }
    }

    func clearCounts(for id: UUID) async {
        guard let engine else { return }
        do {
            let result = try await engine.clearCounts(deviceID: id)
            let selectionChanged = hideZeroCountDevices && clearStatisticsSelection(if: id)
            if !selectionChanged {
                statisticsViewModel?.consume(result)
            }
            await refreshDashboard()
        } catch {
            report(error)
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            report(error)
        }
    }

    func setHideZeroCountDevices(_ enabled: Bool) {
        guard hideZeroCountDevices != enabled else { return }
        hideZeroCountDevices = enabled
        preferences.set(enabled, forKey: Self.hideZeroCountDevicesKey)
        if enabled,
           let selectedDeviceID = statisticsViewModel?.selectedDeviceID,
           !visibleDevices.contains(where: { $0.id == selectedDeviceID }) {
            statisticsViewModel?.selectDevice(nil)
        }
    }

    func flushForTermination() async {
        bootstrapTask?.cancel()
        flushTask?.cancel()
        await monitor?.stop()
        do {
            if let result = try await engine?.flush() {
                statisticsViewModel?.consume(result)
                _ = applyToDashboard(result)
            }
        } catch {
            report(error)
        }
    }

    private func bootstrap(databaseURL: URL) async {
        do {
            // Opening the store may perform a backup and migration. Keep that work
            // off MainActor so a large existing database cannot freeze the menu UI.
            let engine = try await Task.detached(priority: .userInitiated) {
                try StatisticsEngine(databaseURL: databaseURL)
            }.value
            guard !Task.isCancelled else { return }

            let monitor = CoreHIDInputMonitor(engine: engine)
            self.engine = engine
            self.monitor = monitor
            statisticsViewModel = StatisticsViewModel(reader: engine.reader)

            await monitor.setDeviceDirectoryHandler { [weak self] in
                await self?.deviceDirectoryDidChange()
            }
            await monitor.setStateHandler { [weak self] state in
                await self?.monitorStateDidChange(state)
            }

            if let maintenance = try await engine.performMaintenance() {
                statisticsViewModel?.consume(maintenance)
            }
            await refreshDashboard()

            // Input listening starts only after migration and its validation have
            // succeeded. A migration error leaves the database and backup intact.
            permissionState = await monitor.refreshPermission()
            startFlushLoop()
        } catch is CancellationError {
            return
        } catch {
            permissionState = .failed(error.localizedDescription)
            report(error)
        }
    }

    private func startFlushLoop() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
                guard let self else { return }
                await self.flushPendingCounts()
            }
        }
    }

    private func flushPendingCounts() async {
        guard let engine else { return }
        do {
            guard let result = try await engine.flush() else { return }
            let newlyVisibleDevices = applyToDashboard(result)
            statisticsViewModel?.consume(result)
            if hideZeroCountDevices,
               statisticsViewModel?.selectedDeviceID != nil,
               !newlyVisibleDevices.isEmpty {
                // A delta for another device can be irrelevant to a filtered
                // chart while still changing the device picker's membership.
                statisticsViewModel?.invalidateAndReload()
            }
            clearError()
        } catch {
            report(error)
        }
    }

    @discardableResult
    private func applyToDashboard(_ result: FlushResult) -> Set<UUID> {
        guard result.revision > dashboardRevision else { return [] }
        guard result.invalidation.scope == .counts else {
            Task { [weak self] in await self?.refreshDashboard() }
            return []
        }
        guard !result.deltas.isEmpty else { return [] }
        guard result.revision == dashboardRevision + 1 else {
            Task { [weak self] in await self?.refreshDashboard() }
            return []
        }
        let today = TimeBuckets.localDay(for: Date())
        guard dashboardLocalDay == today else {
            Task { [weak self] in await self?.refreshDashboard() }
            return []
        }
        var totalByDevice: [UUID: Int64] = [:]
        var todayByDevice: [UUID: Int64] = [:]
        for delta in result.deltas {
            totalByDevice[delta.deviceID, default: 0] += delta.count
            if delta.localDay == today {
                todayByDevice[delta.deviceID, default: 0] += delta.count
            }
        }

        let knownDeviceIDs = Set(dashboard.devices.map(\.id))
        guard Set(totalByDevice.keys).isSubset(of: knownDeviceIDs) else {
            Task { [weak self] in await self?.refreshDashboard() }
            return []
        }

        var updated = dashboard
        var newlyVisibleDevices: Set<UUID> = []
        for index in updated.devices.indices {
            let deviceID = updated.devices[index].id
            let increment = totalByDevice[deviceID, default: 0]
            if increment > 0,
               updated.devices[index].totalCount == 0,
               !updated.devices[index].isHidden {
                newlyVisibleDevices.insert(deviceID)
            }
            updated.devices[index].totalCount += increment
        }

        let devicesByID = Dictionary(uniqueKeysWithValues: updated.devices.map { ($0.id, $0) })
        var currentToday = Dictionary(uniqueKeysWithValues: updated.todayByDevice.map { ($0.deviceID, $0.count) })
        for (deviceID, count) in todayByDevice where devicesByID[deviceID]?.isHidden == false {
            currentToday[deviceID, default: 0] += count
        }
        updated.todayByDevice = currentToday.compactMap { deviceID, count in
            guard let device = devicesByID[deviceID], !device.isHidden else { return nil }
            return DeviceCount(deviceID: deviceID, deviceName: device.name, count: count)
        }.sorted {
            $0.count == $1.count ? $0.deviceName < $1.deviceName : $0.count > $1.count
        }
        updated.todayTotal = updated.todayByDevice.reduce(0) { $0 + $1.count }
        dashboardRevision = result.revision
        dashboard = updated
        return newlyVisibleDevices
    }

    private func deviceDirectoryDidChange() async {
        await refreshDashboard()
        statisticsViewModel?.invalidateAndReload()
    }

    private func monitorStateDidChange(_ state: InputPermissionState) {
        guard permissionState != state else { return }
        permissionState = state
    }

    private func refreshDashboard() async {
        guard let engine else { return }
        dashboardRefreshGeneration &+= 1
        let requestGeneration = dashboardRefreshGeneration
        do {
            let read = try await engine.dashboard()
            guard requestGeneration == dashboardRefreshGeneration else { return }
            guard read.revision >= dashboardRevision else { return }
            let today = TimeBuckets.localDay(for: Date())
            guard read.localDay == today else {
                Task { [weak self] in await self?.refreshDashboard() }
                return
            }
            dashboardRevision = read.revision
            let updated = read.snapshot
            dashboardLocalDay = read.localDay
            if dashboard != updated {
                dashboard = updated
            }
            if hideZeroCountDevices,
               let selectedDeviceID = statisticsViewModel?.selectedDeviceID,
               !visibleDevices.contains(where: { $0.id == selectedDeviceID }) {
                statisticsViewModel?.selectDevice(nil)
            }
            clearError()
        } catch {
            guard requestGeneration == dashboardRefreshGeneration else { return }
            report(error)
        }
    }

    private func report(_ error: Error) {
        let message = error.localizedDescription
        if errorMessage != message {
            errorMessage = message
        }
    }

    private func clearError() {
        if errorMessage != nil {
            errorMessage = nil
        }
    }

    @discardableResult
    private func clearStatisticsSelection(if matchingID: UUID? = nil) -> Bool {
        guard let statisticsViewModel,
              let selectedDeviceID = statisticsViewModel.selectedDeviceID,
              matchingID == nil || matchingID == selectedDeviceID else { return false }
        statisticsViewModel.selectDevice(nil)
        return true
    }

    static func defaultDatabaseURL() throws -> URL {
        // A hosted unit-test process launches the application target before the
        // test bundle. Keep that bootstrap away from the user's real container.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            let root = FileManager.default.temporaryDirectory.appending(
                path: "ClickClickTests-\(ProcessInfo.processInfo.processIdentifier)",
                directoryHint: .isDirectory
            )
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            return root.appending(path: "clickclick.sqlite")
        }

        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return root.appending(path: "ClickClick", directoryHint: .isDirectory)
            .appending(path: "clickclick.sqlite")
    }
}
