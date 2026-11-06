import SwiftData
import SwiftUI

/// 页面顶部的同步横幅（原型 `banners()`）：登录失效时提示重新登录；有记录没传上去时显示
/// 「同步失败」并可重试。都没有时不占位置。逐条训练的同步标签随历史列表（#99）做。
struct SyncBanner: View {
    let userID: UUID

    @EnvironmentObject private var accounts: AccountStore
    @EnvironmentObject private var uploads: UploadQueue
    @Query private var tasks: [UploadTask]

    init(userID: UUID) {
        self.userID = userID
        _tasks = Query(filter: WorkoutStore.uploadTasks(of: userID))
    }

    var body: some View {
        let failedCount = tasks.filter { $0.state != .waiting }.count
        if accounts.isSessionExpired {
            banner("登录已失效", detail: "请重新登录后继续同步，本地记录不受影响") {
                // token 已经删了，这里只是回到登录页；记录和任务都保留，同账号登录后接着传
                Button("重新登录") { Task { await accounts.logout() } }
            }
        } else if failedCount > 0 {
            banner("同步失败 · 本地记录已保留", detail: "\(failedCount) 条记录没有上传成功") {
                Button {
                    Task { await uploads.retry(userID: userID) }
                } label: {
                    Label("重试", systemImage: "arrow.clockwise")
                }
            }
        }
    }

    private func banner(
        _ title: String, detail: String, @ViewBuilder action: () -> some View
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.footnote)
            }
            Spacer(minLength: 0)
            action()
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.text)
                .padding(.horizontal, 12)
                .frame(minHeight: 36)
                .background(Capsule().fill(Palette.surface))
        }
        .foregroundStyle(Palette.red)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        // 规范的红色浅底不在 8 个色板 token 里，用 red 降透明度近似（原型深色即 13%）
        .background(RoundedRectangle(cornerRadius: 16).fill(Palette.red.opacity(0.13)))
    }
}
