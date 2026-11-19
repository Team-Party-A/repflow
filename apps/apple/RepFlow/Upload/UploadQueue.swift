import Foundation
import SwiftData
import os

private let logger = Logger(subsystem: "repflow", category: "upload")

/// iOS 唯一访问训练接口的模块：按任务发 PUT / DELETE，核对回执，处理错误，更新同步状态。
/// 不改训练内容，也不推进 revision。任务一个接一个发，同一训练的任务因此不会并发。
@MainActor
final class UploadQueue: ObservableObject {
    /// 网络错误、超时、5xx 后的重试间隔：首次失败后最多再试 5 次，共等约 31 秒；
    /// 用完就标「同步失败」，等下一次触发（A2-IOS-01，由负责人确认）
    nonisolated static let defaultRetryDelays: [Duration] = [1, 2, 4, 8, 16].map { .seconds($0) }

    private let context: ModelContext
    private let api: APIClient?
    private let accounts: AccountStore
    private let retryDelays: [Duration]
    private var isRunning = false
    /// 发送途中又被触发时记下账号，这一轮结束后接着跑，保证同一时刻只有一轮在发
    private var queuedUserID: UUID?

    init(
        context: ModelContext, api: APIClient?, accounts: AccountStore,
        retryDelays: [Duration] = defaultRetryDelays
    ) {
        self.context = context
        self.api = api
        self.accounts = accounts
        self.retryDelays = retryDelays
    }

    /// 保存后、回到前台、登录成功时调用
    func sync(userID: UUID) {
        Task { await run(userID: userID) }
    }

    /// 用户点「重试」：失败和被拒收的任务放回待发，马上发一轮
    func retry(userID: UUID) async {
        for task in tasks(of: userID) where task.state != .waiting {
            task.state = .waiting
            if task.kind == .put { workout(task.workoutID, of: userID)?.uploadState = .pending }
        }
        save()
        await run(userID: userID)
    }

    func run(userID: UUID) async {
        queuedUserID = userID
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        while let next = queuedUserID {
            queuedUserID = nil
            await sendAll(of: next)
        }
    }

    /// 只发当前登录账号的任务，且只用它自己的 token；其他账号的任务留在本机，等它登录再发。
    /// 每发一个都重新检查：途中可能已退出登录，任务也可能被新版本覆盖。
    private func sendAll(of userID: UUID) async {
        guard let api else { return }
        var retries = 0
        var lastSent: SentTask?
        while accounts.current?.userID == userID, let token = accounts.token(for: userID),
            let task = nextTask(of: userID)
        {
            let sent = SentTask(task)
            // 退避次数按任务算：换了任务（前一个被拒收或被新版本覆盖）就重新计，
            // 否则后面的任务会少试几次
            if sent != lastSent { retries = 0 }
            lastSent = sent
            switch await send(sent, api: api, token: token) {
            case .accepted:
                complete(sent)
            case .authExpired:
                logger.warning("upload unauthorized: user=\(userID), workout=\(sent.workoutID)")
                accounts.expireToken(token, for: userID)
                // 任务保持待发：同账号后面的请求也会 401，等重新登录拿到新 token 再发
                return
            case .rejected(let code):
                // 409/410/422 等：原样重发结果不会变，也不能抬高 revision 覆盖，停下等用户处理
                recordFailure(of: sent, code: code, state: .rejected)
            case .transient(let code):
                // 在途时被新版本覆盖：旧版本不用再试，也不用等，直接发新版本
                guard current(sent) != nil else { continue }
                guard retries < retryDelays.count else {
                    recordFailure(of: sent, code: code, state: .failed)
                    // 多半是网络或服务端暂时不可用，本轮不再试后面的任务
                    return
                }
                recordFailure(of: sent, code: code, state: nil)
                try? await Task.sleep(for: retryDelays[retries])
                retries += 1
            }
        }
    }

    private func send(_ sent: SentTask, api: APIClient, token: String) async -> Outcome {
        do {
            let receipt: WriteReceipt
            switch sent.kind {
            case .put:
                receipt = try await api.putWorkout(
                    sent.workoutID, body: sent.body ?? Data(), token: token)
            case .delete:
                receipt = try await api.deleteWorkout(
                    sent.workoutID, revision: sent.revision, token: token)
            }
            // 回执要对上训练 ID、revision 和操作类型，才算这个任务完成
            guard receipt.workoutID == sent.workoutID, receipt.acceptedRevision == sent.revision,
                receipt.deleted == (sent.kind == .delete)
            else { return .transient(code: "RECEIPT_MISMATCH") }
            return .accepted
        } catch APIError.unreachable {
            // 含超时。超时不代表后端没写入：重发的是同一份快照，后端按同版本同内容幂等处理
            return .transient(code: "NETWORK")
        } catch APIError.server(401, _, _), APIError.badResponse(401) {
            return .authExpired
        } catch APIError.server(let status, let code, _) {
            return (400..<500).contains(status) ? .rejected(code: code) : .transient(code: code)
        } catch APIError.badResponse(let status) {
            let code = "HTTP_\(status)"
            return (400..<500).contains(status) ? .rejected(code: code) : .transient(code: code)
        } catch {
            logger.error("upload request failed: workout=\(sent.workoutID), error=\(error)")
            return .transient(code: "UNEXPECTED")
        }
    }

    private func complete(_ sent: SentTask) {
        if let task = current(sent) { context.delete(task) }
        switch sent.kind {
        case .put:
            // 确认版本只增不减；途中改出的新版本仍待同步，由它自己的任务负责
            if let workout = workout(sent.workoutID, of: sent.userID) {
                workout.confirmedRevision = max(workout.confirmedRevision ?? 0, sent.revision)
                // 之前用完重试标过失败、后来自动触发发成功了，失败标记要撤掉
                if workout.isSynced { workout.uploadState = .pending }
            }
        case .delete:
            let workoutID = sent.workoutID
            let marker = first(
                FetchDescriptor<DeletedWorkout>(
                    predicate: #Predicate { $0.workoutID == workoutID }))
            if let marker {
                marker.confirmedRevision = max(marker.confirmedRevision ?? 0, sent.revision)
            }
        }
        save()
        logger.info(
            "upload accepted: workout=\(sent.workoutID), revision=\(sent.revision), \(sent.kind.rawValue)"
        )
    }

    /// `state` 为 nil 表示本轮还会重试，只记次数和错误码
    private func recordFailure(of sent: SentTask, code: String, state: UploadTaskState?) {
        logger.error(
            "upload failed: workout=\(sent.workoutID), revision=\(sent.revision), code=\(code)")
        // 已被新版本覆盖的旧任务不用记，新任务会自己发
        guard let task = current(sent) else { return }
        task.attemptCount += 1
        task.lastErrorCode = code
        if let state {
            task.state = state
            if sent.kind == .put { workout(sent.workoutID, of: sent.userID)?.uploadState = .failed }
        }
        save()
    }

    private func tasks(of userID: UUID) -> [UploadTask] {
        let descriptor = FetchDescriptor<UploadTask>(
            predicate: WorkoutStore.uploadTasks(of: userID), sortBy: [SortDescriptor(\.createdAt)])
        do {
            return try context.fetch(descriptor)
        } catch {
            logger.error("fetch upload tasks failed: user=\(userID), error=\(error)")
            return []
        }
    }

    /// 被拒收的任务不自动重发
    private func nextTask(of userID: UUID) -> UploadTask? {
        tasks(of: userID).first { $0.state != .rejected }
    }

    /// 发出的这一版任务如果还在（没被新版本覆盖），返回它
    private func current(_ sent: SentTask) -> UploadTask? {
        tasks(of: sent.userID).first {
            $0.workoutID == sent.workoutID && $0.revision == sent.revision && $0.kind == sent.kind
        }
    }

    private func workout(_ workoutID: UUID, of userID: UUID) -> Workout? {
        first(
            FetchDescriptor<Workout>(
                predicate: #Predicate { $0.workoutID == workoutID && $0.userID == userID }))
    }

    private func first<Model: PersistentModel>(_ descriptor: FetchDescriptor<Model>) -> Model? {
        do {
            return try context.fetch(descriptor).first
        } catch {
            logger.error("fetch \(String(describing: Model.self)) failed: error=\(error)")
            return nil
        }
    }

    private func save() {
        do {
            try context.save()
        } catch {
            logger.error("save upload state failed: error=\(error)")
        }
    }
}

/// 发出时的任务副本。在途期间任务可能被新版本覆盖，回执按这份去认领。
private struct SentTask: Equatable {
    let userID: UUID
    let workoutID: UUID
    let revision: Int32
    let kind: UploadKind
    let body: Data?

    init(_ task: UploadTask) {
        userID = task.userID
        workoutID = task.workoutID
        revision = task.revision
        kind = task.kind
        body = task.requestSnapshot
    }
}

private enum Outcome {
    case accepted
    case authExpired
    /// 4xx：原样重发不会成功
    case rejected(code: String)
    /// 网络错误、超时、5xx 等：保留任务，退避重试
    case transient(code: String)
}
