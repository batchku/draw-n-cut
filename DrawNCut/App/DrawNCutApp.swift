import SwiftUI

@main
struct DrawNCutApp: App {
    var body: some Scene {
        WindowGroup {
            // Light-only: the canvas is the paper, and paper is white.
            RootView()
                .preferredColorScheme(.light)
        }
    }
}
