import AppKit
import SwiftUI
import UserNotifications

// 管理单例设置窗口，让菜单栏入口始终打开同一份配置。
@MainActor
final class SettingsWindow {
    private static var window: NSWindow?

    // 展示左侧导航和对应设置，并复用正在运行的采样器。
    static func show(store: MonitorStore) {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 570),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Kimo Monitor 设置"
        window.minSize = NSSize(width: 680, height: 470)
        window.isReleasedWhenClosed = false
        // 让系统托管导航工具栏与内容区域，避免表单延伸到工具栏下方。
        window.contentViewController = NSHostingController(rootView: SettingsView(store: store))
        // 托管控制器会按内容重算窗口尺寸，恢复设置窗口的初始大小。
        window.setContentSize(NSSize(width: 760, height: 570))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        self.window = window
    }
}

// 设置侧边栏中的固定页面。
enum SettingsPage: String, CaseIterable, Identifiable {
    case general, menuBar, monitoring, panel, alerts, about
    var id: Self { self }
    var title: String {
        switch self { case .general: "通用"; case .menuBar: "菜单栏"; case .monitoring: "监控"; case .panel: "面板"; case .alerts: "通知"; case .about: "关于" }
    }
    var icon: String {
        switch self { case .general: "gearshape"; case .menuBar: "menubar.rectangle"; case .monitoring: "waveform.path.ecg"; case .panel: "rectangle.on.rectangle"; case .alerts: "bell"; case .about: "info.circle" }
    }
}

// 左侧导航切换设置页面，所有页面共享同一份实时配置。
struct SettingsView: View {
    let store: MonitorStore
    @State private var selection: SettingsPage? = .general
    var body: some View {
        HStack(spacing: 0) {
            List(SettingsPage.allCases, selection: $selection) { page in
                Label(page.title, systemImage: page.icon).tag(page)
            }
            .listStyle(.sidebar)
            .frame(width: 175)
            Divider()
            SettingsPageView(store: store, page: selection ?? .general)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }.frame(minWidth: 680, minHeight: 470)
    }
}

// 按页面组织设置项与操作说明。
struct SettingsPageView: View {
    let store: MonitorStore
    let page: SettingsPage
    @State private var confirmReset = false
    @State private var notificationStatus = ""
    @Bindable private var settings: PreferencesStore

    // 复用应用持有的设置对象，确保修改即时生效。
    init(store: MonitorStore, page: SettingsPage) {
        self.store = store
        self.page = page
        self.settings = store.preferences
    }

    var body: some View {
        Form {
            switch page {
            case .general: general
            case .menuBar: menuBar
            case .monitoring: monitoring
            case .panel: panel
            case .alerts: alerts
            case .about: about
            }
        }
        .formStyle(.grouped)

        .alert("恢复默认设置？", isPresented: $confirmReset) {
            Button("恢复默认", role: .destructive) { settings.reset() }
            Button("取消", role: .cancel) { }
        } message: { Text("将重置所有设置并关闭登录启动，不会更改系统通知权限。") }
        .onChange(of: settings.value.cpuAlerts) { _, enabled in if enabled { requestNotifications() } }
        .onChange(of: settings.value.memoryAlerts) { _, enabled in if enabled { requestNotifications() } }
        .task(id: page) { if page == .alerts { await refreshNotificationStatus() } }
    }

    private var general: some View {
        Group {
            Section("启动") {
                Toggle("登录时启动", isOn: Binding(get: { settings.loginEnabled }, set: { settings.setLoginEnabled($0) }))
                Toggle("启动时打开实时总览", isOn: $settings.value.openOverview)
                if let error = settings.loginError { Text(error).foregroundStyle(.red) }
                Text("登录启动由 macOS 管理，部分状态可能需要在系统设置中确认。") .foregroundStyle(.secondary)
            }
            Section("重置") {
                Button("恢复默认设置…") { confirmReset = true }
            }
        }
    }

    private var menuBar: some View {
        Group {
            Section("显示指标") {
                Toggle("CPU", isOn: $settings.value.showCPU).disabled(!settings.value.showMemory && !settings.value.showNetwork)
                Toggle("内存", isOn: $settings.value.showMemory).disabled(!settings.value.showCPU && !settings.value.showNetwork)
                Toggle("网速", isOn: $settings.value.showNetwork).disabled(!settings.value.showCPU && !settings.value.showMemory)
                Text("至少保留一个菜单栏入口；可通过系统的菜单栏操作调整位置。") .foregroundStyle(.secondary)
            }
            Section("显示内容") {
                Picker("内存", selection: $settings.value.memoryDisplay) {
                    ForEach(MemoryDisplay.allCases) { Text($0.title).tag($0) }
                }
                Picker("网速", selection: $settings.value.networkDisplay) {
                    ForEach(NetworkDisplay.allCases) { Text($0.title).tag($0) }
                }
                Text("压力估算与内存占用率是不同指标，估算不等同于系统压力曲线。") .foregroundStyle(.secondary)
            }
            Section("实时预览") {
                HStack(spacing: 16) {
                    if settings.value.showCPU { MenuLabel(kind: .cpu, snapshot: store.snapshot, preferences: settings.value) }
                    if settings.value.showMemory { MenuLabel(kind: .memory, snapshot: store.snapshot, preferences: settings.value) }
                    if settings.value.showNetwork { MenuLabel(kind: .network, snapshot: store.snapshot, preferences: settings.value) }
                }.padding(8).background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var monitoring: some View {
        Group {
            Section("采样") {
                Picker("采样间隔", selection: $settings.value.interval) {
                    ForEach([1.0, 2.0, 5.0, 10.0], id: \.self) { Text("\(Int($0)) 秒").tag($0) }
                }
                Text("采样越频繁，数值响应越快，也可能增加系统开销。") .foregroundStyle(.secondary)
            }
            Section("单位与网络") {
                Picker("网速单位", selection: $settings.value.rateUnit) { ForEach(RateUnit.allCases) { Text($0.title).tag($0) } }
                Picker("容量单位", selection: $settings.value.memoryUnit) { ForEach(MemoryUnit.allCases) { Text($0.title).tag($0) } }
                Picker("网络接口", selection: $settings.value.networkInterface) {
                    Text("自动（所有活跃物理接口）").tag("")
                    if !settings.value.networkInterface.isEmpty && !store.snapshot.interfaces.contains(settings.value.networkInterface) {
                        Text("\(settings.value.networkInterface)（未连接）").tag(settings.value.networkInterface)
                    }
                    ForEach(store.snapshot.interfaces, id: \.self) { Text($0).tag($0) }
                }
                Text("仅列出活跃的 en 接口；切换接口后会重新建立速率基线。") .foregroundStyle(.secondary)
            }
        }
    }

    private var panel: some View {
        Group {
            Section("外观") {
                Picker("主题", selection: $settings.value.theme) { ForEach(PanelTheme.allCases) { Text($0.title).tag($0) } }
                Toggle("显示趋势图", isOn: $settings.value.showCharts)
                Toggle("显示应用列表", isOn: $settings.value.showApplications)
            }
            Section("内容") {
                Picker("图表时间范围", selection: $settings.value.historySeconds) {
                    ForEach([60.0, 300.0, 900.0], id: \.self) { Text("\(Int($0 / 60)) 分钟").tag($0) }
                }
                Picker("应用排行数量", selection: $settings.value.processLimit) {
                    ForEach([5, 10, 15], id: \.self) { Text("\($0) 项").tag($0) }
                }
                Text("更长时间范围从切换后开始积累；应用列表支持滚动。") .foregroundStyle(.secondary)
            }
        }
    }

    private var alerts: some View {
        Group {
            Section("提醒") {
                Toggle("CPU 持续高占用", isOn: $settings.value.cpuAlerts)
                Picker("CPU 阈值", selection: $settings.value.cpuThreshold) {
                    ForEach([50.0, 70.0, 80.0, 90.0, 95.0], id: \.self) { Text("\(Int($0))% ").tag($0) }
                }.disabled(!settings.value.cpuAlerts)
                Picker("持续时间", selection: $settings.value.cpuDuration) {
                    ForEach([10.0, 30.0, 60.0, 300.0], id: \.self) { Text("\(Int($0)) 秒").tag($0) }
                }.disabled(!settings.value.cpuAlerts)
                Toggle("系统内存压力偏高或紧张", isOn: $settings.value.memoryAlerts)
                Picker("重复提醒间隔", selection: $settings.value.alertCooldown) {
                    ForEach([60.0, 300.0, 900.0, 3600.0], id: \.self) { Text("\(Int($0 / 60)) 分钟").tag($0) }
                }
            }
            Section("系统权限") { Text(notificationStatus).foregroundStyle(.secondary) }
        }
    }

    private var about: some View {
        Group {
            Section("Kimo Monitor") {
                LabeledContent("版本", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                LabeledContent("构建", value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—")
                Button("打开实时对照总览") { PreviewWindow.show(store: store) }
            }
            Section("统计口径") {
                Text("CPU 按全部逻辑核心归一化。内存压力估算是压缩内存占非连线内存的比例，不等同于系统压力曲线。")
                Text("网速为活跃物理接口的字节差分。本次流量只包含运行期间实际观测的增量；应用网速尚未接入。")
                Text("采样数据仅在本机内存中处理，退出后不保留历史图表。")
            }
        }
    }

    // 开启任一通知时请求权限，拒绝时关闭提醒并说明原因。
    private func requestNotifications() {
        Task { @MainActor in
            let granted = await AlertController.requestPermission()
            if !granted {
                settings.value.cpuAlerts = false
                settings.value.memoryAlerts = false
            }
            await refreshNotificationStatus()
        }
    }

    // 展示系统真实授权状态，不猜测权限是否生效。
    private func refreshNotificationStatus() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        switch status {
        case .authorized, .provisional, .ephemeral: notificationStatus = "通知权限已开启。"
        case .denied: notificationStatus = "通知权限已关闭，请在 macOS 系统设置的通知中开启。"
        case .notDetermined: notificationStatus = "开启提醒后会请求系统通知权限。"
        @unknown default: notificationStatus = "无法确认通知权限状态。"
        }
    }
}
