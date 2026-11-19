import SwiftUI

@main
struct SleepSoundApp: App {
    @StateObject private var recorder = Recorder()
    @StateObject private var player = Player()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(recorder)
                .environmentObject(player)
        }
    }
}
