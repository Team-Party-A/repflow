import Foundation
import SwiftData

/// 某个登录账号看到的训练数据。切换账号就换一个 store；退出登录不删任何记录。
/// 所有改内容的写入都在这里生成上传任务，并和内容在同一次 save 里落盘。
@MainActor
struct WorkoutStore {
    let context: ModelContext
    let userID: UUID

    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        try ModelContainer(
            for: Workout.self, WorkoutSet.self, UploadTask.self, DeletedWorkout.self,
            Account.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: inMemory))
    }

    /// 按账号过滤的唯一写法；各页面的 @Query 也用它，测试经 `workouts()` 覆盖到同一个谓词
    nonisolated static func owned(by userID: UUID) -> Predicate<Workout> {
        #Predicate { $0.userID == userID }
    }

    nonisolated static func uploadTasks(of userID: UUID) -> Predicate<UploadTask> {
        #Predicate { $0.userID == userID }
    }

    func workouts() throws -> [Workout] {
        let descriptor = FetchDescriptor<Workout>(
            predicate: Self.owned(by: userID),
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
        try commit {
            context.insert(workout)
            for (index, set) in sets.enumerated() {
                set.position = index + 1
                set.workout = workout
            }
            try enqueuePut(workout)
        }
        return workout
    }

    /// 改训练内容的唯一入口：内容、新 revision 和 PUT 任务在同一次 save 里落盘。
    /// 只在内容真正改动时调用，纯同步状态不走这里。
    func update(_ workout: Workout, edit: (Workout) -> Void) throws {
        precondition(workout.userID == userID, "workout \(workout.workoutID) 不属于当前账号")
        try commit {
            edit(workout)
            workout.revision += 1
            workout.uploadState = .pending
            try enqueuePut(workout)
        }
    }

    /// 删除整次训练：删内容、写删除标记、把任务换成 DELETE，在同一次 save 里完成。
    /// 从没上传过也要发 DELETE：后端先留下删除标记，才能挡住可能已经在途的 PUT。
    func delete(_ workout: Workout) throws {
        precondition(workout.userID == userID, "workout \(workout.workoutID) 不属于当前账号")
        try commit {
            let revision = workout.revision + 1
            context.insert(
                DeletedWorkout(
                    workoutID: workout.workoutID, userID: userID, revision: revision,
                    endHandoffReceived: workout.endHandoffReceived))
            try enqueue(.delete, workoutID: workout.workoutID, revision: revision, snapshot: nil)
            context.delete(workout)
        }
    }

    /// 删除一组。契约不允许空的 sets，删的是最后一组就改为删除整次训练
    func deleteSet(_ set: WorkoutSet, of workout: Workout) throws {
        guard workout.sets.count > 1 else { return try delete(workout) }
        try update(workout) { edited in
            edited.sets.removeAll { $0.setID == set.setID }
            context.delete(set)
        }
    }

    /// 中途失败就整体回滚：context 是页面和上传队列共用的，留下半截改动会被别处的下一次
    /// save 带进库里，出现改了内容却没有任务的训练
    private func commit(_ changes: () throws -> Void) throws {
        do {
            try changes()
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    private func enqueuePut(_ workout: Workout) throws {
        try enqueue(
            .put, workoutID: workout.workoutID, revision: workout.revision,
            snapshot: Self.requestBody(of: workout))
    }

    /// 已经在途的旧请求不受覆盖影响：上传队列按 revision 认领回执，旧回执不会删掉这个新任务
    private func enqueue(
        _ kind: UploadKind, workoutID: UUID, revision: Int32, snapshot: Data?
    ) throws {
        let existing = try context.fetch(
            FetchDescriptor<UploadTask>(predicate: #Predicate { $0.workoutID == workoutID })
        ).first
        let task = existing ?? UploadTask(workoutID: workoutID, userID: userID)
        if existing == nil { context.insert(task) }
        task.kind = kind
        task.revision = revision
        task.requestSnapshot = snapshot
        task.state = .waiting
        task.attemptCount = 0
        task.lastErrorCode = nil
    }

    /// 契约 WorkoutInput。可空字段在契约里也是必填，nil 要显式写成 null，不能省略
    private static func requestBody(of workout: Workout) throws -> Data {
        func orNull(_ value: Any?) -> Any { value ?? NSNull() }
        let utc = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let body: [String: Any] = [
            "revision": workout.revision,
            "record_kind": "actual",
            "started_at": workout.startedAt.formatted(utc),
            "ended_at": orNull(workout.endedAt?.formatted(utc)),
            "time_zone": workout.timeZone,
            "sets": workout.orderedSets.map { set -> [String: Any] in
                [
                    "set_id": set.setID.uuidString.lowercased(),
                    "exercise_id": set.exerciseID,
                    "final_rep_count": set.finalRepCount,
                    "estimated_rep_count": orNull(set.estimatedRepCount),
                    "record_source": set.recordSourceRaw,
                    "weight_grams": orNull(set.weightGrams),
                ]
            },
        ]
        return try JSONSerialization.data(
            withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}
