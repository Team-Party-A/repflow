import SwiftUI

@main
struct RepFlowWatchApp: App {
    @WKApplicationDelegateAdaptor(RecordingBackgroundTasks.self) private var backgroundTasks
    private let transfer = RecordingTransfer.shared

    var body: some Scene {
        WindowGroup {
            ContentView(transfer: transfer)
        }
    }
}
