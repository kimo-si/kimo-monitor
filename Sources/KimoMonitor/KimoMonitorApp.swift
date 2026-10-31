import SwiftUI

@main
struct KimoMonitorApp: App {
    @NSApplicationDelegateAdaptor(MonitorAppDelegate.self) private var delegate

    var body: some Scene { Settings { EmptyView() } }
}

// 管理原生菜单栏生命周期；后台采样仍由唯一的 MonitorStore 负责。
@MainActor
final class MonitorAppDelegate: NSObject, NSApplicationDelegate {
    private let store = MonitorStore()
    private var menuBar: MenuBarController?

    // 应用启动时启动唯一采样器，不依赖菜单面板是否打开。
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 创建带紧凑边距的状态项，并订阅实时快照。
        menuBar = MenuBarController(store: store)
        // 启动唯一后台采样器。
        store.start()
        if CommandLine.arguments.contains("--preview") || store.preferences.value.openOverview {
            // 复用实际数据与详情视图，展示实时对照窗口。
            PreviewWindow.show(store: store)
        }
    }

    // 退出时主动清理所有状态项及已打开的详情面板。
    func applicationWillTerminate(_ notification: Notification) {
        menuBar?.stop()
    }
}
