import SwiftUI

struct SettingsView: View {
    private let loginItem = LoginItem()
    @State private var launchesAtLogin = LoginItem().isEnabled
    @State private var loginProblem: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                SettingsCard {
                    SettingsRow(title: "Launch at login") {
                        Toggle("", isOn: $launchesAtLogin)
                            .toggleStyle(.switch)
                            .pointing()
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
        .navigationTitle("Settings")
        .onChange(of: launchesAtLogin) { _, enabled in
            guard let result = loginItem.apply(enabled) else { return }
            loginProblem = result.problem
            launchesAtLogin = result.isEnabled
        }
    }
}
