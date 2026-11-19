import SwiftData
import SwiftUI

@main
struct RepFlowApp: App {
    // 后台文件投递可能不创建窗口，连接随 App 初始化，不能等视图出现。
    private let transfer = RecordingTransfer.shared
    private let container: ModelContainer
    @StateObject private var accounts: AccountStore
    @StateObject private var uploads: UploadQueue
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let container: ModelContainer
        do {
            container = try WorkoutStore.makeContainer()
        } catch {
            // 本地库打不开时继续运行只会让记录静默丢失，直接终止并留下原因
            fatalError("open local workout store failed: \(error)")
        }
        let api = APIClient.configured()
        let accounts = AccountStore(api: api, context: container.mainContext)
        self.container = container
        _accounts = StateObject(wrappedValue: accounts)
        // 和页面共用 mainContext：训练和任务的改动彼此立即可见，不会读到另一个上下文的旧缓存
        _uploads = StateObject(
            wrappedValue: UploadQueue(context: container.mainContext, api: api, accounts: accounts))
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let account = accounts.current {
                    TabView {
                        TodayView(userID: account.userID)
                            .tabItem { Label("今天", systemImage: "chart.bar") }
                        HistoryView(userID: account.userID)
                            .tabItem { Label("历史", systemImage: "list.bullet") }
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
            .environmentObject(uploads)
            // 登录和注册成功都会走到这里；同账号重新登录后接着发之前没传完的任务
            .onChange(of: accounts.current?.userID) { _, userID in
                if let userID { uploads.sync(userID: userID) }
            }
        }
        .modelContainer(container)
        // 冷启动也算回到前台：杀掉重开后没传完的任务会接着发
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active, let userID = accounts.current?.userID {
                uploads.sync(userID: userID)
            }
        }
    }
}
