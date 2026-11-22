import SwiftData
import SwiftUI

@main
struct RepFlowApp: App {
    // 后台文件投递可能不创建窗口，连接随 App 初始化，不能等视图出现。
    private let transfer = RecordingTransfer.shared
    private let container: ModelContainer
    @StateObject private var accounts: AccountStore
    @StateObject private var uploads: UploadQueue
    @StateObject private var inbox: WatchInbox
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
        let uploads = UploadQueue(context: container.mainContext, api: api, accounts: accounts)
        let inbox = WatchInbox(
            context: container.mainContext, sender: RecordingTransfer.shared,
            currentUserID: { accounts.current?.userID },
            onStored: { userID in uploads.sync(userID: userID) })
        // 回调都在主队列，App 初始化完成前不会进来
        RecordingTransfer.shared.onUserInfo = { userInfo in
            MainActor.assumeIsolated { inbox.receive(userInfo) }
        }
        RecordingTransfer.shared.onActivated = { MainActor.assumeIsolated { inbox.requestRetry() } }
        _uploads = StateObject(wrappedValue: uploads)
        _inbox = StateObject(wrappedValue: inbox)
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
            .environmentObject(inbox)
            // 登录和注册成功都会走到这里；同账号重新登录后接着发之前没传完的任务，
            // 并请手表补发登录前没被接收的记录
            .onChange(of: accounts.current?.userID) { _, userID in
                guard let userID else { return }
                uploads.sync(userID: userID)
                inbox.requestRetry()
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
