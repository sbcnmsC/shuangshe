import SwiftUI

@main
struct DualCamLiveApp: App {
    @StateObject private var settings = CaptureSettings()
    @StateObject private var camera = DualCameraSessionModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(camera)
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
        }
    }
}
