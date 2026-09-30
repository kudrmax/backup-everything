import SwiftUI

struct SettingsView: View {
    @State private var launchesAtLogin = LoginItem.isEnabled
    @State private var loginProblem: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                SettingsCard {
                    SettingsRow(title: "Запускать при входе в систему") {
                        Toggle("", isOn: $launchesAtLogin)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
                    }
                }
                if let loginProblem {
                    Text(loginProblem)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 14)
                }
            }
            .padding(24)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Настройки")
        .onChange(of: launchesAtLogin) { _, enabled in
            guard enabled != LoginItem.isEnabled else { return }
            loginProblem = LoginItem.setEnabled(enabled)
            launchesAtLogin = LoginItem.isEnabled
        }
    }
}
