import SwiftUI

// 显示真实应用图标、聚合资源和可访问进程数量。
struct ApplicationList: View {
    let store: MonitorStore
    let mode: MonitorKind
    let applications: [ApplicationUsage]
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(mode == .network ? "应用网速 · 未接入" : "应用占用").font(.system(size: 12, weight: .medium)).foregroundStyle(MonitorStyle.foreground)
                Spacer()
                Text(mode == .network ? "下载速度" : mode == .memory ? "内存占用" : "CPU 占用").frame(width: valueWidth, alignment: .trailing)
                Text(mode == .network ? "上传速度" : mode == .memory ? "占比" : "进程").frame(width: trailingWidth, alignment: .trailing)
                Color.clear.frame(width: 9)
            }.font(.system(size: 10)).foregroundStyle(MonitorStyle.muted).padding(.bottom, 8)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(applications) { app in
                        ApplicationRow(app: app, icon: store.icon(for: app.path), mode: mode, totalMemory: store.snapshot.memory?.total, unit: store.preferences.value.memoryUnit)
                    }
                }
            }.frame(height: 150)
            if applications.isEmpty {
                Text("等待有效采样…").font(.system(size: 13)).foregroundStyle(MonitorStyle.muted).frame(height: 160)
            }
        }
    }
    private var valueWidth: CGFloat { mode == .network ? 55 : 57 }
    private var trailingWidth: CGFloat { mode == .network ? 55 : 39 }
}

// 每个应用行可以展开查看组成进程，而非装饰性的箭头。
struct ApplicationRow: View {
    let app: ApplicationUsage
    let icon: NSImage?
    let mode: MonitorKind
    let totalMemory: UInt64?
    var unit = MemoryUnit.decimal
    @State private var showingProcesses = false
    var body: some View {
        VStack(spacing: 0) {
            PanelDivider()
            Button { showingProcesses = true } label: { row }
                .buttonStyle(.plain).frame(height: 30)
                .popover(isPresented: $showingProcesses) { details }
                .accessibilityLabel(app.name + "，" + value + "，查看进程")
        }
    }
    private var row: some View {
        HStack(spacing: 6) {
            Group {
                if let icon { Image(nsImage: icon).resizable().interpolation(.high) }
                else { Image(systemName: "app.dashed").resizable().foregroundStyle(MonitorStyle.muted) }
            }.frame(width: 22, height: 22).accessibilityHidden(true)
            Text(app.name).font(.system(size: 11)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Text(value).frame(width: mode == .network ? 55 : 57, alignment: .trailing)
            Text(trailing).frame(width: mode == .network ? 55 : 39, alignment: .trailing)
            Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(MonitorStyle.muted).frame(width: 7)
        }.font(.system(size: 10)).monospacedDigit()
    }
    private var value: String {
        switch mode { case .network: "—"; case .memory: MonitorFormat.bytes(app.memory, unit: unit); case .cpu: MonitorFormat.percent(app.cpu, digits: 1) }
    }
    private var trailing: String {
        switch mode {
        case .network: "—"
        case .memory: MonitorFormat.percent(totalMemory.map { Double(app.memory) / Double(max(1, $0)) }, digits: 1)
        case .cpu: app.processes.count.formatted()
        }
    }
    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(app.name).font(.headline)
            Text("可访问进程的物理占用合计；CPU 按全部逻辑核心归一化。")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(app.processes) { process in
                        HStack {
                            Text("\(process.name) (\(process.id))").lineLimit(1)
                            Spacer()
                            Text(MonitorFormat.bytes(process.memory, unit: unit))
                            Text(MonitorFormat.percent(process.cpu, digits: 1)).frame(width: 50, alignment: .trailing)
                        }.font(.caption).monospacedDigit()
                    }
                }
            }.frame(maxHeight: 260)
        }.padding(18).frame(width: 430)
    }
}
