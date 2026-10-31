import AppKit
import Foundation
import UserNotifications

// 基于有效采样计算持续时间和冷却，避免瞬时峰值反复提醒。
struct AlertState {
    private var cpuSince: Date?
    private var lastCPUSample: Date?
    private var lastCPU: Date?
    private var lastMemory: Date?

    // 未启用、无数据或低于阈值时重置连续高负载时间。
    mutating func cpuShouldAlert(_ snapshot: MonitorSnapshot, preferences: MonitorPreferences) -> Bool {
        guard preferences.cpuAlerts, let cpu = snapshot.cpu, cpu * 100 >= preferences.cpuThreshold else {
            cpuSince = nil
            lastCPUSample = nil
            return false
        }
        let now = snapshot.sampledAt
        if let previous = lastCPUSample, now.timeIntervalSince(previous) > preferences.interval * MonitorConfiguration.historyGapMultiplier { cpuSince = nil }
        lastCPUSample = now
        if cpuSince == nil { cpuSince = now }
        guard let cpuSince, now.timeIntervalSince(cpuSince) >= preferences.cpuDuration,
              lastCPU.map({ now.timeIntervalSince($0) >= preferences.alertCooldown }) ?? true else { return false }
        lastCPU = now
        return true
    }

    // 内存提醒只使用系统原生压力等级，不使用估算百分比。
    mutating func memoryShouldAlert(_ snapshot: MonitorSnapshot, preferences: MonitorPreferences) -> Bool {
        guard preferences.memoryAlerts, snapshot.pressure == .warning || snapshot.pressure == .critical else { return false }
        let now = snapshot.sampledAt
        guard lastMemory.map({ now.timeIntervalSince($0) >= preferences.alertCooldown }) ?? true else { return false }
        lastMemory = now
        return true
    }
}

// 负责系统通知授权及投递，采样与通知均复用现有快照。
@MainActor
final class AlertController {
    private var state = AlertState()

    // 用户主动启用提醒后才请求系统通知权限。
    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    // 根据持续时间和冷却决定是否发送通知。
    func evaluate(_ snapshot: MonitorSnapshot, preferences: MonitorPreferences) {
        if state.cpuShouldAlert(snapshot, preferences: preferences) {
            send(title: "CPU 持续高占用", body: "CPU 占用已持续高于 \(Int(preferences.cpuThreshold))%。", identifier: "cpu")
        }
        if state.memoryShouldAlert(snapshot, preferences: preferences) {
            send(title: "内存压力\(snapshot.pressure.title)", body: snapshot.pressure.summary, identifier: "memory")
        }
    }

    // 投递独立标识的本地通知，不发送网络请求。
    private func send(title: String, body: String, identifier: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: "com.kimo.monitor.\(identifier)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
