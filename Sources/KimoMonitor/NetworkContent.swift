import SwiftUI

// 以参考图的结构显示速率、曲线、流量和应用列表。
struct NetworkContent: View {
    let store: MonitorStore
    private var snapshot: MonitorSnapshot { store.snapshot }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                MetricValue(title: "实时下载", metric: MonitorFormat.metric(snapshot.download, rate: true, rateUnit: store.preferences.value.rateUnit), color: MonitorStyle.cyan, symbol: "arrow.down", numberColor: MonitorStyle.foreground)
                Spacer(minLength: 4)
                Rectangle().fill(MonitorStyle.line).frame(width: 1, height: 37)
                Spacer(minLength: 9)
                MetricValue(title: "实时上传", metric: MonitorFormat.metric(snapshot.upload, rate: true, rateUnit: store.preferences.value.rateUnit), color: MonitorStyle.purple, symbol: "arrow.up", numberColor: MonitorStyle.foreground)
            }.padding(.bottom, 12)
            if store.preferences.value.showCharts {
                HistoryChart(points: snapshot.networkHistory, color: MonitorStyle.cyan, isCPU: false, historySeconds: store.preferences.value.historySeconds, interval: store.preferences.value.interval, rateUnit: store.preferences.value.rateUnit)
            }
            if store.preferences.value.showCharts {
                HStack(spacing: 16) {
                    Legend(label: "下载", color: MonitorStyle.cyan)
                    Legend(label: "上传", color: MonitorStyle.purple)
                    Spacer()
                }.padding(.top, 8).padding(.bottom, 10)
            }
            traffic
            PanelDivider().padding(.top, 9).padding(.bottom, 10)
            if store.preferences.value.showApplications {
                ApplicationList(store: store, mode: .network, applications: snapshot.topMemory)
                    .help("网络速率尚未接入可靠数据源；应用按内存排序，横线表示没有数据。")
            }

        }
    }
    private var traffic: some View {
        HStack(spacing: 4) {
            Text("本次流量").foregroundStyle(MonitorStyle.muted)
            Text(MonitorFormat.bytes(snapshot.received + snapshot.sent, unit: store.preferences.value.memoryUnit)).fontWeight(.semibold)
            Spacer(minLength: 4)
            Text("↓").foregroundStyle(MonitorStyle.cyan)
            Text(MonitorFormat.bytes(snapshot.received, unit: store.preferences.value.memoryUnit))
            Text("↑").foregroundStyle(MonitorStyle.purple)
            Text(MonitorFormat.bytes(snapshot.sent, unit: store.preferences.value.memoryUnit))
        }
        .font(.system(size: 10)).monospacedDigit().padding(.horizontal, 8).frame(height: 32)
        .background(MonitorStyle.foreground.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(MonitorStyle.foreground.opacity(0.09)))
        .help("仅包含本次运行观测到的计数增量；不补算应用未运行、接口切换和采样失败期间的流量。")
    }
}
