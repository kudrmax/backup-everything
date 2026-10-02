import BackupCore
import Foundation
import UserNotifications

@MainActor
protocol NotificationPosting {
    func requestAuthorization() async
    func post(title: String, body: String)
}

struct UserNotificationCenter: NotificationPosting {
    func requestAuthorization() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

@MainActor
protocol Notifying {
    func requestAuthorization()
    func post(_ notices: [Notice])
}

/// Notifications need an app bundle: a bare binary (tests, `swift run`) has none, and then nothing is shown.
@MainActor
final class Notifier: Notifying {
    private let isAvailable: Bool
    private let center: any NotificationPosting

    init(isAvailable: Bool = Bundle.main.bundleIdentifier != nil, center: any NotificationPosting = UserNotificationCenter()) {
        self.isAvailable = isAvailable
        self.center = center
    }

    func requestAuthorization() {
        guard isAvailable else { return }
        Task { [center] in
            await center.requestAuthorization()
        }
    }

    func post(_ notices: [Notice]) {
        guard isAvailable else { return }
        for notice in notices {
            let text = NoticeText.of(notice)
            center.post(title: text.title, body: text.body)
        }
    }
}
