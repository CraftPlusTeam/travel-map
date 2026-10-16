import SwiftUI

@main
struct TravelMapApp: App {
    @StateObject private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            MapScreen(store: store)
                .tint(Theme.accent)
                .preferredColorScheme(testingColorScheme)
        }
    }

    private var testingColorScheme: ColorScheme? {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("-ui-testing") && arguments.contains("-ui-testing-dark") ? .dark : nil
    }
}

enum Theme {
    static let accent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.39, green: 0.84, blue: 0.77, alpha: 1)
            : UIColor(red: 0.04, green: 0.38, blue: 0.35, alpha: 1)
    })
    static let canvas = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
}
