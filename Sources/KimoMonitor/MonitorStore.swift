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

    // 使用唯一的设置对象供采样、菜单栏和设置窗口共享。
    init(preferences: PreferencesStore = PreferencesStore()) { self.preferences = preferences }

    // 取消唯一的采样源，避免对象释放后继续唤醒。
    deinit { timer?.cancel(); wakeTask?.cancel() }

    // 所有阻塞系统调用都在独立队列执行，主线程只接收快照。
    func start() {
        guard timer == nil else { return }
        // 先将持久化配置发送到后台队列，再启动唯一采样定时器。
        applyPreferences(preferences.value)
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
            let value = sampler.sample()
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

    // 只为当前排行榜中的应用首次读取图标。
    private func publish(_ value: MonitorSnapshot) {
        for app in value.topMemory + value.topCPU {
            guard let path = app.path, icons[path] == nil else { continue }
            icons[path] = NSWorkspace.shared.icon(forFile: path)
        }
        snapshot = value
        // 根据真实快照处理可选通知，不增加额外采样。
        alerts.evaluate(value, preferences: preferences.value)
    }

    // 视图读取缓存，不在 body 中查询系统或磁盘。
    func icon(for path: String?) -> NSImage? {
        guard let path else { return nil }
        return icons[path]
    }
}
