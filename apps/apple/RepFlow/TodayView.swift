import SwiftData
import SwiftUI

/// B5 登录接入前的临时账号：本机生成一个 ID 并持久保存，让本地数据层的按账号隔离先跑起来。
/// 登录完成后改用后端返回的 user_id。
enum PlaceholderAccount {
    private static let key = "placeholderUserID"

    static var userID: UUID {
        if let saved = UserDefaults.standard.string(forKey: key), let id = UUID(uuidString: saved) {
            return id
        }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: key)
        return id
    }
}

/// 「今天」页的最小版本：手动记录入口。统计卡、最近训练、历史与详情在下一批 Issue 做。
struct TodayView: View {
    let userID: UUID

    @Query private var workouts: [Workout]
    @State private var isRecording = false

    init(userID: UUID) {
        self.userID = userID
        _workouts = Query(filter: #Predicate<Workout> { $0.userID == userID })
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(Date.now.formatted(.dateTime.month().day().weekday(.abbreviated)))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Palette.text2)
                    Text("本机已保存 \(workouts.count) 次训练")
                        .foregroundStyle(Palette.text)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .card()
                    Button {
                        isRecording = true
                    } label: {
                        Label("手动记录一次训练", systemImage: "plus")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Palette.text)
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .overlay(
                                RoundedRectangle(cornerRadius: 18)
                                    .strokeBorder(
                                        Palette.text2.opacity(0.6),
                                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
                    }
                }
                .padding(.horizontal, 20)
            }
            .pageBackground()
            .navigationTitle("今天")
            .sheet(isPresented: $isRecording) {
                ManualWorkoutView(userID: userID)
            }
        }
    }
}
