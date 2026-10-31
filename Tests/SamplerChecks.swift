import Foundation
import Darwin

// 无外部依赖的采集校验，可直接用 swiftc 编译执行。
@main
struct SamplerChecks {
    // 执行边界回归和本机独立 CPU 校准。
    static func main() {
        checkNetwork()
        checkMemoryAndGrouping()
        checkMemoryHeadroom()
        // 核对连续压力估算的计算与边界，不借用占用率或余量补数。
        checkMemoryPressureEstimate()
        checkLiveSampling()
        // 验证关闭详情后不保留进程信息，重新打开不会跨关闭区间计算 CPU。
        checkApplicationDemand()
        print("PASS: 所有采样校验通过")
    }

    // 验证 64 位流量、断连、接口切换及计数器回退。
    private static func checkNetwork() {
        let old = ["en0": InterfaceCounters(received: 5_000_000_000, sent: 1_000)]
        let current = ["en0": InterfaceCounters(received: 5_000_004_096, sent: 1_512)]
        let delta = SystemSampler.networkDelta(current: current, previous: old)
        precondition(delta == NetworkDelta(received: 4_096, sent: 512, complete: true))
        precondition(!SystemSampler.networkDelta(current: [:], previous: old).complete)
        precondition(!SystemSampler.networkDelta(current: ["en1": InterfaceCounters(received: 1, sent: 1)], previous: old).complete)
        let reset = ["en0": InterfaceCounters(received: 0, sent: 0)]
        precondition(SystemSampler.networkDelta(current: reset, previous: old) == NetworkDelta(received: 0, sent: 0, complete: false))
        print("PASS: 64 位计数、断连、接口切换及计数重置")
    }

    // 验证内存不重复相加、应用合计及首次 CPU 值的传播。
    private static func checkMemoryAndGrouping() {
        let memory = MemoryUsage(total: 100, application: 30, wired: 10, compressed: 20, cached: 25)
        precondition(memory.used == 60 && memory.available == 40 && memory.fraction == 0.6)
        let first = ProcessUsage(id: 1, name: "A", applicationPath: "/A.app", memory: 12, cpu: 0.1)
        let second = ProcessUsage(id: 2, name: "B", applicationPath: "/A.app", memory: 18, cpu: nil)
        let app = ApplicationUsage(id: "/A.app", name: "A", path: "/A.app", processes: [first, second])
        precondition(app.memory == 30 && app.cpu == nil && app.processes.count == 2)
        precondition(MonitorFormat.metric(1_000_000_000).text == "1.0 GB")
        precondition(MonitorFormat.rate(nil) == "—")
        print("PASS: 内存构成、应用合计、首次采样及十进制单位")
    }

    // 余量只接受系统定义的 0...100%，边界与未知值不会伪造数据。
    private static func checkMemoryHeadroom() {
        precondition(MemoryHeadroom(availablePercent: 0)?.fraction == 0)
        precondition(MemoryHeadroom(availablePercent: 100)?.fraction == 1)
        precondition(MemoryHeadroom(availablePercent: 47)?.fraction == 0.47)
        precondition(MemoryHeadroom(availablePercent: -1) == nil)
        precondition(MemoryHeadroom(availablePercent: 101) == nil)
        print("PASS: 内存余量百分比的零值、满值、普通值及越界校验")
    }

    // 覆盖零值、满值、正常比例和异常采样，保证估算结果处于 0...100%。
    private static func checkMemoryPressureEstimate() {
        let readings: [(UInt64, UInt64, UInt64, Double?)] = [
            (100, 20, 0, 0), (100, 20, 40, 0.5), (100, 20, 80, 1),
            (0, 0, 0, nil), (100, 100, 0, nil), (100, 101, 0, nil), (100, 20, 81, nil)
        ]
        for (total, wired, compressed, expected) in readings {
            let memory = MemoryUsage(total: total, application: 0, wired: wired, compressed: compressed, cached: 0)
            precondition(MemoryPressureEstimate(memory: memory)?.fraction == expected)
        }
        var snapshot = MonitorSnapshot()
        precondition(snapshot.memoryPressureEstimate == nil)
        snapshot.memory = MemoryUsage(total: 100, application: 35, wired: 20, compressed: 40, cached: 0)
        snapshot.memoryHeadroom = MemoryHeadroom(availablePercent: 30)
        precondition(snapshot.memoryPressureEstimate?.fraction == 0.5 && snapshot.memory?.fraction == 0.95)
        print("PASS: 压力估算的零值、50%、满值和异常边界；估算独立于占用率与系统余量")
    }

    // 使用 getrusage 的微秒 CPU 时间独立验证 Mach 时间换算。
    private static func checkLiveSampling() {
        let sampler = SystemSampler()
        let initial = sampler.sample()
        precondition(initial.cpu == nil && initial.download == nil)
        let processSampler = ProcessSampler()
        _ = processSampler.sample()
        var before = rusage(), after = rusage()
        getrusage(RUSAGE_SELF, &before)
        let start = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime - start < 1.2 { _ = sqrt(Double.random(in: 1...100)) }
        getrusage(RUSAGE_SELF, &after)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let sample = sampler.sample()
        let own = processSampler.sample().flatMap(\.processes).first { $0.id == getpid() }
        let independent = (seconds(after) - seconds(before)) / elapsed / Double(ProcessInfo.processInfo.activeProcessorCount)
        precondition(sample.memory != nil && sample.cpu != nil)
        precondition(own?.cpu != nil && abs((own?.cpu ?? 0) - independent) < 0.015)
        print("PASS: 本机 getrusage CPU 校准；差异 \(abs((own?.cpu ?? 0) - independent) * 100) 个百分点")
        checkPerformance(sampler)
    }

    // 记录优化构建下每次采集耗时和进程端口数量是否保持稳定。
    private static func checkPerformance(_ sampler: SystemSampler) {
        sampler.setApplicationsEnabled(true)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let baseline = hostReferences(host)
        var durations: [Double] = []
        for _ in 0..<50 { durations.append(sampler.sample().samplingMilliseconds) }
        let portsAfter = hostReferences(host)
        precondition(portsAfter == baseline)
        let average = durations.reduce(0, +) / Double(durations.count)
        print("MEASURE: 50 次采样平均 \(average) ms，最大 \(durations.max() ?? 0) ms；Mach 端口 \(baseline) → \(portsAfter)")
    }

    // 按需采集必须保留首次缺失值语义，关闭图表后也不继续积累隐藏历史。
    private static func checkApplicationDemand() {
        let sampler = SystemSampler()
        precondition(sampler.sample().topMemory.isEmpty)
        sampler.setApplicationsEnabled(true)
        let first = sampler.sample()
        precondition(!first.topMemory.isEmpty && first.topCPU.isEmpty)
        precondition(!sampler.sample().topCPU.isEmpty)
        sampler.setApplicationsEnabled(false)
        let closed = sampler.sample()
        precondition(closed.topMemory.isEmpty && closed.topCPU.isEmpty)
        sampler.setApplicationsEnabled(true)
        precondition(sampler.sample().topCPU.isEmpty, "恢复时不能使用关闭前的进程 CPU 基线")
        var preferences = MonitorPreferences()
        preferences.showCharts = false
        preferences.showApplications = false
        sampler.configure(preferences)
        let hidden = sampler.sample()
        precondition(hidden.cpuHistory.isEmpty && hidden.networkHistory.isEmpty && hidden.topMemory.isEmpty)
        print("PASS: 进程按需采样、关闭释放、重开 CPU 基线与隐藏图表")
    }

    // getrusage 提供与 Mach 时间接口独立的微秒累计 CPU 时间。
    private static func seconds(_ value: rusage) -> Double {
        Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec) + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1_000_000
    }

    // 直接检查 send-right 引用数量，同名端口的引用泄漏也能检测。
    private static func hostReferences(_ host: mach_port_t) -> mach_port_urefs_t {
        var references: mach_port_urefs_t = 0
        precondition(mach_port_get_refs(mach_task_self_, host, MACH_PORT_RIGHT_SEND, &references) == KERN_SUCCESS)
        return references
    }
}
