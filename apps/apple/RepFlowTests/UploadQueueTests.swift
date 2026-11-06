import SwiftData
import XCTest

@testable import RepFlow

/// 按请求回一个对得上的 WriteReceipt，相当于后端接受了这次写入
private func accepted(_ request: URLRequest) -> (Int, Data) {
    let url = request.url!
    let isDelete = request.httpMethod == "DELETE"
    let revision: Int
    if isDelete {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        revision = Int(query[0].value!)!
    } else {
        let body = try! JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        revision = body["revision"] as! Int
    }
    let receipt: [String: Any] = [
        "workout_id": url.lastPathComponent, "accepted_revision": revision, "deleted": isDelete,
    ]
    return (200, try! JSONSerialization.data(withJSONObject: receipt))
}

private func errorBody(_ code: String) -> Data {
    Data(#"{"error":{"code":"\#(code)","message":"server-msg","fields":[]}}"#.utf8)
}

private func json(_ data: Data?) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(data)) as? [String: Any])
}

@MainActor
final class UploadQueueTests: XCTestCase {
    private let userA = UUID()
    private let userB = UUID()
    private let keychain = TokenKeychain(service: "repflow.access-token.upload-tests")
    private var accounts: AccountStore!
    private var container: ModelContainer!
    private var context: ModelContext!
    private var queue: UploadQueue!

    override func setUp() async throws {
        let defaults = UserDefaults(suiteName: "UploadQueueTests")!
        defaults.removePersistentDomain(forName: "UploadQueueTests")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let api = APIClient(
            baseURL: URL(string: "https://api.example.invalid:8080")!,
            session: URLSession(configuration: configuration))
        accounts = AccountStore(api: api, keychain: keychain, defaults: defaults)
        container = try WorkoutStore.makeContainer(inMemory: true)
        context = ModelContext(container)
        // 退避间隔注入为 0：网络类失败首发后再试 2 次，测试不用真等
        queue = UploadQueue(
            context: context, api: api, accounts: accounts, retryDelays: [.zero, .zero])
        try await signIn(userA, token: "token-a")
    }

    override func tearDown() async throws {
        keychain.delete(for: userA)
        keychain.delete(for: userB)
        StubURLProtocol.handler = nil
    }

    /// 走真实的登录流程，由 AccountStore 存 token、设当前账号
    private func signIn(_ userID: UUID, token: String) async throws {
        let body = Data(
            """
            {"user_id":"\(userID.uuidString.lowercased())","username":"alice",
             "access_token":"\(token)","token_type":"Bearer","expires_at":"2027-11-06T10:00:00Z"}
            """.utf8)
        StubURLProtocol.handler = { _ in (200, body) }
        try await accounts.login(username: "alice", password: "correct horse battery")
        StubURLProtocol.requests = []
    }

    @discardableResult
    private func createWorkout(for userID: UUID) throws -> Workout {
        try WorkoutStore(context: context, userID: userID).create(
            startedAt: Date(timeIntervalSince1970: 1_793_000_000), timeZone: "Asia/Shanghai",
            origin: .phone,
            sets: [
                WorkoutSet(
                    position: 0, exerciseID: "dumbbell_curl", finalRepCount: 10,
                    estimatedRepCount: 9, recordSource: .automatic),
                WorkoutSet(
                    position: 0, exerciseID: "push_up", finalRepCount: 20, recordSource: .manual,
                    weightGrams: 0),
            ])
    }

    private func tasks() throws -> [UploadTask] {
        try context.fetch(FetchDescriptor<UploadTask>())
    }

    func testSaveAndEditWritePutTaskWithRequestSnapshot() throws {
        let workout = try createWorkout(for: userA)

        // 训练和任务由同一次 save 落盘，另一个上下文能同时读到
        let other = ModelContext(container)
        XCTAssertEqual(try other.fetch(FetchDescriptor<Workout>()).count, 1)
        let task = try XCTUnwrap(other.fetch(FetchDescriptor<UploadTask>()).first)
        XCTAssertEqual(task.kind, .put)
        XCTAssertEqual(task.revision, 1)
        XCTAssertEqual(task.userID, userA)

        let body = try json(task.requestSnapshot)
        XCTAssertEqual(body["revision"] as? Int, 1)
        XCTAssertEqual(body["record_kind"] as? String, "actual")
        XCTAssertEqual(body["started_at"] as? String, "2026-10-26T07:33:20.000Z")
        XCTAssertEqual(body["time_zone"] as? String, "Asia/Shanghai")
        // 契约里可空字段也是必填，nil 要写成 null
        XCTAssertTrue(body["ended_at"] is NSNull)
        let sets = try XCTUnwrap(body["sets"] as? [[String: Any]])
        XCTAssertEqual(sets.map { $0["exercise_id"] as? String }, ["dumbbell_curl", "push_up"])
        XCTAssertEqual(
            sets[0]["set_id"] as? String, workout.orderedSets[0].setID.uuidString.lowercased())
        XCTAssertEqual(sets[0]["estimated_rep_count"] as? Int, 9)
        XCTAssertTrue(sets[0]["weight_grams"] is NSNull)
        XCTAssertTrue(sets[1]["estimated_rep_count"] is NSNull)
        XCTAssertEqual(sets[1]["weight_grams"] as? Int, 0)

        // 编辑：同一个任务换成新 revision 和新快照，不留两个任务
        try WorkoutStore(context: context, userID: userA).update(workout) {
            $0.orderedSets[0].finalRepCount = 12
        }
        let edited = try XCTUnwrap(tasks().first)
        XCTAssertEqual(try tasks().count, 1)
        XCTAssertEqual(edited.revision, 2)
        let editedSets = try XCTUnwrap(json(edited.requestSnapshot)["sets"] as? [[String: Any]])
        XCTAssertEqual(editedSets[0]["final_rep_count"] as? Int, 12)
    }

    func testSuccessDeletesTaskAndMarksSynced() async throws {
        let workout = try createWorkout(for: userA)
        let snapshot = try XCTUnwrap(tasks().first?.requestSnapshot)
        StubURLProtocol.handler = accepted

        await queue.run(userID: userA)

        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(
            request.url?.path(), "/api/v1/workouts/\(workout.workoutID.uuidString.lowercased())")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token-a")
        XCTAssertEqual(request.httpBody, snapshot)
        XCTAssertTrue(try tasks().isEmpty)
        XCTAssertTrue(workout.isSynced)
    }

    func testTransientFailuresKeepTaskAndResendSameSnapshot() async throws {
        let workout = try createWorkout(for: userA)
        let snapshot = try XCTUnwrap(tasks().first?.requestSnapshot)
        let responses = [
            (-1, Data()), (500, errorBody("INTERNAL_ERROR")),
            (503, errorBody("SERVICE_UNAVAILABLE")),
        ]
        StubURLProtocol.handler = { _ in responses[StubURLProtocol.requests.count - 1] }

        await queue.run(userID: userA)

        // 断网、500、503 各一次：首发加 2 次重试用完，任务保留，训练显示同步失败
        XCTAssertEqual(StubURLProtocol.requests.count, 3)
        let task = try XCTUnwrap(tasks().first)
        XCTAssertEqual(task.state, .failed)
        XCTAssertEqual(task.attemptCount, 3)
        XCTAssertEqual(task.lastErrorCode, "SERVICE_UNAVAILABLE")
        XCTAssertEqual(task.revision, 1)
        XCTAssertEqual(workout.uploadState, .failed)

        // 发的是保存时的快照：绕过 update 直接改内存里的训练，下次触发重发的内容也不变
        workout.orderedSets[0].finalRepCount = 99
        StubURLProtocol.handler = accepted
        await queue.run(userID: userA)

        XCTAssertEqual(StubURLProtocol.requests.count, 4)
        XCTAssertEqual(Set(StubURLProtocol.requests.map(\.httpBody)), Set<Data?>([snapshot]))
        XCTAssertTrue(try tasks().isEmpty)
        XCTAssertEqual(workout.confirmedRevision, 1)
        // 自动触发发成功后撤掉失败标记
        XCTAssertEqual(workout.uploadState, .pending)
    }

    func testRetriesAreCountedPerTask() async throws {
        let rejected = try createWorkout(for: userA)
        let next = try createWorkout(for: userA)
        // 前一个任务用掉 2 次重试后被拒收；后一个任务仍有完整的 2 次重试
        StubURLProtocol.handler = { request in
            let isRejected =
                request.url!.lastPathComponent == rejected.workoutID.uuidString.lowercased()
            let count = StubURLProtocol.requests.count
            if isRejected {
                return count < 3
                    ? (503, errorBody("SERVICE_UNAVAILABLE"))
                    : (409, errorBody("REVISION_CONFLICT"))
            }
            return count < 6 ? (503, errorBody("SERVICE_UNAVAILABLE")) : accepted(request)
        }

        await queue.run(userID: userA)

        XCTAssertEqual(StubURLProtocol.requests.count, 6)
        XCTAssertEqual(try tasks().map(\.workoutID), [rejected.workoutID])
        XCTAssertTrue(next.isSynced)
    }

    func testEditDuringLastRetrySendsNewRevisionInSameRound() async throws {
        let store = WorkoutStore(context: context, userID: userA)
        let workout = try createWorkout(for: userA)
        // revision 1 的最后一次重试在途时用户改了一版，这次也失败了
        StubURLProtocol.handler = { request in
            let count = StubURLProtocol.requests.count
            if count == 3 {
                DispatchQueue.main.sync {
                    MainActor.assumeIsolated { try! store.update(workout) { $0.endedAt = Date() } }
                }
            }
            return count <= 3 ? (503, errorBody("SERVICE_UNAVAILABLE")) : accepted(request)
        }

        await queue.run(userID: userA)

        // revision 2 本轮就发出，不因旧版本用完重试而停下
        let revisions = try StubURLProtocol.requests.map {
            try json($0.httpBody)["revision"] as? Int
        }
        XCTAssertEqual(revisions, [1, 1, 1, 2])
        XCTAssertTrue(workout.isSynced)
        XCTAssertTrue(try tasks().isEmpty)
    }

    func testOnlyCurrentAccountsTasksAreSentWithItsOwnToken() async throws {
        let workoutA = try createWorkout(for: userA)
        try createWorkout(for: userB)
        // 即使 B 的 token 还在钥匙串里，也不能被用来发送
        try keychain.save("token-b", for: userB)
        StubURLProtocol.handler = accepted

        await queue.run(userID: userA)
        await queue.run(userID: userB)

        XCTAssertEqual(
            StubURLProtocol.requests.map { $0.url?.lastPathComponent },
            [workoutA.workoutID.uuidString.lowercased()])
        XCTAssertEqual(
            StubURLProtocol.requests.map { $0.value(forHTTPHeaderField: "Authorization") },
            ["Bearer token-a"])
        XCTAssertEqual(try tasks().map(\.userID), [userB])
    }

    func testDeletingNeverUploadedWorkoutSendsDelete() async throws {
        let store = WorkoutStore(context: context, userID: userA)
        let workout = try createWorkout(for: userA)
        let workoutID = workout.workoutID
        try store.delete(workout)

        // 删内容、写删除标记、未发出的 PUT 换成 DELETE，revision 推进到 2
        XCTAssertTrue(try store.workouts().isEmpty)
        let marker = try XCTUnwrap(context.fetch(FetchDescriptor<DeletedWorkout>()).first)
        XCTAssertEqual(marker.workoutID, workoutID)
        XCTAssertEqual(marker.revision, 2)
        let task = try XCTUnwrap(tasks().first)
        XCTAssertEqual(try tasks().count, 1)
        XCTAssertEqual(task.kind, .delete)
        XCTAssertEqual(task.revision, 2)
        XCTAssertNil(task.requestSnapshot)

        StubURLProtocol.handler = accepted
        await queue.run(userID: userA)

        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
        XCTAssertEqual(request.httpMethod, "DELETE")
        XCTAssertEqual(request.url?.path(), "/api/v1/workouts/\(workoutID.uuidString.lowercased())")
        XCTAssertEqual(request.url?.query(), "revision=2")
        XCTAssertNil(request.httpBody)
        XCTAssertTrue(try tasks().isEmpty)
        XCTAssertEqual(marker.confirmedRevision, 2)
    }

    func testDeletingLastSetDeletesWholeWorkout() throws {
        let store = WorkoutStore(context: context, userID: userA)
        let workout = try createWorkout(for: userA)

        // 还剩一组：只是一次编辑，PUT 新版本只含剩下的组
        try store.deleteSet(workout.orderedSets[0], of: workout)
        let put = try XCTUnwrap(tasks().first)
        XCTAssertEqual(put.kind, .put)
        XCTAssertEqual(put.revision, 2)
        let sets = try XCTUnwrap(json(put.requestSnapshot)["sets"] as? [[String: Any]])
        XCTAssertEqual(sets.map { $0["exercise_id"] as? String }, ["push_up"])

        // 删最后一组：契约不允许空 sets，改为删除整次训练
        try store.deleteSet(workout.orderedSets[0], of: workout)
        let delete = try XCTUnwrap(tasks().first)
        XCTAssertEqual(try tasks().count, 1)
        XCTAssertEqual(delete.kind, .delete)
        XCTAssertEqual(delete.revision, 3)
        XCTAssertTrue(try store.workouts().isEmpty)
        XCTAssertEqual(try context.fetch(FetchDescriptor<DeletedWorkout>()).map(\.revision), [3])
    }

    func testUnauthorizedDisablesTokenAndResumesAfterSameAccountRelogin() async throws {
        let workout = try createWorkout(for: userA)
        try createWorkout(for: userA)
        StubURLProtocol.handler = { _ in (401, errorBody("AUTH_REQUIRED")) }

        await queue.run(userID: userA)

        // 停用 token 并提示重新登录，后面的任务不再带着旧 token 发
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
        XCTAssertNil(keychain.token(for: userA))
        XCTAssertTrue(accounts.isSessionExpired)
        // 不算同步失败，任务原样待发
        XCTAssertEqual(try tasks().map(\.state), [.waiting, .waiting])
        XCTAssertEqual(workout.uploadState, .pending)

        // 点「重新登录」回到登录页，同账号登录拿到新 token 后接着发
        await accounts.logout()
        try await signIn(userA, token: "token-a2")
        XCTAssertFalse(accounts.isSessionExpired)
        StubURLProtocol.handler = accepted
        await queue.run(userID: userA)

        XCTAssertEqual(
            StubURLProtocol.requests.map { $0.value(forHTTPHeaderField: "Authorization") },
            ["Bearer token-a2", "Bearer token-a2"])
        XCTAssertTrue(try tasks().isEmpty)
    }

    func testConflictDeletedAndInvalidStopWithoutBumpingRevision() async throws {
        let conflict = try createWorkout(for: userA)
        let gone = try createWorkout(for: userA)
        let invalid = try createWorkout(for: userA)
        let errors = [
            conflict.workoutID: (409, "REVISION_CONFLICT"),
            gone.workoutID: (410, "WORKOUT_DELETED"),
            invalid.workoutID: (422, "VALIDATION_ERROR"),
        ]
        StubURLProtocol.handler = { request in
            let (status, code) = errors[UUID(uuidString: request.url!.lastPathComponent)!]!
            return (status, errorBody(code))
        }

        await queue.run(userID: userA)

        // 每条只发一次：不盲目重试，revision 也不抬高去覆盖
        XCTAssertEqual(StubURLProtocol.requests.count, 3)
        XCTAssertEqual(Set(try tasks().map(\.state)), [.rejected])
        XCTAssertEqual(Set(try tasks().map(\.revision)), [1])
        XCTAssertEqual(
            Set(try tasks().compactMap(\.lastErrorCode)),
            ["REVISION_CONFLICT", "WORKOUT_DELETED", "VALIDATION_ERROR"])
        for workout in [conflict, gone, invalid] {
            XCTAssertEqual(workout.revision, 1)
            XCTAssertEqual(workout.uploadState, .failed)
        }

        // 自动触发（如回到前台）不再发被拒收的任务；用户点重试才原样重发
        await queue.run(userID: userA)
        XCTAssertEqual(StubURLProtocol.requests.count, 3)
        await queue.retry(userID: userA)
        XCTAssertEqual(StubURLProtocol.requests.count, 6)
        XCTAssertEqual(Set(try tasks().map(\.revision)), [1])

        // 422 纠正输入：内容真的改了才推进 revision，新版本自动发出
        try WorkoutStore(context: context, userID: userA).update(invalid) {
            $0.orderedSets[0].finalRepCount = 11
        }
        StubURLProtocol.handler = accepted
        await queue.run(userID: userA)
        XCTAssertEqual(StubURLProtocol.requests.count, 7)
        XCTAssertEqual(invalid.revision, 2)
        XCTAssertTrue(invalid.isSynced)
    }

    func testLateReceiptOfOldRevisionDoesNotClearNewerEdit() async throws {
        let store = WorkoutStore(context: context, userID: userA)
        let workout = try createWorkout(for: userA)
        // 第一个请求在途时用户又改了一版，之后 revision 1 的成功回执才到
        StubURLProtocol.handler = { request in
            if StubURLProtocol.requests.count == 1 {
                DispatchQueue.main.sync {
                    MainActor.assumeIsolated { try! store.update(workout) { $0.endedAt = Date() } }
                }
            }
            return accepted(request)
        }

        await queue.run(userID: userA)

        // 旧回执只推进确认版本，没有删掉 revision 2 的任务；revision 2 随后发出并确认
        let revisions = try StubURLProtocol.requests.map {
            try json($0.httpBody)["revision"] as? Int
        }
        XCTAssertEqual(revisions, [1, 2])
        XCTAssertEqual(workout.confirmedRevision, 2)
        XCTAssertTrue(workout.isSynced)
        XCTAssertTrue(try tasks().isEmpty)
    }
}
