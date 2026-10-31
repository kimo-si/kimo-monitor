import Foundation
import Darwin

// 将进程 CPU 累计时间与它自己的读取时刻绑定，避免扫描顺序引入时间误差。
private struct ProcessCounter {
    let cpuTime: UInt64
    let startTime: UInt64
    let observedAt: TimeInterval
}

// 缓存进程名称及应用包路径；启动时间用于识别 PID 复用。
private struct ProcessIdentity {
    let startTime: UInt64
    let executableID: UUID
    let name: String
    let applicationPath: String?
    let refreshedAt: TimeInterval
}

// 所有方法只在采样器的后台串行队列调用。
final class ProcessSampler {
    private var previous: [pid_t: ProcessCounter] = [:]
    private var identities: [pid_t: ProcessIdentity] = [:]
    private var names: [String: String] = [:]
    private let timebase = ProcessSampler.readTimebase()
    private var processorCount = 1.0

    // 枚举可访问进程，并按明确的应用包路径聚合。
    func sample() -> [ApplicationUsage] {
        processorCount = Double(max(1, ProcessInfo.processInfo.activeProcessorCount))
        let pids = processIDs()
        var counters: [pid_t: ProcessCounter] = [:]
        let processes = pids.compactMap { readProcess($0, next: &counters) }
        previous = counters
        identities = identities.filter { counters[$0.key] != nil }
        let groups = Dictionary(grouping: processes) { $0.applicationPath ?? "pid:\($0.id)" }
        let activePaths = Set(groups.values.compactMap { $0.first?.applicationPath })
        names = names.filter { activePaths.contains($0.key) }
        return groups.map { key, members in
            let path = members.first?.applicationPath
            return ApplicationUsage(id: key, name: applicationName(path, fallback: members.first?.name ?? "未知进程"),
                                    path: path, processes: members.sorted { $0.id < $1.id })
        }
    }

    // 唤醒后丢弃旧 CPU 基线，不把休眠时间计入进程速率。
    func resetBaseline() { previous = [:] }

    // 无可见排行榜时释放进程元信息，恢复采样时从新基线开始计算 CPU。
    func releaseCaches() {
        previous = [:]
        identities = [:]
        names = [:]
    }

    // 预留进程增长空间，限制读取数量不超过实际缓冲区。
    private func processIDs() -> [pid_t] {
        let capacity = Int(proc_listallpids(nil, 0)) + 256
        guard capacity > 256 else { return [] }
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }
        return pids.prefix(min(Int(count), capacity)).filter { $0 > 0 }
    }

    // 读取物理占用与 CPU 累计值，权限失败时跳过该进程。
    private func readProcess(_ pid: pid_t, next: inout [pid_t: ProcessCounter]) -> ProcessUsage? {
        var info = rusage_info_v2()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard status == 0, let identity = identity(pid, start: info.ri_proc_start_abstime, executableID: UUID(uuid: info.ri_uuid), now: now) else { return nil }
        let total = info.ri_user_time.addingReportingOverflow(info.ri_system_time)
        guard !total.overflow else { return nil }
        let cpu = cpuFraction(pid, total: total.partialValue, start: info.ri_proc_start_abstime, now: now)
        next[pid] = ProcessCounter(cpuTime: total.partialValue, startTime: info.ri_proc_start_abstime, observedAt: now)
        return ProcessUsage(id: pid, name: identity.name, applicationPath: identity.applicationPath,
                            memory: info.ri_phys_footprint, cpu: cpu)
    }

    // 同时校验进程生命期及读取间隔，并将 Mach 时间转换为秒。
    private func cpuFraction(_ pid: pid_t, total: UInt64, start: UInt64, now: TimeInterval) -> Double? {
        guard let old = previous[pid], old.startTime == start, total >= old.cpuTime,
              now > old.observedAt, timebase > 0 else { return nil }
        return Double(total - old.cpuTime) * timebase / 1_000_000_000
            / (now - old.observedAt) / processorCount
    }

    // 定期刷新元信息以处理 exec；应用路径只从实际可执行文件路径推导。
    private func identity(_ pid: pid_t, start: UInt64, executableID: UUID, now: TimeInterval) -> ProcessIdentity? {
        if let cached = identities[pid], cached.startTime == start, cached.executableID == executableID,
           now - cached.refreshedAt < MonitorConfiguration.metadataLifetime { return cached }
        var name = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_name(pid, &name, UInt32(name.count)) > 0 else { return nil }
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &path, UInt32(path.count))
        let executable = length > 0 ? String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) : ""
        let root = executable.range(of: ".app/").map { String(executable[..<$0.lowerBound]) + ".app" }
        let result = ProcessIdentity(startTime: start, executableID: executableID, name: String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self), applicationPath: root, refreshedAt: now)
        identities[pid] = result
        return result
    }

    // 从本地应用包读取展示名称，避免在视图刷新时查询磁盘。
    private func applicationName(_ path: String?, fallback: String) -> String {
        guard let path else { return fallback }
        if let cached = names[path] { return cached }
        let bundle = Bundle(path: path)
        let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        names[path] = name
        return name
    }

    // Intel 和 Apple Silicon 使用同一套系统时间基准转换。
    private static func readTimebase() -> Double {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom != 0 else { return 0 }
        return Double(info.numer) / Double(info.denom)
    }
}
