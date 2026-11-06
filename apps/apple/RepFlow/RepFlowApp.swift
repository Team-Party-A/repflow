import SwiftData
import SwiftUI

@main
struct RepFlowApp: App {
    // 后台文件投递可能不创建窗口，连接随 App 初始化，不能等视图出现。
    private let transfer = RecordingTransfer.shared
    @StateObject private var accounts = AccountStore(api: APIClient.configured())
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
            Group {
                if let account = accounts.current {
                    TabView {
                        TodayView(userID: account.userID)
                            .tabItem { Label("今天", systemImage: "chart.bar") }
                        ContentView(transfer: transfer)
                            .tabItem { Label("录制文件", systemImage: "waveform") }
                        SettingsView(account: account)
                            .tabItem { Label("设置", systemImage: "gearshape") }
                    }
                    // 各页的 @Query 在 init 里按 userID 建，换账号时整棵重建，避免残留上个账号的查询
                    .id(account.userID)
                } else {
                    AuthView()
                }
            }
            // 规范只有一个强调色 Volt，系统蓝不再出现；选中态用正文色
            .tint(Palette.text)
            .environmentObject(accounts)
        }
        .modelContainer(container)
    }
}
