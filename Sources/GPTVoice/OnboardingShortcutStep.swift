import SwiftUI

struct OnboardingShortcutStep: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            OnboardingHeader(title: "Choose a shortcut",
                             summary: "Choose whether to hold the shortcut or press it to start and stop.")
            ShortcutPanel(model: model)
        }
    }
}
