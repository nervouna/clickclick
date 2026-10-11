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
        do {
            try await engine?.flush()
        } catch {
            report(error)
        }
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
            try await engine.renameDevice(id: id, name: trimmedName)
            await refreshDashboard()
            statisticsViewModel?.dataDidChange()
        } catch {
            report(error)
        }
    }

    func hideDevice(_ id: UUID, hidden: Bool) async {
        guard let engine else { return }
        do {
            try await engine.setDeviceHidden(id: id, hidden: hidden)
            let selectionChanged = hidden && clearStatisticsSelection(if: id)
            await refreshDashboard()
            if !selectionChanged { statisticsViewModel?.dataDidChange() }
        } catch {
            report(error)
        }
    }

    func mergeDevice(_ source: UUID, into target: UUID) async {
        guard let engine else { return }
        do {
            try await engine.mergeDevice(source: source, target: target)
            let selectionChanged = clearStatisticsSelection()
            await refreshDashboard()
            if !selectionChanged { statisticsViewModel?.dataDidChange() }
        } catch {
            report(error)
        }
    }

    func deleteDevice(_ id: UUID) async {
        guard let engine else { return }
        do {
            try await engine.deleteDevice(id: id)
            await monitor?.deviceWasDeleted(id)
            let selectionChanged = clearStatisticsSelection(if: id)
            await refreshDashboard()
            if !selectionChanged { statisticsViewModel?.dataDidChange() }
        } catch {
            report(error)
        }
    }

    func clearAllCounts() async {
        guard let engine else { return }
        do {
            try await engine.clearAllCounts()
            let selectionChanged = hideZeroCountDevices && clearStatisticsSelection()
            await refreshDashboard()
            if !selectionChanged { statisticsViewModel?.dataDidChange() }
        } catch {
            report(error)
        }
    }

    func clearCounts(for id: UUID) async {
        guard let engine else { return }
        do {
            try await engine.clearCounts(deviceID: id)
            let selectionChanged = hideZeroCountDevices && clearStatisticsSelection(if: id)
            await refreshDashboard()
            if !selectionChanged { statisticsViewModel?.dataDidChange() }
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
        await monitor?.stop()
        do {
            try await engine?.flush()
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
            await engine.setFlushHandler { [weak self] error in
                await self?.flushDidFinish(error)
            }

            try await engine.performMaintenance()
            await refreshDashboard()

            // Input listening starts only after migration and its validation have
            // succeeded. A migration error leaves the database and backup intact.
            permissionState = await monitor.refreshPermission()
        } catch is CancellationError {
            return
        } catch {
            permissionState = .failed(error.localizedDescription)
            report(error)
        }
    }

    private func flushDidFinish(_ error: Error?) async {
        if let error {
            report(error)
            return
        }
        await refreshDashboard()
        statisticsViewModel?.dataDidChange()
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
            let updated = try await engine.dashboard()
            guard requestGeneration == dashboardRefreshGeneration else { return }
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
