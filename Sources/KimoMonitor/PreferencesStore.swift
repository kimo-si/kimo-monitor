import Foundation
import Observation
import ServiceManagement

// 在主线程持有并持久化所有用户设置。
@MainActor @Observable
final class PreferencesStore {
    private static let key = "com.kimo.monitor.preferences"
    var value: MonitorPreferences { didSet { save() } }
    var loginEnabled = SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval
    var loginError: String?

    // 恢复保存的设置，首次启动使用原有默认值。
    init() {
        let data = UserDefaults.standard.data(forKey: Self.key)
        value = data.flatMap { try? JSONDecoder().decode(MonitorPreferences.self, from: $0) } ?? MonitorPreferences()
    }

    // 将设置编码为一个原子值，避免分散键之间不一致。
    private func save() {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }

    // 通过系统服务更改登录启动，并在失败时保留真实状态。
    func setLoginEnabled(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch { loginError = error.localizedDescription }
        let status = SMAppService.mainApp.status
        loginEnabled = status == .enabled || status == .requiresApproval
        if status == .requiresApproval { loginError = "请在系统设置的登录项中允许 Kimo Monitor。" }
    }

    // 重置配置并关闭登录启动，不更改历史数据或系统通知授权。
    func reset() {
        if loginEnabled { setLoginEnabled(false) }
        value = MonitorPreferences()
    }
}
