import SwiftUI
import Darwin

// 使用生产菜单栏和窗口测量真实 CPU 时间及物理内存，不以瞬时百分比代替平均负载。
@main
struct PerformanceChecks: App {
    // 等待应用场景就绪后顺序测量三个使用场景。
    init() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            await Self.measureScenarios()
            NSApplication.shared.terminate(nil)
        }
    }
    var body: some Scene { Settings { EmptyView() } }

    // 保持默认两秒采样，分别记录纯菜单栏、可见总览及关闭总览的占用。
    @MainActor private static func measureScenarios() async {
        let store = MonitorStore()
        store.preferences.value = MonitorPreferences()
        let controller = MenuBarController(store: store)
        defer { controller.stop() }
        store.start()
        await measure("menu", store: store)
        PreviewWindow.show(store: store)
        await measure("overview", store: store)
        NSApp.windows.first { $0.title == "Kimo Monitor · 实时对照" }?.close()
        await measure("closed", store: store)
    }

    // 预热后按实际经过时间计算单核心 CPU 百分比，内存读取内核 phys_footprint。
    @MainActor private static func measure(_ scenario: String, store: MonitorStore) async {
        try? await Task.sleep(for: .seconds(6))
        let start = ProcessInfo.processInfo.systemUptime
        let before = cpuSeconds()
        var sampling: [Double] = []
        var footprints: [UInt64] = []
        var residents: [UInt64] = []
        for _ in 0..<10 {
            try? await Task.sleep(for: .seconds(2))
            precondition(scenario != "overview" || !store.snapshot.topMemory.isEmpty,
                         "总览测量期间必须保持可见并采集排行，避免遮挡导致低估开销")
            sampling.append(store.snapshot.samplingMilliseconds)
            let memory = memoryUsage()
            footprints.append(memory.ri_phys_footprint / 1_048_576)
            residents.append(memory.ri_resident_size / 1_048_576)
        }
        let cpu = (cpuSeconds() - before) / (ProcessInfo.processInfo.systemUptime - start) * 100
        let average = sampling.reduce(0, +) / Double(sampling.count)
        print("MEASURE: \(scenario) cpu=\(cpu)% footprintMedian=\(footprints.sorted()[5])MiB rssMedian=\(residents.sorted()[5])MiB sample=\(average)ms")
        fflush(nil)
    }

    // getrusage 返回当前进程用户态与内核态累计 CPU 秒数。
    private static func cpuSeconds() -> Double {
        var value = rusage()
        precondition(getrusage(RUSAGE_SELF, &value) == 0)
        return Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec)
            + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1_000_000
    }

    // 直接读取本进程的驻留集和物理内存账本，避免把虚拟地址空间当成占用。
    private static func memoryUsage() -> rusage_info_v2 {
        var value = rusage_info_v2()
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V2, $0)
            }
        }
        precondition(status == 0)
        return value
    }
}
