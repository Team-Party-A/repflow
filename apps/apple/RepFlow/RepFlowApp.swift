import SwiftData
import SwiftUI

@main
struct RepFlowApp: App {
    // 后台文件投递可能不创建窗口，连接随 App 初始化，不能等视图出现。
    private let transfer = RecordingTransfer.shared
    private let container: ModelContainer = {
        do {
            return try WorkoutStore.makeContainer()
        } catch {
            // 本地库打不开时继续运行只会让记录静默丢失，直接终止并留下原因
            fatalError("open local workout store failed: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            TabView {
                TodayView(userID: PlaceholderAccount.userID)
                    .tabItem { Label("今天", systemImage: "chart.bar") }
                ContentView(transfer: transfer)
                    .tabItem { Label("录制文件", systemImage: "waveform") }
            }
            // 规范只有一个强调色 Volt，系统蓝不再出现；选中态用正文色
            .tint(Palette.text)
        }
        .modelContainer(container)
    }
}
