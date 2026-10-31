import AppKit
import Observation

// 负责采样调度、主线程发布与展示图标缓存。
@MainActor @Observable
final class MonitorStore {
    private(set) var snapshot = MonitorSnapshot()
    let preferences: PreferencesStore
    @ObservationIgnored private let alerts = AlertController()
    @ObservationIgnored private var lastPreferences: MonitorPreferences?
    @ObservationIgnored private let queue = DispatchQueue(label: "com.kimo.monitor.sampler", qos: .utility)
    @ObservationIgnored private let sampler = SystemSampler()
    @ObservationIgnored private var timer: DispatchSourceTimer?
    @ObservationIgnored private var wakeTask: Task<Void, Never>?
    @ObservationIgnored private var icons: [String: NSImage] = [:]
    @ObservationIgnored private var detailConsumers: Set<DetailConsumer> = []
    @ObservationIgnored private var applicationsEnabled = false

    // 使用唯一的设置对象供采样、菜单栏和设置窗口共享。
    init(preferences: PreferencesStore = PreferencesStore()) { self.preferences = preferences }

    // 取消唯一的采样源，避免对象释放后继续唤醒。
    deinit { timer?.cancel(); wakeTask?.cancel() }

    // 所有阻塞系统调用都在独立队列执行，主线程只接收快照。
    func start() {
        guard timer == nil else { return }
        // 先将持久化配置发送到后台队列，再启动唯一采样定时器。
        observePreferences()
        // 系统唤醒后重新建立差分基线，防止出现虚假的速率尖峰。
        observeWake()
    }

    // 配置变化时串行更新采样器，并只在间隔变化时重新调度定时器。
    private func applyPreferences(_ value: MonitorPreferences) {
        let old = lastPreferences
        lastPreferences = value
        let sampler = self.sampler
        queue.async { sampler.configure(value) }
        // 显示设置改变后同步排行榜需求，不创建第二个定时器。
        configureApplications()
        if timer == nil { createTimer(interval: value.interval) }
        else if old?.interval != value.interval {
            timer?.schedule(deadline: .now() + value.interval, repeating: value.interval, leeway: .milliseconds(150))
        }
    }

    // 创建后台采样源，回调只向主线程发布不可变快照。
    private func createTimer(interval: Double) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(150))
        let sampler = self.sampler
        timer.setEventHandler { @Sendable [weak self] in
            let value = autoreleasepool { sampler.sample() }
            Task { @MainActor [weak self] in self?.publish(value) }
        }
        self.timer = timer
        timer.resume()
    }

    // 订阅用户设置，变化后重新注册 Observation 跟踪。
    private func observePreferences() {
        withObservationTracking {
            applyPreferences(preferences.value)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observePreferences() }
        }
    }

    // 通过异步通知接收系统唤醒事件，不新增轮询定时器。
    private func observeWake() {
        wakeTask = Task { @MainActor [weak self] in
            let notifications = NSWorkspace.shared.notificationCenter.notifications(named: NSWorkspace.didWakeNotification)
            for await _ in notifications {
                guard !Task.isCancelled else { return }
                self?.resetBaseline()
            }
        }
    }

    // 复位与采集排在同一队列，确保旧值不会跨越唤醒边界。
    private func resetBaseline() {
        let sampler = self.sampler
        queue.async { @Sendable in sampler.resetBaseline() }
    }

    // 按使用者登记可见性，总览与弹出面板共享一份进程采样。
    func setDetailsVisible(_ visible: Bool, for consumer: DetailConsumer) {
        if visible { detailConsumers.insert(consumer) }
        else { detailConsumers.remove(consumer) }
        // 仅在最终需求变化时启动或停用进程采集。
        configureApplications()
    }

    // 没有可见应用列表时释放详情，重新打开时立即采集首帧。
    private func configureApplications() {
        let enabled = !detailConsumers.isEmpty && preferences.value.showApplications
        guard enabled != applicationsEnabled else { return }
        applicationsEnabled = enabled
        let sampler = self.sampler
        queue.async { [weak self] in
            // 在同一串行队列切换需求，避免与定时采样竞争。
            sampler.setApplicationsEnabled(enabled)
            guard enabled else { return }
            let value = autoreleasepool { sampler.sample() }
            Task { @MainActor [weak self] in self?.publish(value) }
        }
        if !enabled {
            icons.removeAll()
            snapshot.topMemory = []
            snapshot.topCPU = []
        }
    }

    // 只为当前排行榜中的应用首次读取图标。
    private func publish(_ value: MonitorSnapshot) {
        var current = value
        if !applicationsEnabled { current.topMemory = []; current.topCPU = [] }
        // 缓存只覆盖当前排行，图标缩到实际 Retina 展示尺寸后保留。
        updateIcons(current)
        snapshot = current
        // 根据真实快照处理可选通知，不增加额外采样。
        alerts.evaluate(value, preferences: preferences.value)
    }

    // 移除不再展示的图标，避免长时间运行时随应用切换无限增长。
    private func updateIcons(_ value: MonitorSnapshot) {
        let paths = Set((value.topMemory + value.topCPU).compactMap(\.path))
        icons = icons.filter { paths.contains($0.key) }
        for path in paths where icons[path] == nil {
            icons[path] = autoreleasepool { thumbnail(for: path) }
        }
    }

    // 将系统多尺寸图标栅格化为小位图，不长期持有原始高分辨率图像。
    private func thumbnail(for path: String) -> NSImage? {
        let size = MonitorConfiguration.applicationIconSize
        let scale = MonitorConfiguration.applicationIconScale
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size * scale),
                                            pixelsHigh: Int(size * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: scale, y: scale)
        NSWorkspace.shared.icon(forFile: path).draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        bitmap.size = NSSize(width: size, height: size)
        let image = NSImage(size: bitmap.size)
        image.addRepresentation(bitmap)
        return image
    }

    // 视图读取缓存，不在 body 中查询系统或磁盘。
    func icon(for path: String?) -> NSImage? {
        guard let path else { return nil }
        return icons[path]
    }
}
