import AppKit
import SwiftUI

@main
struct ClickClickApp: App {
    @State private var model: AppModel
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        appDelegate.model = model
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(model)
        } label: {
            MenuBarLabel()
                .environment(model)
        }
        .menuBarExtraStyle(.window)

        Window("详细统计", id: "statistics") {
            Group {
                if let statisticsModel = model.statisticsViewModel {
                    StatisticsView(
                        model: statisticsModel,
                        hideZeroCountDevices: model.hideZeroCountDevices
                    )
                } else if let errorMessage = model.errorMessage {
                    ContentUnavailableView {
                        Label("无法打开统计数据库", systemImage: "externaldrive.badge.exclamationmark")
                    } description: {
                        Text(errorMessage)
                    }
                } else {
                    ProgressView("正在准备统计数据库…")
                        .controlSize(.large)
                }
            }
            .environment(model)
            .frame(minWidth: 840, minHeight: 620)
        }
        .defaultSize(width: 980, height: 720)

        Settings {
            SettingsView()
                .environment(model)
                .frame(width: 520, height: 420)
        }
    }
}

private struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Label(model.dashboard.todayTotal.formatted(), systemImage: "keyboard")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var isTerminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clockOrWakeDidChange),
            name: Notification.Name.NSSystemTimeZoneDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clockOrWakeDidChange),
            name: Notification.Name.NSCalendarDayChanged,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(clockOrWakeDidChange),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Task { await model?.applicationDidBecomeActive() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating, let model else { return .terminateNow }
        isTerminating = true
        Task {
            await model.flushForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // Foundation posts NSCalendarDayChanged and NSSystemTimeZoneDidChange on a
    // background queue, so the selector must not assume main-actor isolation.
    @objc private nonisolated func clockOrWakeDidChange() {
        Task { @MainActor in await self.model?.clockOrWakeDidChange() }
    }
}
