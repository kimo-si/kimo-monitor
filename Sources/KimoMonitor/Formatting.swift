import Foundation

// 分开数字与单位，允许大数字和小单位采用参考图的排版。
struct FormattedMetric {
    let number: String
    let unit: String
    var text: String { unit.isEmpty ? number : number + " " + unit }
}

// 所有内存使用十进制 GB/MB；单位和换算保持一致。
enum MonitorFormat {
    // 根据实际字节数选择十进制单位。
    static func metric(_ value: Double?, rate: Bool = false, rateUnit: RateUnit = .bytes, memoryUnit: MemoryUnit = .decimal) -> FormattedMetric {
        guard let value, value.isFinite, value >= 0 else { return FormattedMetric(number: "—", unit: "") }
        let isBits = rate && rateUnit == .bits
        let units = rate ? (isBits ? ["b/s", "Kb/s", "Mb/s", "Gb/s"] : ["B/s", "KB/s", "MB/s", "GB/s"]) : (memoryUnit == .binary ? ["B", "KiB", "MiB", "GiB", "TiB"] : ["B", "KB", "MB", "GB", "TB"])
        let base = !rate && memoryUnit == .binary ? 1_024.0 : 1_000.0
        var number = isBits ? value * 8 : value
        var index = 0
        while number >= base && index < units.count - 1 { number /= base; index += 1 }
        let digits = number >= 100 || index == 0 ? 0 : 1
        return FormattedMetric(number: number.formatted(.number.precision(.fractionLength(digits))), unit: units[index])
    }

    // 显示实时字节速率。
    static func rate(_ value: Double?, unit: RateUnit = .bytes) -> String { metric(value, rate: true, rateUnit: unit).text }

    // 为菜单栏无障碍读数组合完整文字，与分列绘制复用同一份格式结果。
    static func menuRate(_ value: Double?, unit: RateUnit = .bytes) -> String {
        menuRateMetric(value, unit: unit).text
    }

    // 独立返回数字和单位，整数 KB/s 与较大单位的小数规则保持一致。
    static func menuRateMetric(_ value: Double?, unit: RateUnit = .bytes) -> FormattedMetric {
        let metric = metric(value, rate: true, rateUnit: unit)
        guard let raw = value, raw.isFinite, raw >= 0 else { return metric }
        let value = unit == .bits ? raw * 8 : raw
        guard value < 1_000_000 else { return metric }
        let divisor = value >= 1_000 ? 1_000.0 : 1.0
        let number = (value / divisor).formatted(.number.precision(.fractionLength(0)))
        return FormattedMetric(number: number, unit: metric.unit)
    }

    // 显示真实物理字节容量。
    static func bytes(_ value: UInt64, unit: MemoryUnit = .decimal) -> String { metric(Double(value), memoryUnit: unit).text }

    // 根据显示场景选择百分比精度。
    static func percent(_ value: Double?, digits: Int = 0) -> String {
        guard let value, value.isFinite else { return "—" }
        return (value * 100).formatted(.number.precision(.fractionLength(digits))) + "%"
    }
}
