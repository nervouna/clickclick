import AppKit
import Foundation
import Observation
import ServiceManagement

@MainActor
@Observable
final class AppModel {
    private(set) var permissionState: InputPermissionState = .notRequested
    private(set) var dashboard = DashboardSnapshot()
    private(set) var trend: [TrendPoint] = []
    private(set) var keyCounts: [KeyCount] = []
    private(set) var errorMessage: String?
    var isPaused = false
    var selectedDeviceID: UUID?
    var granularity: TrendGranularity = .hour
    var rangeEnd = Date()
    var showingOnboarding = false

    private(set) var launchAtLogin = false
    private(set) var hideZeroCountDevices: Bool
    private let engine: StatisticsEngine?
    private let monitor: CoreHIDInputMonitor?
    private var refreshTask: Task<Void, Never>?
    private let preferences: UserDefaults

    private static let hideZeroCountDevicesKey = "hideZeroCountDevices"

    init(databaseURL: URL? = nil, preferences: UserDefaults = .standard) {
        self.preferences = preferences
        hideZeroCountDevices = preferences.object(forKey: Self.hideZeroCountDevicesKey) as? Bool ?? true
        do {
            let url = try databaseURL ?? Self.defaultDatabaseURL()
            let engine = try StatisticsEngine(databaseURL: url)
            self.engine = engine
            monitor = CoreHIDInputMonitor(engine: engine)
            permissionState = InputPermission.currentState()
            showingOnboarding = permissionState == .notRequested
            launchAtLogin = SMAppService.mainApp.status == .enabled
            refreshTask = Task { [weak self] in
                await self?.bootstrap()
            }
        } catch {
            engine = nil
            monitor = nil
            permissionState = .failed(error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    var visibleDevices: [KeyboardDevice] {
        dashboard.visibleDevices(hideZeroCount: hideZeroCountDevices)
    }

    var visibleTodayDeviceCounts: [DeviceCount] {
        dashboard.visibleTodayCounts(hideZeroCount: hideZeroCountDevices)
    }

    var rangeStart: Date {
        Calendar.autoupdatingCurrent.date(byAdding: granularity.defaultLookback, to: rangeEnd) ?? rangeEnd
    }

    func enableCounting() async {
        guard let monitor else { return }
        permissionState = await monitor.requestPermission()
        showingOnboarding = false
        if permissionState == .denied { InputPermission.openSystemSettings() }
        await refresh()
    }

    func openPermissionSettings() {
        InputPermission.openSystemSettings()
    }

    func togglePaused() async {
        isPaused.toggle()
        await monitor?.setPaused(isPaused)
    }

    func refresh() async {
        guard let engine else { return }
        if let monitor { permissionState = await monitor.refreshPermission() }
        do {
            dashboard = try await engine.dashboard()
            trend = try await engine.trend(
                granularity: granularity,
                from: rangeStart,
                to: rangeEnd,
                deviceID: selectedDeviceID
            )
            keyCounts = try await engine.keyCounts(from: rangeStart, to: rangeEnd, deviceID: selectedDeviceID)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setGranularity(_ value: TrendGranularity) async {
        granularity = value
        rangeEnd = Date()
        await refresh()
    }

    func selectDevice(_ id: UUID?) async {
        selectedDeviceID = id
        await refresh()
    }

    func renameDevice(_ id: UUID, to name: String) async {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do { try await engine?.renameDevice(id: id, name: name); await refresh() }
        catch { errorMessage = error.localizedDescription }
    }

    func hideDevice(_ id: UUID, hidden: Bool) async {
        do { try await engine?.setDeviceHidden(id: id, hidden: hidden); await refresh() }
        catch { errorMessage = error.localizedDescription }
    }

    func mergeDevice(_ source: UUID, into target: UUID) async {
        do { try await engine?.mergeDevice(source: source, target: target); selectedDeviceID = nil; await refresh() }
        catch { errorMessage = error.localizedDescription }
    }

    func deleteDevice(_ id: UUID) async {
        do { try await engine?.deleteDevice(id: id); selectedDeviceID = nil; await refresh() }
        catch { errorMessage = error.localizedDescription }
    }

    func clearAllCounts() async {
        do { try await engine?.clearAllCounts(); await refresh() }
        catch { errorMessage = error.localizedDescription }
    }

    func clearCounts(for id: UUID) async {
        do { try await engine?.clearCounts(deviceID: id); await refresh() }
        catch { errorMessage = error.localizedDescription }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            errorMessage = error.localizedDescription
        }
    }

    func setHideZeroCountDevices(_ enabled: Bool) {
        hideZeroCountDevices = enabled
        preferences.set(enabled, forKey: Self.hideZeroCountDevicesKey)
        if enabled,
           let selectedDeviceID,
           !visibleDevices.contains(where: { $0.id == selectedDeviceID }) {
            self.selectedDeviceID = nil
            Task { await refresh() }
        }
    }

    func flushForTermination() async {
        do { try await engine?.flush() }
        catch { errorMessage = error.localizedDescription }
        await monitor?.stop()
    }

    private func bootstrap() async {
        await engine?.startPeriodicFlush()
        do { try await engine?.performMaintenance() }
        catch { errorMessage = error.localizedDescription }
        if permissionState == .granted { await monitor?.start() }
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(2))
            rangeEnd = Date()
        }
    }

    private static func defaultDatabaseURL() throws -> URL {
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
