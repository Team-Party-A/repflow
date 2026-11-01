import Foundation
import SwiftData

/// 某个登录账号看到的训练数据。切换账号就换一个 store；退出登录不删任何记录。
@MainActor
struct WorkoutStore {
    let context: ModelContext
    let userID: UUID

    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        try ModelContainer(
            for: Workout.self, WorkoutSet.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: inMemory))
    }

    func workouts() throws -> [Workout] {
        let userID = userID
        let descriptor = FetchDescriptor<Workout>(
            predicate: #Predicate { $0.userID == userID },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        return try context.fetch(descriptor)
    }

    /// 新训练从 revision 1 开始，sets 按数组顺序编号
    @discardableResult
    func create(
        startedAt: Date, timeZone: String, origin: WorkoutOrigin, sets: [WorkoutSet]
    ) throws -> Workout {
        let workout = Workout(
            userID: userID, startedAt: startedAt, timeZone: timeZone, origin: origin)
        context.insert(workout)
        for (index, set) in sets.enumerated() {
            set.position = index + 1
            set.workout = workout
        }
        try context.save()
        return workout
    }

    /// 改训练内容的唯一入口：内容和新 revision 在同一次 save 里落盘。
    /// 只在内容真正改动时调用，纯同步状态不走这里。
    func update(_ workout: Workout, edit: (Workout) -> Void) throws {
        precondition(workout.userID == userID, "workout \(workout.workoutID) 不属于当前账号")
        edit(workout)
        workout.revision += 1
        workout.uploadState = .pending
        try context.save()
    }
}
