import SwiftUI

// 在真实系统菜单栏中验证固定宽度、原始图像和实时采样订阅。
@main
struct MenuBarSystemChecks: App {
    // 场景注册完成后创建与生产相同的菜单控制器。
    init() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            await Self.checkStatusItems()
            NSApplication.shared.terminate(nil)
        }
    }
    var body: some Scene { Settings { EmptyView() } }

    // 检查真实按钮的两侧边距，并覆盖动态更新与后台快照发布。
    @MainActor private static func checkStatusItems() async {
        let store = MonitorStore()
        let controller = MenuBarController(store: store)
        defer { controller.stop() }
        try? await Task.sleep(for: .milliseconds(300))
        let original = buttonSizes()
        precondition(original.count == 3)
        // 验证三个指标由独立的原生状态按钮承载。
        checkIndependentItems()
        // 验证三个入口仍能各自打开和关闭对应面板。
        checkPanelActions(controller: controller)
        // 验证应用失去焦点后面板关闭，且可以再次打开。
        checkApplicationDeactivation(controller: controller)
        // 通过应用事件队列验证同一应用中点击面板外部会关闭面板。
        await checkOutsideClick(controller: controller)
        // 改变所有菜单读数，确认原生按钮不会恢复系统默认宽边距。
        await checkChangingReadings(controller: controller, original: original)
        // 总览和设置关闭后必须销毁宿主视图，且能重新打开。
        checkWindowRelease(store: store)
        // 启动真实采样，验证 Observation 会把下一份快照送到状态按钮。
        store.start()
        try? await Task.sleep(for: .seconds(MonitorConfiguration.interval + 1))
        let renderer = MenuBarLabelRenderer()
        for button in statusButtons() {
            guard let identifier = button.identifier, let kind = MonitorKind(rawValue: identifier.rawValue) else {
                preconditionFailure("菜单入口缺少指标标识")
            }
            precondition(button.accessibilityLabel() == renderer.accessibilityText(for: kind, snapshot: store.snapshot))
        }
        print("PASS: 三个独立状态项的面板操作和实时更新均正确；尺寸 \(original)")
    }

    // 实际创建并重复关闭窗口，检查关闭后没有保留观察实时快照的内容视图。
    @MainActor private static func checkWindowRelease(store: MonitorStore) {
        for _ in 0..<2 {
            PreviewWindow.show(store: store)
            guard let overview = NSApp.windows.first(where: { $0.title == "Kimo Monitor · 实时对照" && $0.isVisible }) else {
                preconditionFailure("总览没有重新打开")
            }
            overview.close()
            precondition(overview.contentView == nil, "关闭后必须释放总览视图")
            SettingsWindow.show(store: store)
            guard let settings = NSApp.windows.first(where: { $0.title == "Kimo Monitor 设置" && $0.isVisible }) else {
                preconditionFailure("设置没有重新打开")
            }
            settings.close()
            precondition(settings.contentViewController == nil, "关闭后必须释放设置视图")
        }
        print("PASS: 总览与设置关闭后释放视图，连续两次重开正常")
    }


    // 向独立窗口投递鼠标事件，验证面板外部点击经过事件监听器后关闭面板。
    @MainActor private static func checkOutsideClick(controller: MenuBarController) async {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 100, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        guard let button = statusButtons().first,
              let event = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 20, y: 20),
                                             modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil,
                                             eventNumber: 1, clickCount: 1, pressure: 1) else {
            preconditionFailure("无法构造面板外部点击")
        }
        controller.togglePanel(button)
        precondition(controller.presentedKind != nil, "外部点击测试前面板未打开")
        NSApp.postEvent(event, atStart: false)
        // 等待事件队列处理点击，避免机器繁忙时固定短延迟造成误报。
        for _ in 0..<20 where controller.presentedKind != nil {
            try? await Task.sleep(for: .milliseconds(100))
        }
        precondition(controller.presentedKind == nil, "应用内点击面板外部后面板未关闭")
        print("PASS: 应用内点击面板外部时关闭面板")
    }

    // 模拟系统失焦通知，覆盖每个面板的关闭和重新打开。
    @MainActor private static func checkApplicationDeactivation(controller: MenuBarController) {
        for button in statusButtons() {
            guard let id = button.identifier, let kind = MonitorKind(rawValue: id.rawValue) else {
                preconditionFailure("菜单入口缺少指标标识")
            }
            controller.togglePanel(button)
            precondition(controller.presentedKind == kind, "失焦测试前面板未打开")
            NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
            precondition(controller.presentedKind == nil, "应用失焦后面板未关闭")
            controller.togglePanel(button)
            precondition(controller.presentedKind == kind, "失焦关闭后无法重新打开")
            controller.togglePanel(button)
        }
        print("PASS: 三个面板在应用失焦时关闭，随后均可重新打开")
    }

    // 验证三个入口各自拥有独立的系统窗口和可命中的状态按钮。
    @MainActor private static func checkIndependentItems() {
        let buttons = statusButtons()
        precondition(buttons.count == 3)
        precondition(Set(buttons.compactMap { $0.identifier?.rawValue }) == Set(MonitorKind.allCases.map(\.rawValue)))
        precondition(Set(buttons.compactMap { $0.window }.map(ObjectIdentifier.init)).count == 3, "指标必须使用独立状态项")
        for button in buttons {
            guard let content = button.window?.contentView else { preconditionFailure("状态按钮没有窗口") }
            let center = NSPoint(x: button.bounds.midX, y: button.bounds.midY)
            precondition(content.hitTest(button.convert(center, to: content)) === button, "鼠标未命中对应状态按钮")
        }
        let measurements = buttons.map { "\($0.identifier?.rawValue ?? "?"): \($0.window?.frame.width ?? 0) pt" }
        print("PASS: CPU、MEM、网速分别拥有独立原生状态项，系统分配宽度：\(measurements)")
    }

    // 通过控制器动作验证每个指标都能切换独立的弹出面板。
    @MainActor private static func checkPanelActions(controller: MenuBarController) {
        let allButtons = statusButtons()
        for button in allButtons {
            guard let id = button.identifier, let kind = MonitorKind(rawValue: id.rawValue) else {
                preconditionFailure("菜单入口缺少指标标识")
            }
            controller.togglePanel(button)
            precondition(controller.presentedKind == kind, "点击未打开或切换对应面板")
        }
        if let last = allButtons.last { controller.togglePanel(last) }
        precondition(controller.presentedKind == nil, "再次点击未关闭面板")
        for button in statusButtons() {
            guard let id = button.identifier, let kind = MonitorKind(rawValue: id.rawValue) else {
                preconditionFailure("菜单入口缺少指标标识")
            }
            controller.togglePanel(button)
            precondition(controller.presentedKind == kind, "点击未打开对应面板")
            controller.togglePanel(button)
            precondition(controller.presentedKind == nil, "再次点击未关闭面板")
        }
    }

    // 同时改变速率、内存百分比和等级，覆盖一位至三位数字。
    @MainActor private static func checkChangingReadings(controller: MenuBarController, original: [NSSize]) async {
        let levels: [MemoryPressure] = [.normal, .warning, .critical, .unavailable]
        let compressed: [UInt64] = [0, 8, 51, 100]
        for (index, (rate, pressure)) in zip([8_000.0, 512_000, 12_400_000, 999_900_000_000], levels).enumerated() {
            var snapshot = MonitorSnapshot()
            snapshot.upload = rate
            snapshot.download = rate
            snapshot.cpu = 0.28
            snapshot.pressure = pressure
            snapshot.memory = MemoryUsage(total: 120, application: 0, wired: 20, compressed: compressed[index], cached: 0)
            controller.update(snapshot: snapshot)
            try? await Task.sleep(for: .milliseconds(100))
            precondition(buttonSizes() == original, "读数变化导致实际状态按钮宽度改变")
        }
    }

    // 测量按钮、原始图像和原生绘制矩形，防止以缩放文字换取紧凑间距。
    @MainActor private static func buttonSizes() -> [NSSize] {
        let buttons = statusButtons()
        precondition(buttons.count == 3)
        for button in buttons {
            guard let image = button.image else { preconditionFailure("状态按钮缺少图像") }
            precondition(button.title.isEmpty && image.isTemplate)
            precondition(image.size.height == MenuBarLabelRenderer.imageHeight)
            precondition(button.frame.width == image.size.width, "状态项宽度必须与完整图像一致")
            precondition(button.cell?.imageRect(forBounds: button.bounds).width == image.size.width, "状态图像被压缩或裁切")
        }
        return buttons.map(\.frame.size).sorted { $0.width < $1.width }
    }

    // 只获取本测试进程中的状态按钮，不读取或修改其他应用的状态项。
    @MainActor private static func statusButtons() -> [NSStatusBarButton] {
        NSApp.windows.flatMap { buttons(in: $0.contentView) }
    }

    // 递归查找本进程窗口内的原生状态按钮。
    @MainActor private static func buttons(in view: NSView?) -> [NSStatusBarButton] {
        guard let view else { return [] }
        let current = (view as? NSStatusBarButton).flatMap { button in
            button.identifier.flatMap { MonitorKind(rawValue: $0.rawValue) } == nil ? nil : button
        }.map { [$0] } ?? []
        return current + view.subviews.flatMap { buttons(in: $0) }
    }
}
