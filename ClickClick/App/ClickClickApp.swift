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
            Label(model.dashboard.todayTotal.formatted(), systemImage: "keyboard")
        }
        .menuBarExtraStyle(.window)

        Window("详细统计", id: "statistics") {
            StatisticsView()
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
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var isTerminating = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating, let model else { return .terminateNow }
        isTerminating = true
        Task {
            await model.flushForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
