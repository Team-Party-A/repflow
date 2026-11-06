import SwiftData
import SwiftUI

/// 设置页：当前账号、同步状态与退出登录
struct SettingsView: View {
    let account: Account

    @EnvironmentObject private var accounts: AccountStore
    @EnvironmentObject private var uploads: UploadQueue
    @Environment(\.colorScheme) private var colorScheme
    @Query private var workouts: [Workout]
    @Query private var tasks: [UploadTask]
    @State private var isConfirmingLogout = false

    init(account: Account) {
        self.account = account
        _workouts = Query(filter: WorkoutStore.owned(by: account.userID))
        _tasks = Query(filter: WorkoutStore.uploadTasks(of: account.userID))
    }

    /// 一条训练最多一个任务，所以任务数就是待同步的训练数加上没发出去的删除
    private var unsyncedCount: Int { tasks.count }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    SyncBanner(userID: account.userID)
                    HStack(spacing: 14) {
                        Text(account.username.prefix(1).uppercased())
                            .font(.title2.weight(.bold))
                            .foregroundStyle(Palette.volt)
                            .frame(width: 52, height: 52)
                            .background(
                                Circle().fill(colorScheme == .light ? Palette.text : Palette.raised)
                            )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.username)
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(Palette.text)
                            Text("已登录 · 本机 \(workouts.count) 次训练")
                                .font(.footnote)
                                .foregroundStyle(Palette.text2)
                        }
                        Spacer()
                    }
                    .padding(16)
                    .card()

                    Text("同步")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Palette.text2)
                        .padding(.leading, 4)
                    HStack {
                        Text("待上传").foregroundStyle(Palette.text)
                        Spacer()
                        Text(unsyncedCount > 0 ? "\(unsyncedCount) 条" : "无")
                            .foregroundStyle(Palette.text2)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .card()
                    if unsyncedCount > 0 && !accounts.isSessionExpired {
                        Button {
                            Task { await uploads.retry(userID: account.userID) }
                        } label: {
                            Label("立即上传", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }

                    Text("训练记录按账号分开保存在本机。退出登录不会删除记录，再次登录同一账号后，未上传的记录会继续上传。")
                        .font(.footnote)
                        .foregroundStyle(Palette.text2)
                        .padding(.horizontal, 4)

                    Button("退出登录", role: .destructive) { isConfirmingLogout = true }
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Palette.red)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .padding(.horizontal, 20)
            }
            .pageBackground()
            .navigationTitle("设置")
            .alert(logoutTitle, isPresented: $isConfirmingLogout) {
                Button("取消", role: .cancel) {}
                Button("退出登录", role: .destructive) { Task { await accounts.logout() } }
            } message: {
                Text(
                    unsyncedCount > 0
                        ? "记录会保留在本机，重新登录 \(account.username) 后继续上传。"
                        : "本机记录会保留，重新登录后可以继续查看。")
            }
        }
    }

    private var logoutTitle: String {
        unsyncedCount > 0 ? "还有 \(unsyncedCount) 条记录未上传，仍要退出登录吗？" : "退出登录？"
    }
}
