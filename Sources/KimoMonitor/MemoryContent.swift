import SwiftUI

// 优先显示压力估算百分比及真实系统等级，内存占用和系统余量作为辅助信息。
struct MemoryContent: View {
    let store: MonitorStore
    private var memory: MemoryUsage? { store.snapshot.memory }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MemoryPressureStatus(pressure: store.snapshot.pressure, estimate: store.snapshot.memoryPressureEstimate)
                .padding(.bottom, 11)
            PanelDivider().padding(.bottom, 11)
            overview.padding(.bottom, 9)
            MemoryBar(memory: memory).frame(height: 14).padding(.bottom, 11)
            categories.padding(.bottom, 14)
            PanelDivider().padding(.bottom, 11)
            if store.preferences.value.showApplications { ApplicationList(store: store, mode: .memory, applications: store.snapshot.topMemory) }
        }
    }
    private var overview: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("内存占用").font(.system(size: 11))
                Spacer()
                Text("系统余量 " + MonitorFormat.percent(store.snapshot.memoryHeadroom?.fraction))
                    .font(.system(size: 10)).foregroundStyle(MonitorStyle.muted).monospacedDigit()
                    .help("系统报告的可用页比例，与 memory_pressure -Q 一致；独立于内存压力和占用率。")
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(memory.map { MonitorFormat.bytes($0.used, unit: store.preferences.value.memoryUnit) } ?? "—").font(.system(size: 16, weight: .medium))
                Text("/ " + (memory.map { MonitorFormat.bytes($0.total, unit: store.preferences.value.memoryUnit) } ?? "—"))
                    .font(.system(size: 11)).foregroundStyle(MonitorStyle.muted)
                Spacer(minLength: 0)
                Text(MonitorFormat.percent(memory?.fraction))
                    .font(.system(size: 18, weight: .medium)).foregroundStyle(MonitorStyle.purple)
            }.monospacedDigit()
        }
    }
    private var categories: some View {
        HStack(alignment: .top) {
            MemoryDetail(title: "应用", value: memory?.application, color: MonitorStyle.purple, unit: store.preferences.value.memoryUnit)
            Spacer(minLength: 2)
            MemoryDetail(title: "连线", value: memory?.wired, color: Color(red: 0.64, green: 0.43, blue: 0.96), unit: store.preferences.value.memoryUnit)
            Spacer(minLength: 2)
            MemoryDetail(title: "压缩", value: memory?.compressed, color: Color(white: 0.6), unit: store.preferences.value.memoryUnit)
            Spacer(minLength: 2)
            MemoryDetail(title: "可用", value: memory?.available, color: Color(white: 0.3), unit: store.preferences.value.memoryUnit)
        }.help("已使用 = 应用 + 连线 + 压缩。缓存文件另计：" + (memory.map { MonitorFormat.bytes($0.cached, unit: store.preferences.value.memoryUnit) } ?? "—"))
    }
}

// 明确区分估算百分比和真实系统等级，颜色始终由系统等级决定。
struct MemoryPressureStatus: View {
    let pressure: MemoryPressure
    let estimate: MemoryPressureEstimate?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("压力估算").font(.system(size: 11))
                Spacer()
                Text(MonitorFormat.percent(estimate?.fraction))
                    .font(.system(size: 24, weight: .medium)).monospacedDigit().foregroundStyle(pressureColor)
                Text(pressure.title).font(.system(size: 11, weight: .medium)).foregroundStyle(pressureColor)
            }
            Text(pressure.summary).font(.system(size: 10)).foregroundStyle(MonitorStyle.muted)
                .fixedSize(horizontal: false, vertical: true)
        }.help("估算值 = 压缩内存 ÷（物理内存 − 连线内存）；不是活动监视器的压力曲线数值。旁边的压力等级由系统直接报告。")
    }
    private var pressureColor: Color {
        switch pressure { case .normal: .green; case .warning: .yellow; case .critical: .red; case .unavailable: MonitorStyle.muted }
    }
}

// 各段与真实分类字节数成比例，不将缓存与应用重复累计。
struct MemoryBar: View {
    let memory: MemoryUsage?
    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                segment(memory?.application, color: MonitorStyle.purple, width: proxy.size.width)
                segment(memory?.wired, color: Color(red: 0.64, green: 0.43, blue: 0.96), width: proxy.size.width)
                segment(memory?.compressed, color: Color(white: 0.6), width: proxy.size.width)
                MonitorStyle.foreground.opacity(0.12)
            }
        }.clipShape(.rect(cornerRadius: 7))
    }

    // 使用实际物理总量作为所有分段的共同分母。
    private func segment(_ value: UInt64?, color: Color, width: CGFloat) -> some View {
        color.frame(width: width * min(1, Double(value ?? 0) / Double(max(1, memory?.total ?? 1))))
    }
}

// 显示一个真实内存分类及容量。
struct MemoryDetail: View {
    let title: String
    let value: UInt64?
    let color: Color
    var unit = MemoryUnit.decimal
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Legend(label: title, color: color)
            Text(value.map { MonitorFormat.bytes($0, unit: unit) } ?? "—").font(.system(size: 10)).monospacedDigit().padding(.leading, 12)
        }
    }
}
