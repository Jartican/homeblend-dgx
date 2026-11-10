import SwiftUI

@main
struct HomeBlendCompanionApp: App {
    @StateObject private var model = CompanionViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
        }
    }
}
