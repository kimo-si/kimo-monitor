import SwiftUI

// 绘制带坐标、网格、面积填充和真实时间轴的轻量图表。
struct HistoryChart: View {
    let points: [HistoryPoint]
    let color: Color
    let isCPU: Bool
    var historySeconds = MonitorConfiguration.historySeconds
    var interval = MonitorConfiguration.interval
    var rateUnit = RateUnit.bytes
    private var maximum: Double {
        guard !isCPU else { return 1 }
        let peak = points.reduce(0.0) { max($0, $1.primary ?? 0, $1.secondary ?? 0) }
        guard peak > 0 else { return 1_000 }
        let magnitude = pow(10, floor(log10(peak)))
        return ceil(peak / magnitude) * magnitude
    }
    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            VStack(alignment: .trailing) {
                Text(axisLabel(maximum))
                Spacer()
                Text(axisLabel(maximum / 2))
                Spacer()
                Text(isCPU ? "0%" : "0")
            }.font(.system(size: 9)).lineLimit(1).minimumScaleFactor(0.65).foregroundStyle(MonitorStyle.muted).frame(width: isCPU ? 25 : 35, height: 64)
            VStack(spacing: 7) {
                plot.frame(height: 64)
                HStack { Text(timeLabel(historySeconds)); Spacer(); Text(timeLabel(historySeconds / 2)); Spacer(); Text("现在") }
                    .font(.system(size: 9)).foregroundStyle(MonitorStyle.muted)
            }
        }.accessibilityLabel("最近\(Int(historySeconds / 60))分钟变化趋势，最大刻度 " + axisLabel(maximum))
    }
    private var plot: some View {
        Canvas { context, size in
            drawGrid(context: &context, size: size)
            draw(secondary: false, context: &context, size: size)
            if !isCPU { draw(secondary: true, context: &context, size: size) }
        }.background(.black.opacity(0.06))
    }

    // 将时间轴刻度转换为易读的分钟或秒数。
    private func timeLabel(_ seconds: Double) -> String {
        seconds >= 60 ? "\(Int(seconds / 60))分钟前" : "\(Int(seconds))秒前"
    }

    // 使用同一数值格式，防止坐标单位与指标单位不同。
    private func axisLabel(_ value: Double) -> String {
        isCPU ? MonitorFormat.percent(value) : MonitorFormat.rate(value, unit: rateUnit)
    }

    // 固定时间网格不触发独立的动画或额外定时器。
    private func drawGrid(context: inout GraphicsContext, size: CGSize) {
        var grid = Path()
        for index in 0...8 {
            let x = size.width * Double(index) / 8
            grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height))
        }
        for index in 0...2 {
            let y = size.height * Double(index) / 2
            grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y))
        }
        context.stroke(grid, with: .color(MonitorStyle.foreground.opacity(0.10)), lineWidth: 0.7)
    }

    // 对缺失值和过长间隔切断曲线，避免把离线时间绘制为连续数据。
    private func draw(secondary: Bool, context: inout GraphicsContext, size: CGSize) {
        guard let end = points.last?.time else { return }
        let tint = secondary ? MonitorStyle.purple : color
        var segment: [CGPoint] = []
        var previousTime: TimeInterval?
        for point in points {
            let value = secondary ? point.secondary : point.primary
            if value == nil || previousTime.map({ point.time - $0 > interval * MonitorConfiguration.historyGapMultiplier }) == true {
                paint(segment, color: tint, context: &context, height: size.height)
                segment = []
            }
            if let value {
                let x = size.width * (1 - (end - point.time) / historySeconds)
                segment.append(CGPoint(x: max(0, x), y: size.height * (1 - min(1, max(0, value / maximum)))))
            }
            previousTime = point.time
        }
        paint(segment, color: tint, context: &context, height: size.height)
    }

    // 使用线性真实采样点和渐变填充，避免曲线插值制造不存在的峰值。
    private func paint(_ points: [CGPoint], color: Color, context: inout GraphicsContext, height: CGFloat) {
        guard let first = points.first, let last = points.last, points.count > 1 else { return }
        var path = Path()
        path.addLines(points)
        var area = path
        area.addLine(to: CGPoint(x: last.x, y: height))
        area.addLine(to: CGPoint(x: first.x, y: height)); area.closeSubpath()
        context.fill(area, with: .linearGradient(Gradient(colors: [color.opacity(0.42), color.opacity(0.04)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: height)))
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
    }
}
