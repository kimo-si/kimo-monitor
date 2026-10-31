import Foundation

// 验证设置对格式和提醒行为的实际影响。
@main
struct SettingsChecks {
    // 验证默认值、单位换算、持续时间、中断和冷却边界。
    @MainActor static func main() {
        let defaults = MonitorPreferences()
        precondition(defaults.showCPU && defaults.showMemory && defaults.showNetwork)
        precondition(!defaults.cpuAlerts && !defaults.memoryAlerts)
        precondition(MonitorFormat.rate(1_000, unit: .bits) == "8.0 Kb/s")
        precondition(MonitorFormat.bytes(1_073_741_824, unit: .binary) == "1.0 GiB")
        checkCPUAlerts()
        checkMemoryAlerts()
        print("PASS: 设置默认值、单位换算及 CPU / 系统内存提醒的持续和冷却规则")
    }

    // CPU 在连续高负载达阈值后提醒，采样中断必须重新计时。
    static func checkCPUAlerts() {
        var settings = MonitorPreferences()
        settings.cpuAlerts = true
        settings.cpuDuration = 10
        settings.alertCooldown = 60
        settings.interval = 2
        var state = AlertState()
        var snapshot = MonitorSnapshot()
        let start = Date(timeIntervalSince1970: 1000)
        snapshot.cpu = 0.9
        for offset in stride(from: 0, through: 8, by: 2) {
            snapshot.sampledAt = start.addingTimeInterval(Double(offset))
            precondition(!state.cpuShouldAlert(snapshot, preferences: settings))
        }
        snapshot.sampledAt = start.addingTimeInterval(10)
        precondition(state.cpuShouldAlert(snapshot, preferences: settings))
        snapshot.sampledAt = start.addingTimeInterval(12)
        precondition(!state.cpuShouldAlert(snapshot, preferences: settings))
        snapshot.cpu = nil
        precondition(!state.cpuShouldAlert(snapshot, preferences: settings))
        snapshot.cpu = 0.9
        snapshot.sampledAt = start.addingTimeInterval(100)
        precondition(!state.cpuShouldAlert(snapshot, preferences: settings))
        snapshot.sampledAt = start.addingTimeInterval(120)
        precondition(!state.cpuShouldAlert(snapshot, preferences: settings))
    }

    // 内存只依据系统警告或紧张状态，正常与不可用不能触发。
    static func checkMemoryAlerts() {
        var settings = MonitorPreferences()
        settings.memoryAlerts = true
        var state = AlertState()
        var snapshot = MonitorSnapshot()
        snapshot.sampledAt = Date(timeIntervalSince1970: 1000)
        snapshot.pressure = .normal
        precondition(!state.memoryShouldAlert(snapshot, preferences: settings))
        snapshot.pressure = .warning
        precondition(state.memoryShouldAlert(snapshot, preferences: settings))
        precondition(!state.memoryShouldAlert(snapshot, preferences: settings))
        snapshot.sampledAt.addTimeInterval(settings.alertCooldown)
        snapshot.pressure = .critical
        precondition(state.memoryShouldAlert(snapshot, preferences: settings))
    }
}
