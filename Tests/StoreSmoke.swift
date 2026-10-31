import AppKit

// 检查真实后台定时器与主线程发布，捕获只会在运行时出现的隔离错误。
@main
struct StoreSmoke {
    // 两次定时采样后验证数据已经从后台到达主线程。
    @MainActor static func main() async throws {
        let store = MonitorStore()
        let started = Date.now
        store.start()
        try await Task.sleep(for: .seconds(MonitorConfiguration.interval + 1))
        precondition(store.snapshot.sampledAt > started)
        precondition(store.snapshot.cpu != nil && store.snapshot.memory != nil)
        precondition(store.snapshot.topMemory.isEmpty && store.snapshot.topCPU.isEmpty,
                     "仅菜单栏运行时不应采集排行榜")
        let points = store.snapshot.cpuHistory
        precondition(points.count >= 2, "至少需要两次采样来测量更新间隔")
        let elapsed = points[1].time - points[0].time
        precondition(abs(elapsed - 2) < 0.5, "实际采样间隔不是约 2 秒：\(elapsed)")
        print("PASS: Swift 6 后台采样与主线程发布，实际采样间隔 \(elapsed) 秒")
        // 验证多个消费者、停用和重新打开不会保留失效进程数据。
        try await checkDetailDemand(store)
    }

    // 覆盖详情首帧、共享需求、最后关闭、隐藏列表和重新启用。
    @MainActor private static func checkDetailDemand(_ store: MonitorStore) async throws {
        store.setDetailsVisible(true, for: .overview)
        try await Task.sleep(for: .seconds(1))
        precondition(!store.snapshot.topMemory.isEmpty)
        let path = store.snapshot.topMemory.compactMap(\.path).first
        if let icon = store.icon(for: path) {
            precondition(icon.representations.allSatisfy { $0.pixelsWide == 44 && $0.pixelsHigh == 44 })
        }
        store.setDetailsVisible(true, for: .popover)
        store.setDetailsVisible(false, for: .overview)
        precondition(!store.snapshot.topMemory.isEmpty, "另一个详情仍可见时不能停止采样")
        store.setDetailsVisible(false, for: .popover)
        try await Task.sleep(for: .seconds(1))
        precondition(store.snapshot.topMemory.isEmpty && store.icon(for: path) == nil)
        store.preferences.value.showApplications = false
        store.setDetailsVisible(true, for: .overview)
        try await Task.sleep(for: .seconds(1))
        precondition(store.snapshot.topMemory.isEmpty)
        store.preferences.value.showApplications = true
        try await Task.sleep(for: .seconds(3))
        precondition(!store.snapshot.topMemory.isEmpty && !store.snapshot.topCPU.isEmpty)
        print("PASS: 详情按需采样、多窗口共享、图标尺寸与释放、列表设置切换")
    }
}
