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
        precondition(!store.snapshot.topMemory.isEmpty)
        let points = store.snapshot.cpuHistory
        precondition(points.count >= 2, "至少需要两次采样来测量更新间隔")
        let elapsed = points[1].time - points[0].time
        precondition(abs(elapsed - 2) < 0.5, "实际采样间隔不是约 2 秒：\(elapsed)")
        print("PASS: Swift 6 后台采样与主线程发布，实际采样间隔 \(elapsed) 秒")
    }
}
