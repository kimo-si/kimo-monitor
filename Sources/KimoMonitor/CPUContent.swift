import SwiftUI

// 展示 CPU 占用、历史趋势和应用排行。
struct CPUContent: View {
    let store: MonitorStore
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MetricValue(title: "总 CPU 占用", metric: FormattedMetric(number: MonitorFormat.percent(store.snapshot.cpu), unit: ""), color: MonitorStyle.foreground, size: 29)
                .padding(.bottom, 12)
            if store.preferences.value.showCharts {
                HistoryChart(points: store.snapshot.cpuHistory, color: MonitorStyle.orange, isCPU: true, historySeconds: store.preferences.value.historySeconds, interval: store.preferences.value.interval)
            }
            PanelDivider().padding(.top, 12).padding(.bottom, 11)
            if store.preferences.value.showApplications { ApplicationList(store: store, mode: .cpu, applications: store.snapshot.topCPU) }
            Text("CPU 占比以全部逻辑核心为 100%")
                .font(.system(size: 9)).foregroundStyle(MonitorStyle.muted).padding(.top, 7)
        }
    }

}
