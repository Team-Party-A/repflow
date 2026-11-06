import SwiftData
import SwiftUI

/// 设置页最小版本：当前账号与退出登录。同步状态卡片随上传（#97）补。
struct SettingsView: View {
    let account: Account

    @EnvironmentObject private var accounts: AccountStore
    @Environment(\.colorScheme) private var colorScheme
    @Query private var workouts: [Workout]
    @State private var isConfirmingLogout = false

    init(account: Account) {
        self.account = account
        _workouts = Query(filter: WorkoutStore.owned(by: account.userID))
    }

    private var unsyncedCount: Int { workouts.filter { !$0.isSynced }.count }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
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
