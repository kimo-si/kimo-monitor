import SwiftUI

// 提供三个面板的真实数据对照窗口，也用于人工视觉验收。
@MainActor
final class PreviewWindow {
    private static var window: NSWindow?

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
        window.contentView = NSHostingView(rootView: content)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        self.window = window
    }
}
