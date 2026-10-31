import SwiftUI

// 提供三个面板的真实数据对照窗口，也用于人工视觉验收。
@MainActor
final class PreviewWindow: NSObject, NSWindowDelegate {
    private static var window: NSWindow?
    private static let lifecycle = PreviewWindow()
    private weak var store: MonitorStore?

    // 同时展示与菜单栏复用的视图，禁止另造演示数据。
    static func show(store: MonitorStore) {
        if let window { window.makeKeyAndOrderFront(nil); return }
        let content = HStack(alignment: .top, spacing: 12) {
            MonitorPanel(kind: .network, store: store)
            MonitorPanel(kind: .memory, store: store)
            MonitorPanel(kind: .cpu, store: store)
        }.padding(18).background(LinearGradient(colors: [Color(red: 0.13, green: 0.18, blue: 0.24), .black], startPoint: .topLeading, endPoint: .bottomTrailing))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 990, height: 510), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Kimo Monitor · 实时对照"
        window.isReleasedWhenClosed = false
        lifecycle.store = store
        window.delegate = lifecycle
        self.window = window
        window.contentView = NSHostingView(rootView: content)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        // 显示总览时登记共享的应用排行需求。
        lifecycle.updateVisibility(window)
    }

    // 被其他窗口完全遮挡时暂停排行，重新可见时自动恢复。
    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        updateVisibility(window)
    }

    // 最小化后不再扫描进程列表。
    func windowDidMiniaturize(_ notification: Notification) {
        store?.setDetailsVisible(false, for: .overview)
    }

    // 取消最小化时重新计算可见性。
    func windowDidDeminiaturize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        updateVisibility(window)
    }

    // 关闭时销毁托管视图及窗口引用，停止不可见 SwiftUI 树继续观察快照。
    func windowWillClose(_ notification: Notification) {
        store?.setDetailsVisible(false, for: .overview)
        Self.window?.contentView = nil
        Self.window = nil
        store = nil
    }

    // 仅可见且未最小化的总览需要进程详情。
    private func updateVisibility(_ window: NSWindow) {
        store?.setDetailsVisible(window.isVisible && !window.isMiniaturized
                                && window.occlusionState.contains(.visible), for: .overview)
    }
}
