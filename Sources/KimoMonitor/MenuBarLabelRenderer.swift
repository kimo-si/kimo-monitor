import SwiftUI
import Observation

// 将双行标签合成为原生状态按钮使用的 Retina 模板图，保留原始字形比例。
@MainActor
final class MenuBarLabelRenderer {
    private struct CachedLabel {
        let text: String
        let image: NSImage
    }
    private var cache: [MonitorKind: CachedLabel] = [:]
    static let imageHeight: CGFloat = MenuBarLayout.height

    // 仅在显示文字变化时重绘；状态图始终保持固定尺寸。
    func image(for kind: MonitorKind, snapshot: MonitorSnapshot, preferences: MonitorPreferences = MonitorPreferences()) -> NSImage {
        let text = accessibilityText(for: kind, snapshot: snapshot, preferences: preferences)
        if let cached = cache[kind], cached.text == text { return cached.image }
        let image = render(kind: kind, snapshot: snapshot, preferences: preferences)
        cache[kind] = CachedLabel(text: text, image: image)
        return image
    }

    // 为纯图像菜单标签保留完整的 VoiceOver 读数。
    func accessibilityText(for kind: MonitorKind, snapshot: MonitorSnapshot, preferences: MonitorPreferences = MonitorPreferences()) -> String {
        switch kind {
        case .network: preferences.networkDisplay.title + "，上传 " + MonitorFormat.menuRate(snapshot.upload, unit: preferences.rateUnit) + "，下载 " + MonitorFormat.menuRate(snapshot.download, unit: preferences.rateUnit)
        case .memory: (preferences.memoryDisplay == .pressure ? "内存压力估算" : preferences.memoryDisplay.title) + " " + (preferences.memoryDisplay == .pressure ? MonitorFormat.percent(snapshot.memoryPressureEstimate?.fraction) : preferences.memoryDisplay == .usage ? MonitorFormat.percent(snapshot.memory?.fraction) : snapshot.memory.map { MonitorFormat.bytes($0.used, unit: preferences.memoryUnit) } ?? "—") + "，系统等级 " + snapshot.pressure.title
        case .cpu: "CPU " + MonitorFormat.percent(snapshot.cpu)
        }
    }

    // 按布局的原生点尺寸生成 Retina 模板图，保持粗体字形的原始宽高比。
    private func render(kind: MonitorKind, snapshot: MonitorSnapshot, preferences: MonitorPreferences) -> NSImage {
        let width = kind == .network ? MenuBarLayout.networkWidth : (kind == .memory && preferences.memoryDisplay == .used ? MenuBarLayout.memoryCapacityWidth : MenuBarLayout.metricWidth)
        let renderer = ImageRenderer(content: MenuLabel(kind: kind, snapshot: snapshot, preferences: preferences))
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(width: width, height: MenuBarLayout.height)
        guard let image = renderer.nsImage else { return failureImage(width: width) }
        image.isTemplate = true
        return image
    }

    // 渲染失败时显示明确的错误标记，保留固定宽度且不发布伪造读数。
    private func failureImage(width: CGFloat) -> NSImage {
        let image = NSImage(systemSymbolName: "exclamationmark.circle", accessibilityDescription: "菜单栏绘制失败")
            ?? NSImage(size: NSSize(width: width, height: Self.imageHeight))
        image.size = NSSize(width: width, height: Self.imageHeight)
        image.isTemplate = true
        return image
    }
}

// 为每个指标创建独立状态项，并复用同一个详情面板容器。
@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    private let store: MonitorStore
    private let renderer = MenuBarLabelRenderer()
    private let popover = NSPopover()
    private var items: [MonitorKind: NSStatusItem] = [:]
    private var activeKind: MonitorKind?
    private var isRunning = true
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?
    var presentedKind: MonitorKind? { popover.isShown ? activeKind : nil }

    // 创建三个独立入口并订阅同一份快照，不增加采样器或刷新定时器。
    init(store: MonitorStore) {
        self.store = store
        super.init()
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.delegate = self
        NotificationCenter.default.addObserver(self, selector: #selector(applicationDidResignActive),
                                               name: NSApplication.didResignActiveNotification, object: NSApp)
        // 创建三个独立状态项，交由系统分别管理点击与位置。
        for kind in MonitorKind.allCases { items[kind] = makeStatusItem(for: kind) }
        // 数据变化后只更新标签，图像缓存继续负责避免重复绘制。
        observeSnapshot()
    }

    // 按原始图像尺寸更新状态按钮，固定边距不会随数字和单位变化。
    func update(snapshot: MonitorSnapshot) {
        let preferences = store.preferences.value
        for (kind, item) in items {
            let visible = kind == .cpu ? preferences.showCPU : kind == .memory ? preferences.showMemory : preferences.showNetwork
            item.isVisible = visible
            item.length = kind == .memory && preferences.memoryDisplay == .used ? MenuBarLayout.memoryCapacityWidth : MenuBarLayout.statusItemWidth(for: kind)
            if !visible && activeKind == kind { closePanel() }
            let description = renderer.accessibilityText(for: kind, snapshot: snapshot, preferences: preferences)
            item.button?.image = renderer.image(for: kind, snapshot: snapshot, preferences: preferences)
            item.button?.toolTip = description
            item.button?.setAccessibilityLabel(description)
        }
    }

    // 应用退出时停止订阅并移除状态项，防止残留入口。
    func stop() {
        isRunning = false
        // 停止事件监听，避免关闭后继续响应其他应用的点击。
        stopMonitoringClicks()
        NotificationCenter.default.removeObserver(self)
        popover.performClose(nil)
        for item in items.values { NSStatusBar.system.removeStatusItem(item) }
        items.removeAll()
    }

    // 为每个指标创建原生状态项，并保留各自的系统位置和交互。
    private func makeStatusItem(for kind: MonitorKind) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: MenuBarLayout.statusItemWidth(for: kind))
        item.autosaveName = "com.kimo.monitor." + kind.rawValue
        item.button?.identifier = NSUserInterfaceItemIdentifier(kind.rawValue)
        item.button?.imagePosition = .imageOnly
        item.button?.imageScaling = .scaleNone
        if #available(macOS 27, *) {
            item.expandedInterfaceDelegate = self
        } else {
            item.button?.target = self
            item.button?.action = #selector(togglePanel(_:))
        }
        return item
    }

    // Observation 只在快照发布时重新订阅，所有状态按钮操作保持在主线程。
    private func observeSnapshot() {
        guard isRunning else { return }
        withObservationTracking {
            // 将当前快照绘制到三个原生按钮，并跟踪下一次快照发布。
            update(snapshot: store.snapshot)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeSnapshot() }
        }
    }

    // 同一入口关闭面板，另一入口切换到对应面板。
    @objc func togglePanel(_ sender: NSStatusBarButton) {
        guard let kind = items.first(where: { $0.value.button === sender })?.key else { return }
        if presentedKind == kind { closePanel(); return }
        // 将原有 SwiftUI 面板锚定到用户选择的指标下方。
        showPanel(for: kind, button: sender)
    }

    // 三个入口共用弹出容器，详情内容与实时对照窗口使用相同视图和数据。
    private func showPanel(for kind: MonitorKind, button: NSStatusBarButton) {
        popover.performClose(nil)
        activeKind = kind
        popover.contentViewController = NSHostingController(rootView: MonitorPanel(kind: kind, store: store))
        popover.contentSize = NSSize(width: kind.width, height: kind.height)
        NSApplication.shared.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // 只在面板显示期间监听外部点击，避免按钮点击与系统自动关闭竞争。
        if popover.isShown { startMonitoringClicks() }
    }

    // 关闭面板并清理与本次展示绑定的点击监听。
    private func closePanel() {
        stopMonitoringClicks()
        popover.performClose(nil)
    }

    // 同时监听应用内和其他应用的点击，不拦截事件本身。
    private func startMonitoringClicks() {
        stopMonitoringClicks()
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
            self?.handleLocalClick(event)
            return event
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
            Task { @MainActor [weak self] in self?.closePanel() }
        }
    }

    // 指标按钮与面板内部的点击交由各自处理，其他应用内点击关闭面板。
    private func handleLocalClick(_ event: NSEvent) {
        if event.window === popover.contentViewController?.view.window { return }
        if items.values.contains(where: { $0.button?.window === event.window }) { return }
        closePanel()
    }

    // 移除所有事件监听，保证重复打开面板不会累积监听器。
    private func stopMonitoringClicks() {
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        localClickMonitor = nil
        globalClickMonitor = nil
    }

    // 切换到其他应用时关闭当前面板。
    @objc private func applicationDidResignActive(_ notification: Notification) {
        closePanel()
    }

    // 面板被系统关闭时同步清理状态和监听。
    func popoverDidClose(_ notification: Notification) {
        stopMonitoringClicks()
        let closedKind = activeKind
        activeKind = nil
        // 面板自行关闭时，同步结束对应的系统菜单栏会话。
        if #available(macOS 27, *), let kind = closedKind {
            items[kind]?.expandedInterfaceSession?.cancel()
        }
    }
}

@available(macOS 27, *)
extension MenuBarController: @MainActor NSStatusItemExpandedInterfaceDelegate {
    // 系统开始跟踪指定状态项时，打开该指标对应的面板。
    func statusItem(_ statusItem: NSStatusItem, didBegin session: NSStatusItemExpandedInterfaceSession) {
        guard let kind = items.first(where: { $0.value === statusItem })?.key,
              let button = statusItem.button else { return }
        showPanel(for: kind, button: button)
    }

    // 系统结束跟踪时关闭对应面板，避免切换入口后残留窗口。
    func statusItemDidEndExpandedInterfaceSession(_ statusItem: NSStatusItem, animated: Bool) {
        guard let kind = activeKind, items[kind] === statusItem else { return }
        closePanel()
    }
}
