import SwiftUI

@main
struct OffroadARApp: App {
    @StateObject private var controller = ARController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(controller)
        }
    }
}
