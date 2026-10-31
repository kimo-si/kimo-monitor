import Foundation

// 保存内核直接读取的单进程资源，不通过进程名称推测所属应用。
struct ProcessUsage: Identifiable, Equatable, Sendable {
    let id: Int32
    let name: String
    let applicationPath: String?
    let memory: UInt64
    let cpu: Double?
}

// 保存同一应用包下所有可访问进程的合计。
struct ApplicationUsage: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let path: String?
    let processes: [ProcessUsage]
    var memory: UInt64 { processes.reduce(0) { $0 + $1.memory } }
    var cpu: Double? {
        guard processes.allSatisfy({ $0.cpu != nil }) else { return nil }
        return processes.reduce(0) { $0 + ($1.cpu ?? 0) }
    }
}

// 保存互不重叠的内存分类；缓存另列，不叠加到已使用。
struct MemoryUsage: Equatable, Sendable {
    let total: UInt64
    let application: UInt64
    let wired: UInt64
    let compressed: UInt64
    let cached: UInt64
    var used: UInt64 { application + wired + compressed }
    var available: UInt64 { total > used ? total - used : 0 }
    var fraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

// 系统压力等级独立于连续估算值，不将枚举值换算成百分比。
enum MemoryPressure: Equatable, Sendable {
    case normal, warning, critical, unavailable
    var title: String {
        switch self { case .normal: "正常"; case .warning: "偏高"; case .critical: "紧张"; case .unavailable: "不可用" }
    }
    var summary: String {
        switch self {
        case .normal: "内存能够满足当前应用需求"
        case .warning: "内存资源偏紧，留意压力是否持续升高"
        case .critical: "内存资源紧张，建议关闭不需要的应用"
        case .unavailable: "暂时无法读取压力状态"
        }
    }
}

// 以非连线内存中的压缩占比估算压力；此指标不等同于活动监视器的压力曲线。
struct MemoryPressureEstimate: Equatable, Sendable {
    let fraction: Double

    // 以物理内存减连线内存近似可调度池，拒绝零分母或超出池容量的异常读数。
    init?(memory: MemoryUsage) {
        guard memory.total > memory.wired else { return nil }
        let availablePool = memory.total - memory.wired
        guard memory.compressed <= availablePool else { return nil }
        fraction = Double(memory.compressed) / Double(availablePool)
    }
}

// 内核报告的可用内存百分比，与 memory_pressure -Q 的数值口径相同。
struct MemoryHeadroom: Equatable, Sendable {
    let availablePercent: Int32
    var fraction: Double { Double(availablePercent) / 100 }

    // 未知或越界的读数不进入界面，避免伪造有效百分比。
    init?(availablePercent: Int32) {
        guard (0...100).contains(availablePercent) else { return nil }
        self.availablePercent = availablePercent
    }
}

// 保存有真实时间戳的图表点，采样失败时以 nil 留出缺口。
struct HistoryPoint: Equatable, Sendable {
    let time: TimeInterval
    let primary: Double?
    let secondary: Double?
}

// 保存供界面原子更新的监控快照及预排序应用列表。
struct MonitorSnapshot: Equatable, Sendable {
    var sampledAt = Date.now
    var download: Double?
    var upload: Double?
    var received: UInt64 = 0
    var sent: UInt64 = 0
    var interfaces: [String] = []
    var cpu: Double?
    var memory: MemoryUsage?
    var pressure: MemoryPressure = .unavailable
    var memoryHeadroom: MemoryHeadroom?
    var memoryPressureEstimate: MemoryPressureEstimate? { memory.flatMap { MemoryPressureEstimate(memory: $0) } }
    var topMemory: [ApplicationUsage] = []
    var topCPU: [ApplicationUsage] = []
    var networkHistory: [HistoryPoint] = []
    var cpuHistory: [HistoryPoint] = []
    var samplingMilliseconds: Double = 0
}

// 集中管理采样周期、图表窗口与展示数量。
enum MonitorConfiguration {
    static let interval: Double = 2
    static let historyGapMultiplier: Double = 2.5
    static let historySeconds: Double = 60
    static let processLimit = 5
    static let metadataLifetime: Double = 30
}

// 用持久化值统一描述采样、显示与提醒选项。
struct MonitorPreferences: Codable, Equatable, Sendable {
    var openOverview = false
    var showCPU = true
    var showMemory = true
    var showNetwork = true
    var memoryDisplay = MemoryDisplay.pressure
    var networkDisplay = NetworkDisplay.both
    var interval = 2.0
    var historySeconds = 60.0
    var processLimit = 5
    var networkInterface = ""
    var rateUnit = RateUnit.bytes
    var memoryUnit = MemoryUnit.decimal
    var theme = PanelTheme.dark
    var showCharts = true
    var showApplications = true
    var cpuAlerts = false
    var memoryAlerts = false
    var cpuThreshold = 80.0
    var cpuDuration = 30.0
    var alertCooldown = 300.0
}

// 内存菜单栏可选择估算压力、占用率或实际已用容量。
enum MemoryDisplay: String, Codable, CaseIterable, Identifiable, Sendable {
    case pressure, usage, used
    var id: Self { self }
    var title: String { switch self { case .pressure: "压力估算"; case .usage: "内存占用率"; case .used: "已用内存" } }
}

// 网络菜单栏可以展示双向或单向速率。
enum NetworkDisplay: String, Codable, CaseIterable, Identifiable, Sendable {
    case both, download, upload
    var id: Self { self }
    var title: String { switch self { case .both: "上传与下载"; case .download: "仅下载"; case .upload: "仅上传" } }
}

// 速率以字节或比特显示，采样仍使用字节。
enum RateUnit: String, Codable, CaseIterable, Identifiable, Sendable {
    case bytes, bits
    var id: Self { self }
    var title: String { self == .bytes ? "字节 / 秒" : "比特 / 秒" }
}

// 容量支持十进制和二进制单位。
enum MemoryUnit: String, Codable, CaseIterable, Identifiable, Sendable {
    case decimal, binary
    var id: Self { self }
    var title: String { self == .decimal ? "GB / MB（十进制）" : "GiB / MiB（二进制）" }
}

// 面板支持深色、浅色和跟随系统。
enum PanelTheme: String, Codable, CaseIterable, Identifiable, Sendable {
    case dark, light, system
    var id: Self { self }
    var title: String { switch self { case .dark: "深色"; case .light: "浅色"; case .system: "跟随系统" } }
}
