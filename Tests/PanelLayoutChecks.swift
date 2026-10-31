import SwiftUI

// 用真实采样结果测量紧凑面板的内容高度，确保五行排行榜没有被裁切。
@main
struct PanelLayoutChecks {
    // 同时验证后端返回五项和前端完整容纳五项。
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let store = MonitorStore()
        store.start()
        try await Task.sleep(for: .seconds(MonitorConfiguration.interval + 1))
        precondition(store.snapshot.topMemory.count == 5 && store.snapshot.topCPU.count == 5)
        let width = MonitorKind.network.width - 28
        // 验证所有压力状态高度一致，避免异常状态将五行应用挤出面板。
        checkPressureLayouts(width: width)
        let measurements: [(MonitorKind, CGFloat)] = [
            (.network, contentHeight(NetworkContent(store: store), width: width)),
            (.memory, contentHeight(MemoryContent(store: store), width: width)),
            (.cpu, contentHeight(CPUContent(store: store), width: width))
        ]
        for (kind, height) in measurements {
            let available = kind.height - 71
            precondition(height <= available, "\(kind.title)内容高\(height)，超过可用\(available)，五行可能裁切")
            print("PASS: \(kind.title) \(kind.width)×\(kind.height) pt，五行内容高 \(height) / \(available) pt")
        }
        print("LIVE: 压力估算 \(MonitorFormat.percent(store.snapshot.memoryPressureEstimate?.fraction))，系统等级 \(store.snapshot.pressure.title)")
    }

    // 所有压力等级使用同一主卡片高度，不可用状态也必须完整显示。
    @MainActor private static func checkPressureLayouts(width: CGFloat) {
        let levels: [MemoryPressure] = [.normal, .warning, .critical, .unavailable]
        let readings: [UInt64?] = [nil, 0, 8, 51, 100]
        let heights = levels.flatMap { level in
            readings.map { compressed in
                let memory = compressed.map { MemoryUsage(total: 120, application: 0, wired: 20, compressed: $0, cached: 0) }
                let estimate = memory.flatMap { MemoryPressureEstimate(memory: $0) }
                return contentHeight(MemoryPressureStatus(pressure: level, estimate: estimate), width: width)
            }
        }
        precondition(Set(heights).count == 1, "压力状态切换不应改变主卡片高度")
        print("PASS: 内存压力主卡片四种状态高度一致，均为 \(heights[0]) pt")
    }

    // 指定面板的实际内容宽度后，读取 SwiftUI 的自然高度。
    @MainActor private static func contentHeight<Content: View>(_ content: Content, width: CGFloat) -> CGFloat {
        NSHostingView(rootView: content.frame(width: width)).fittingSize.height
    }
}
