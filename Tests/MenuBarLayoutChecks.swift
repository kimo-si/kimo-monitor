import SwiftUI

// 实际测量 SwiftUI 菜单标签布局，验证单位和数字变化时宽度不变。
@main
struct MenuBarLayoutChecks {
    // 逐个构建标签进行离屏测量，不创建窗口或菜单项。
    @MainActor static func main() {
        _ = NSApplication.shared
        let rates: [Double?] = [nil, 0, 8_000, 512_000, 12_400_000, 999_900_000_000]
        let sizes = rates.map { value in
            var snapshot = MonitorSnapshot()
            snapshot.upload = value
            snapshot.download = value
            let host = NSHostingView(rootView: MenuLabel(kind: .network, snapshot: snapshot))
            return host.fittingSize
        }
        precondition(sizes.allSatisfy { $0.width == MenuBarLayout.networkWidth && $0.height == MenuBarLayout.height })
        checkRenderedRows()
        checkReferenceTypography()
        // 验证估算百分比会刷新菜单图像，占用变化不会被误当成压力变化。
        checkMemoryPressureLabel()
        checkMemoryPressureCache()
        // 比较生产位图中的单位列，验证不同位数和小数不会移动或缩放单位。
        checkFixedRateUnits()
        // 输出生产绘图与 SwiftUI 设置预览的对照，供真实字号视觉核验。
        saveRendererComparison()
        precondition(MonitorFormat.menuRate(8_000) == "8 KB/s")
        precondition(MonitorFormat.menuRate(512_000) == "512 KB/s")
        print("PASS: 菜单栏网速从空值、B/s、KB/s 到 GB/s 均固定为 \(MenuBarLayout.networkWidth) × \(MenuBarLayout.height) pt")
    }

    // 检查最终交给系统的图像上下两半都有文字像素，并验证不变读数复用缓存。
    @MainActor private static func checkRenderedRows() {
        let renderer = MenuBarLabelRenderer()
        var snapshot = MonitorSnapshot()
        snapshot.cpu = 1
        snapshot.upload = 8_000
        snapshot.download = 512_000
        for kind in [MonitorKind.network, .memory, .cpu] {
            let image = renderer.image(for: kind, snapshot: snapshot)
            precondition(image === renderer.image(for: kind, snapshot: snapshot))
            guard let data = image.tiffRepresentation, let pixels = NSBitmapImageRep(data: data) else {
                preconditionFailure("无法读取最终双行位图")
            }
            let middle = pixels.pixelsHigh / 2
            precondition(hasInk(pixels, rows: 0..<middle))
            precondition(hasInk(pixels, rows: middle..<pixels.pixelsHigh))
            let expectedWidth = kind == .network ? MenuBarLayout.networkWidth : MenuBarLayout.metricWidth
            precondition(image.size == NSSize(width: expectedWidth, height: MenuBarLabelRenderer.imageHeight))
            precondition(pixels.pixelsWide == Int(expectedWidth * 2) && pixels.pixelsHigh == Int(MenuBarLayout.height * 2), "不得通过改写图像尺寸压扁字体")
        }
        print("PASS: 最终菜单图像上、下两行均有真实文字像素，相同读数复用缓存，Retina 字形宽高比无拉伸")
    }

    // 验证参考图的标准宽粗体和等宽数字，防止恢复窄体或读数切换时文字宽度跳变。
    @MainActor private static func checkReferenceTypography() {
        let widths = ["25%", "51%"].map { value in
            NSHostingView(rootView: Text(value).font(MenuBarTypography.value).monospacedDigit()).fittingSize.width
        }
        precondition(widths[0] == widths[1])
        let condensed = NSHostingView(rootView: Text("25%")
            .font(.system(size: 11, weight: .regular).width(.condensed))).fittingSize.width
        precondition(widths[0] > condensed, "参考图需要标准宽度粗体，不能恢复窄体")
        print("PASS: 参考图标准宽度粗体，25% 与 51% 等宽，均为 \(widths[0]) pt")
    }

    // 覆盖未知、一位、两位与三位百分比，确保数值改变时图像会刷新且宽度固定。
    @MainActor private static func checkMemoryPressureLabel() {
        let renderer = MenuBarLabelRenderer()
        let readings: [(UInt64?, String)] = [(nil, "—"), (0, "0%"), (8, "8%"), (51, "51%"), (100, "100%")]
        var images: [Data] = []
        for (compressed, expected) in readings {
            var snapshot = MonitorSnapshot()
            snapshot.memory = compressed.map { MemoryUsage(total: 120, application: 0, wired: 20, compressed: $0, cached: 0) }
            let image = renderer.image(for: .memory, snapshot: snapshot)
            precondition(image.size == NSSize(width: MenuBarLayout.metricWidth, height: MenuBarLayout.height))
            precondition(renderer.accessibilityText(for: .memory, snapshot: snapshot).hasPrefix("内存压力估算 " + expected))
            guard let data = image.tiffRepresentation else { preconditionFailure("无法读取内存压力位图") }
            images.append(data)
        }
        precondition(Set(images).count == readings.count, "压力估算变化必须刷新菜单图像")
        print("PASS: 内存菜单显示 —、0%、8%、51%、100%，百分比更新且菜单尺寸固定")
    }

    // 应用内存和余量改变时，只要压力估算不变就复用菜单图像。
    @MainActor private static func checkMemoryPressureCache() {
        let renderer = MenuBarLabelRenderer()
        var snapshot = MonitorSnapshot()
        snapshot.pressure = .normal
        snapshot.memory = MemoryUsage(total: 120, application: 0, wired: 20, compressed: 40, cached: 0)
        let image = renderer.image(for: .memory, snapshot: snapshot)
        snapshot.memory = MemoryUsage(total: 120, application: 40, wired: 20, compressed: 40, cached: 0)
        snapshot.memoryHeadroom = MemoryHeadroom(availablePercent: 30)
        precondition(image === renderer.image(for: .memory, snapshot: snapshot), "占用或余量不应被当成压力估算")
        print("PASS: 压力估算不变时复用菜单缓存，独立于占用率和余量")
    }

    // 同单位下遍历一位、两位、三位与较长数字，要求两行单位的像素完全一致。
    @MainActor private static func checkFixedRateUnits() {
        let rates: [[Double]] = [
            [0, 8, 49, 512, 999],
            [8_000, 49_000, 512_000, 999_000],
            [1_000_000, 12_400_000, 124_000_000, 999_000_000],
            [1_000_000_000, 12_400_000_000, 124_000_000_000, 999_900_000_000]
        ]
        for group in rates {
            let samples = group.map { unitPixels(in: networkPixels(rate: $0)) }
            precondition(samples[0].contains { $0 > 0.1 }, "单位必须完整可见")
            precondition(samples.allSatisfy { $0 == samples[0] }, "数字变化导致单位位移或缩放")
        }
        let unitWidth = NSHostingView(rootView: Text("MB/s").font(MenuBarTypography.rate)).fittingSize.width
        precondition(unitWidth <= MenuBarLayout.rateUnitWidth, "最宽单位不能被裁切或缩小")
        print("PASS: B/s、KB/s、MB/s、GB/s 各组读数位数变化时，两行单位区域像素完全一致")
    }

    // 从真实菜单渲染器获取包含两行速率的最终像素。
    @MainActor private static func networkPixels(rate: Double) -> NSBitmapImageRep {
        var snapshot = MonitorSnapshot()
        snapshot.upload = rate
        snapshot.download = rate
        let image = MenuBarLabelRenderer().image(for: .network, snapshot: snapshot)
        guard let data = image.tiffRepresentation, let pixels = NSBitmapImageRep(data: data) else {
            preconditionFailure("无法读取网速双行位图")
        }
        return pixels
    }

    // 逐像素提取固定单位列，覆盖上下两行并保留抗锯齿透明度。
    @MainActor private static func unitPixels(in image: NSBitmapImageRep) -> [CGFloat] {
        let origin = MenuBarLayout.arrowWidth + MenuBarLayout.columnSpacing
            + MenuBarLayout.rateNumberWidth + MenuBarLayout.rateUnitSpacing
        let scale = CGFloat(image.pixelsWide) / MenuBarLayout.networkWidth
        let columns = Int(origin * scale)..<Int((origin + MenuBarLayout.rateUnitWidth) * scale)
        return (0..<image.pixelsHigh).flatMap { y in
            columns.map { x in image.colorAt(x: x, y: y)?.alphaComponent ?? 0 }
        }
    }

    // 通过透明度检测文字区域，不依赖字体抗锯齿的具体像素颜色。
    @MainActor private static func hasInk(_ image: NSBitmapImageRep, rows: Range<Int>) -> Bool {
        for y in rows {
            for x in 0..<image.pixelsWide where (image.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 { return true }
        }
        return false
    }

    // 上排为 SwiftUI 参考，下排为原生生产位图，按原始 Retina 像素并排保存。
    @MainActor private static func saveRendererComparison() {
        var snapshot = MonitorSnapshot()
        snapshot.cpu = 0.25
        snapshot.upload = 8_000
        snapshot.download = 512_000
        snapshot.memory = MemoryUsage(total: 120, application: 0, wired: 20, compressed: 51, cached: 0)
        let canvas = NSImage(size: NSSize(width: 150, height: 60))
        canvas.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 150, height: 60).fill()
        var x: CGFloat = 5
        for kind in [MonitorKind.network, .memory, .cpu] {
            let renderer = ImageRenderer(content: MenuLabel(kind: kind, snapshot: snapshot).colorMultiply(.black))
            renderer.scale = 2
            let native = MenuBarLabelRenderer().image(for: kind, snapshot: snapshot)
            renderer.nsImage?.draw(at: NSPoint(x: x, y: 33), from: .zero, operation: .sourceOver, fraction: 1)
            native.draw(at: NSPoint(x: x, y: 3), from: .zero, operation: .sourceOver, fraction: 1)
            x += native.size.width + 10
        }
        canvas.unlockFocus()
        guard let tiff = canvas.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:]) else { preconditionFailure("绘图对照导出失败") }
        try! data.write(to: URL(fileURLWithPath: "artifacts/menu-renderer-comparison.png"))
    }

}
