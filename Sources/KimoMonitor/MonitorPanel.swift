import SwiftUI

// 集中定义从参考图等比例缩放的尺寸和配色。
enum MonitorStyle {
    static let cyan = Color(red: 0.02, green: 0.83, blue: 0.95)
    static let purple = Color(red: 0.61, green: 0.28, blue: 1)
    static let orange = Color(red: 1, green: 0.57, blue: 0.19)
    static let muted = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.68, alpha: 1) : NSColor(white: 0.38, alpha: 1)
    })
    static let foreground = Color(nsColor: .labelColor)
    static let panelBackground = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(calibratedRed: 0.105, green: 0.125, blue: 0.15, alpha: 0.88) : NSColor(calibratedWhite: 0.96, alpha: 0.94)
    })
    static let line = foreground.opacity(0.12)
}

// 为三个菜单入口提供稳定的尺寸、图标与主题色。
enum MonitorKind: String, CaseIterable {
    case network, memory, cpu
    var title: String { switch self { case .network: "网速"; case .memory: "内存"; case .cpu: "CPU" } }
    var icon: String { switch self { case .network: "wifi"; case .memory: "memorychip"; case .cpu: "cpu" } }
    var color: Color { switch self { case .network: MonitorStyle.cyan; case .memory: MonitorStyle.purple; case .cpu: MonitorStyle.orange } }
    var width: CGFloat { switch self { case .network: 310; case .memory: 310; case .cpu: 310 } }
    var height: CGFloat { switch self { case .network: 474; case .memory: 454; case .cpu: 442 } }
}

// 按参考图使用标准宽度的系统粗体，分别控制标题、百分比和网速的视觉层级。
enum MenuBarTypography {
    static let caption = Font.system(size: 8, weight: .bold, design: .default)
    static let value = Font.system(size: 11, weight: .bold, design: .default)
    static let rate = Font.system(size: 9.25, weight: .bold, design: .default)
    static let arrow = Font.system(size: 7.5, weight: .bold, design: .default)
}

// 固定每个状态项的宽度，读数更新只改变文字，不重新分配菜单栏空间。
struct MenuLabel: View {
    let kind: MonitorKind
    let snapshot: MonitorSnapshot
    var preferences = MonitorPreferences()
    var body: some View {
        Group {
            if kind == .network {
                VStack(alignment: .leading, spacing: 0) {
                    if preferences.networkDisplay != .download { networkRow(symbol: "arrow.up", value: snapshot.upload) }
                    if preferences.networkDisplay != .upload { networkRow(symbol: "arrow.down", value: snapshot.download) }
                }.frame(width: MenuBarLayout.networkWidth, height: MenuBarLayout.height)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    Text(kind == .cpu ? "CPU" : "MEM")
                        .font(MenuBarTypography.caption)
                        .frame(height: MenuBarLayout.captionHeight, alignment: .leading)
                    Text(menuValue)
                        .font(MenuBarTypography.value).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(MenuBarLayout.metricMinimumScale).fixedSize(horizontal: false, vertical: true)
                        .frame(width: metricWidth, height: MenuBarLayout.valueHeight, alignment: .leading)
                }.frame(width: metricWidth, height: MenuBarLayout.height, alignment: .leading)
            }
        }
        .foregroundStyle(.white)
        .accessibilityElement(children: .combine)
    }

    // 容量读数需要额外空间，百分比仍保持原有紧凑宽度。
    private var metricWidth: CGFloat {
        kind == .memory && preferences.memoryDisplay == .used ? MenuBarLayout.memoryCapacityWidth : MenuBarLayout.metricWidth
    }

    // 依据用户选择生成内存或 CPU 菜单读数。
    private var menuValue: String {
        guard kind == .memory else { return MonitorFormat.percent(snapshot.cpu) }
        switch preferences.memoryDisplay {
        case .pressure: return MonitorFormat.percent(snapshot.memoryPressureEstimate?.fraction)
        case .usage: return MonitorFormat.percent(snapshot.memory?.fraction)
        case .used: return snapshot.memory.map { MonitorFormat.bytes($0.used, unit: preferences.memoryUnit) } ?? "—"
        }
    }

    // 箭头和速率分别占固定列，数字变化不挤压单位或另一行。
    private func networkRow(symbol: String, value: Double?) -> some View {
        HStack(spacing: MenuBarLayout.columnSpacing) {
            Image(systemName: symbol).font(MenuBarTypography.arrow)
                .symbolRenderingMode(.monochrome)
                .offset(y: MenuBarLayout.arrowBaselineOffset)
                .frame(width: MenuBarLayout.arrowWidth).accessibilityHidden(true)
            // 使用结构化读数固定单位位置，只让数字在自己的列内变化。
            networkRate(MonitorFormat.menuRateMetric(value, unit: preferences.rateUnit))
        }.frame(width: MenuBarLayout.networkWidth, height: MenuBarLayout.height / 2, alignment: .leading)
    }

    // 数字向左扩展，单位固定左对齐；超长数字仅在数字列内缩放。
    private func networkRate(_ metric: FormattedMetric) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: MenuBarLayout.rateUnitSpacing) {
            Text(metric.number).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.65).fixedSize(horizontal: false, vertical: true)
                .frame(width: MenuBarLayout.rateNumberWidth, alignment: .trailing)
            Text(metric.unit).fixedSize()
                .frame(width: MenuBarLayout.rateUnitWidth, alignment: .leading)
        }
        .font(MenuBarTypography.rate)
        .offset(y: MenuBarLayout.rateBaselineOffset)
        .frame(width: MenuBarLayout.rateWidth, alignment: .leading)
    }
}

// 参考图按 Retina 2× 换算：两行网速相距 11 pt，指标起点间距由内容宽度与系统外边距共同组成。
enum MenuBarLayout {
    static let metricWidth: CGFloat = 26
    static let memoryCapacityWidth: CGFloat = 56
    static let metricMinimumScale: CGFloat = 0.7
    static let arrowWidth: CGFloat = 8
    static let arrowBaselineOffset: CGFloat = 0.5
    static let columnSpacing: CGFloat = 1.5
    static let rateNumberWidth: CGFloat = 21
    static let rateUnitSpacing: CGFloat = 2.5
    static let rateUnitWidth: CGFloat = 24
    static let rateWidth: CGFloat = rateNumberWidth + rateUnitSpacing + rateUnitWidth
    static let rateBaselineOffset: CGFloat = -0.5
    static let networkTrailingPadding: CGFloat = 0
    static let networkWidth: CGFloat = arrowWidth + columnSpacing + rateWidth + networkTrailingPadding
    static let statusItemHorizontalPadding: CGFloat = 0
    static let captionHeight: CGFloat = 10
    static let valueHeight: CGFloat = 12
    static let height: CGFloat = captionHeight + valueHeight

    // 仅分配标签原始宽度与紧凑内边距，不通过缩小字体来改变指标间距。
    static func statusItemWidth(for kind: MonitorKind) -> CGFloat {
        let contentWidth = kind == .network ? networkWidth : metricWidth
        return contentWidth + statusItemHorizontalPadding * 2
    }

}

// 复用同一块玻璃面板，保持三个菜单的一致边框和间距。
struct MonitorPanel: View {
    let kind: MonitorKind
    let store: MonitorStore
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.fixedSize(horizontal: false, vertical: true)
            PanelDivider().padding(.bottom, 11)
            switch kind {
            case .network: NetworkContent(store: store)
            case .memory: MemoryContent(store: store)
            case .cpu: CPUContent(store: store)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 12)
        .frame(width: kind.width, height: kind.height, alignment: .topLeading)
        .background(.ultraThinMaterial)
        .background(MonitorStyle.panelBackground)
        .clipShape(.rect(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(MonitorStyle.foreground.opacity(0.18), lineWidth: 1))
        .preferredColorScheme(store.preferences.value.theme == .system ? nil : (store.preferences.value.theme == .dark ? .dark : .light))
    }
    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: kind.icon).font(.system(size: 20, weight: .regular)).foregroundStyle(kind.color)
            Text(kind.title).font(.system(size: 16, weight: .medium))
            Spacer()
            Menu("设置", systemImage: "gearshape") {
                Text("每 \(Int(store.preferences.value.interval)) 秒采样 · 数据仅保留在本机")
                Button("打开设置…") { SettingsWindow.show(store: store) }
                Button("打开实时对照总览") { PreviewWindow.show(store: store) }
                Button("查看统计口径") { showDefinitions() }
                Divider()
                Button("退出 Kimo Monitor", role: .destructive) { NSApplication.shared.terminate(nil) }
            }.menuStyle(.borderlessButton).menuIndicator(.hidden)
                .labelStyle(.iconOnly).font(.system(size: 14)).foregroundStyle(MonitorStyle.muted).frame(width: 20)
        }.frame(height: 28).padding(.bottom, 7)
    }

    // 设置中的统计口径直接展示当前实现范围。
    private func showDefinitions() {
        let alert = NSAlert()
        alert.messageText = "统计口径"
        alert.informativeText = "网速：活跃 en 接口的 64 位字节差分，包含链路开销。\n流量：本次运行实际观测到的累计增量，不代表完整今日流量。\n内存：匿名页减可清除页 + 连线 + 压缩。缓存另列。\n应用内存：同一应用包内可访问进程的物理占用合计。\nCPU：全部逻辑核心归一化；新进程等待第二次采样。\n内存压力估算：压缩内存 ÷（物理内存 − 连线内存）。菜单栏显示估算百分比，不能视为活动监视器的曲线数值。系统真实压力等级独立保留；占用率与系统余量作为辅助。\n应用网速：当前未接入可靠数据源。"
        alert.runModal()
    }
}

// 绘制统一的细分隔线。
struct PanelDivider: View {
    var body: some View { Rectangle().fill(MonitorStyle.line).frame(height: 1) }
}

// 将数值和单位独立排版，并对动态数字使用固定字宽。
struct MetricValue: View {
    let title: String
    let metric: FormattedMetric
    let color: Color
    var size: CGFloat = 24
    var symbol: String? = nil
    var numberColor: Color? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(color) }
                Text(title).font(.system(size: 11)).foregroundStyle(MonitorStyle.foreground.opacity(0.88))
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(metric.number).font(.system(size: size, weight: .medium)).foregroundStyle(numberColor ?? color)
                Text(metric.unit).font(.system(size: 11, weight: .medium))
            }.foregroundStyle(color).monospacedDigit()
        }
    }
}

// 用文字和色点共同说明图例，支持不依赖颜色识别。
struct Legend: View {
    let label: String
    let color: Color
    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 4).fill(color).frame(width: 7, height: 7)
            Text(label).font(.system(size: 10)).foregroundStyle(MonitorStyle.muted)
        }
    }
}
