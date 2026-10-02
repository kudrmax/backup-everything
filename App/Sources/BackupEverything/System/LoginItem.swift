import Foundation
import ServiceManagement

@MainActor
protocol LoginService {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LoginService {}

@MainActor
struct LoginItem {
    private let service: any LoginService

    init(service: any LoginService = SMAppService.mainApp) {
        self.service = service
    }

    var isEnabled: Bool {
        service.status == .enabled
    }

    /// Follows the switch when it disagrees with the system: the position the system ended up in and why it failed, if it did.
    func apply(_ enabled: Bool) -> (isEnabled: Bool, problem: String?)? {
        guard enabled != isEnabled else { return nil }
        let problem = setEnabled(enabled)
        return (isEnabled, problem)
    }

    private func setEnabled(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            return nil
        } catch {
            return "Could not change launch at login: \(error.localizedDescription)"
        }
    }
}
