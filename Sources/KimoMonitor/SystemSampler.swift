import Foundation
import Darwin

// 保存网络接口的一次 64 位内核计数及该次读取的时间。
struct InterfaceCounters: Equatable {
    let received: UInt64
    let sent: UInt64
}

// 汇总可以明确计算的接口字节增量。
struct NetworkDelta: Equatable {
    let received: UInt64
    let sent: UInt64
    let complete: Bool
}

// 该对象的全部可变状态仅由 MonitorStore 的专用串行队列访问。
final class SystemSampler: @unchecked Sendable {
    private let host = mach_host_self()
    private let processes = ProcessSampler()
    private var previousNetwork: [String: InterfaceCounters]?
    private var previousNetworkTime: TimeInterval?
    private var previousCPU: host_cpu_load_info?
    private var snapshot = MonitorSnapshot()
    private var preferences = MonitorPreferences()

    // 释放一次获取并重复使用的 Mach 主机端口，避免长期运行泄漏 send rights。
    deinit { mach_port_deallocate(mach_task_self_, host) }

    // 在后台完成系统调用、差分计算和排序，仅传回不可变值。
    func sample() -> MonitorSnapshot {
        let start = ProcessInfo.processInfo.systemUptime
        snapshot.sampledAt = .now
        // 先读取网络与 CPU 累计计数，再分别计算真实时间间隔。
        updateNetwork()
        updateCPU()
        snapshot.memory = readMemory()
        snapshot.pressure = readPressure()
        snapshot.memoryHeadroom = readMemoryHeadroom()
        // 应用分组及排序只在后台执行一次。
        updateApplications()
        recordHistory()
        snapshot.samplingMilliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1_000
        return snapshot
    }

    // 在采样队列更新配置，接口变化时丢弃旧网络基线。
    func configure(_ value: MonitorPreferences) {
        if preferences.networkInterface != value.networkInterface {
            previousNetwork = nil
            previousNetworkTime = nil
            snapshot.networkHistory = []
        }
        preferences = value
    }

    // 唤醒后重新建立累计计数基线；本次运行已记录流量保持不变。
    func resetBaseline() {
        previousNetwork = nil
        previousNetworkTime = nil
        previousCPU = nil
        processes.resetBaseline()
        snapshot.networkHistory = []
        snapshot.cpuHistory = []
    }

    // 只有接口集合相同且计数未重置时才发布完整速率。
    private func updateNetwork() {
        let available = readNetwork()
        snapshot.interfaces = available?.keys.sorted() ?? []
        let selected = preferences.networkInterface
        let current = selected.isEmpty ? available : available.map { $0.filter { $0.key == selected } }
        let now = ProcessInfo.processInfo.systemUptime
        defer { previousNetwork = current; previousNetworkTime = now }
        snapshot.download = nil
        snapshot.upload = nil
        guard let current, let old = previousNetwork, let previousNetworkTime,
              now > previousNetworkTime else { return }
        let delta = Self.networkDelta(current: current, previous: old)
        snapshot.received += delta.received
        snapshot.sent += delta.sent
        guard delta.complete else { return }
        snapshot.download = Double(delta.received) / (now - previousNetworkTime)
        snapshot.upload = Double(delta.sent) / (now - previousNetworkTime)
    }

    // 对接口新增、断开及计数器重置保留不完整状态，不伪装成零流量。
    static func networkDelta(current: [String: InterfaceCounters], previous: [String: InterfaceCounters]) -> NetworkDelta {
        var received: UInt64 = 0, sent: UInt64 = 0
        var complete = !current.isEmpty && Set(current.keys) == Set(previous.keys)
        for (name, counter) in current {
            guard let old = previous[name], counter.received >= old.received, counter.sent >= old.sent else {
                complete = false
                continue
            }
            received += counter.received - old.received
            sent += counter.sent - old.sent
        }
        return NetworkDelta(received: received, sent: sent, complete: complete)
    }

    // 从路由接口消息中读取 64 位计数，失败时不沿用旧值。
    private func readNetwork() -> [String: InterfaceCounters]? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0 else { return nil }
        return parseInterfaces(buffer, size: size)
    }

    // 根据消息实际长度前进，正确跳过比 if_msghdr2 更短的地址消息。
    private func parseInterfaces(_ buffer: [UInt8], size: Int) -> [String: InterfaceCounters] {
        buffer.withUnsafeBytes { bytes in
            var result: [String: InterfaceCounters] = [:]
            var offset = 0
            while offset + 4 <= size {
                let length = Int(bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                guard length >= 4, offset + length <= size else { break }
                defer { offset += length }
                guard bytes[offset + 3] == RTM_IFINFO2, length >= MemoryLayout<if_msghdr2>.size else { continue }
                let header = bytes.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                guard let name = physicalInterfaceName(header) else { continue }
                result[name] = InterfaceCounters(received: header.ifm_data.ifi_ibytes, sent: header.ifm_data.ifi_obytes)
            }
            return result
        }
    }

    // 采用 en 接口口径，排除回环、桥接和 VPN 隧道的重复字节。
    private func physicalInterfaceName(_ header: if_msghdr2) -> String? {
        guard header.ifm_flags & IFF_UP != 0, header.ifm_flags & IFF_RUNNING != 0 else { return nil }
        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        guard if_indextoname(UInt32(header.ifm_index), &name) != nil else { return nil }
        let value = String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return value.hasPrefix("en") ? value : nil
    }

    // 读取 CPU ticks 并处理 UInt32 计数器回绕。
    private func updateCPU() {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count) }
        }
        snapshot.cpu = nil
        guard result == KERN_SUCCESS else { previousCPU = nil; return }
        defer { previousCPU = info }
        guard let old = previousCPU else { return }
        let current = [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3]
        let previous = [old.cpu_ticks.0, old.cpu_ticks.1, old.cpu_ticks.2, old.cpu_ticks.3]
        let delta = zip(current, previous).map { UInt64($0 &- $1) }
        let total = delta.reduce(0, +)
        guard total > 0 else { return }
        snapshot.cpu = 1 - Double(delta[Int(CPU_STATE_IDLE)]) / Double(total)
    }

    // 用匿名页减可清除页计算应用内存，独立保留连线、压缩和缓存。
    private func readMemory() -> MemoryUsage? {
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        var pageSize: vm_size_t = 0
        guard host_page_size(host, &pageSize) == KERN_SUCCESS else { return nil }
        let page = UInt64(pageSize)
        let anonymous = UInt64(info.internal_page_count)
        let purgeable = UInt64(info.purgeable_count)
        return MemoryUsage(total: ProcessInfo.processInfo.physicalMemory,
                           application: (anonymous > purgeable ? anonymous - purgeable : 0) * page,
                           wired: UInt64(info.wire_count) * page, compressed: UInt64(info.compressor_page_count) * page,
                           cached: (UInt64(info.external_page_count) + purgeable) * page)
    }

    // 尝试读取系统离散压力级别；不支持的内核或未知值明确返回不可用。
    private func readPressure() -> MemoryPressure {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &value, &size, nil, 0) == 0 else { return .unavailable }
        // XNU 此 sysctl 已转换为 dispatch 级别，不使用内核内部 0...3 枚举。
        switch value {
        case Int32(DispatchSource.MemoryPressureEvent.normal.rawValue): return .normal
        case Int32(DispatchSource.MemoryPressureEvent.warning.rawValue): return .warning
        case Int32(DispatchSource.MemoryPressureEvent.critical.rawValue): return .critical
        default: return .unavailable
        }
    }

    // 直接读取内核可用页比例，不调用 shell，也不把离散压力等级硬转换为百分比。
    private func readMemoryHeadroom() -> MemoryHeadroom? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_level", &value, &size, nil, 0) == 0,
              size == MemoryLayout<Int32>.size else { return nil }
        return MemoryHeadroom(availablePercent: value)
    }

    // 预先计算菜单面板需要的排行榜，避免 SwiftUI 刷新时扫描和排序。
    private func updateApplications() {
        let applications = processes.sample()
        snapshot.topMemory = Array(applications.sorted { $0.memory > $1.memory }.prefix(preferences.processLimit))
        snapshot.topCPU = Array(applications.filter { $0.cpu != nil }.sorted { ($0.cpu ?? 0) > ($1.cpu ?? 0) }.prefix(preferences.processLimit))
    }

    // 按真实时间裁剪图表，失败或休眠间隔保持缺口。
    private func recordHistory() {
        let now = ProcessInfo.processInfo.systemUptime
        snapshot.networkHistory.append(HistoryPoint(time: now, primary: snapshot.download, secondary: snapshot.upload))
        snapshot.cpuHistory.append(HistoryPoint(time: now, primary: snapshot.cpu, secondary: nil))
        snapshot.networkHistory.removeAll { $0.time < now - preferences.historySeconds }
        snapshot.cpuHistory.removeAll { $0.time < now - preferences.historySeconds }
    }
}
