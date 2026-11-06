import SwiftData
import XCTest

@testable import RepFlow

/// 拦下 URLSession 的请求，按测试给的处理函数回响应，不连真实后端
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLSession 把 httpBody 转成了流，这里读回来方便断言
        var request = request
        if let stream = request.httpBodyStream {
            stream.open()
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            stream.close()
            request.httpBody = body
        }
        Self.requests.append(request)
        let (status, data) = Self.handler?(request) ?? (500, Data())
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
final class AccountStoreTests: XCTestCase {
    private let userA = UUID()
    private let userB = UUID()
    private let keychain = TokenKeychain(service: "repflow.access-token.tests")
    private var defaults: UserDefaults!
    private var store: AccountStore!

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: "AccountStoreTests")
        defaults.removePersistentDomain(forName: "AccountStoreTests")
        StubURLProtocol.requests = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let api = APIClient(
            baseURL: URL(string: "https://api.example.invalid:8080")!,
            session: URLSession(configuration: configuration))
        store = AccountStore(api: api, keychain: keychain, defaults: defaults)
    }

    override func tearDown() async throws {
        keychain.delete(for: userA)
        keychain.delete(for: userB)
        StubURLProtocol.handler = nil
    }

    private static func authBody(_ userID: UUID, _ username: String, token: String) -> Data {
        Data(
            """
            {"user_id":"\(userID.uuidString.lowercased())","username":"\(username)",
             "access_token":"\(token)","token_type":"Bearer","expires_at":"2027-11-06T10:00:00Z"}
            """.utf8)
    }

    /// 按用户名决定登录成谁，退出一律 204
    private func stubServer() {
        StubURLProtocol.handler = { [userA, userB] request in
            if request.url!.path().hasSuffix("/auth/logout") { return (204, Data()) }
            let body =
                try! JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
            return body["username"] == "alice"
                ? (200, Self.authBody(userA, "alice", token: "token-a"))
                : (200, Self.authBody(userB, "bob", token: "token-b"))
        }
    }

    func testLoginSavesTokenByUserIDAndNotPassword() async throws {
        stubServer()
        try await store.login(username: "alice", password: "correct horse battery")

        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
            request.url?.absoluteString, "https://api.example.invalid:8080/api/v1/auth/login")
        let sent = try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: String]
        XCTAssertEqual(sent, ["username": "alice", "password": "correct horse battery"])

        XCTAssertEqual(store.current, Account(userID: userA, username: "alice"))
        XCTAssertEqual(keychain.token(for: userA), "token-a")
        XCTAssertNil(keychain.token(for: userB))
        // 杀掉重开仍是登录态
        let relaunched = AccountStore(api: nil, keychain: keychain, defaults: defaults)
        XCTAssertEqual(relaunched.current?.userID, userA)
        // 密码不落盘
        let persisted = "\(defaults.dictionaryRepresentation())"
        XCTAssertFalse(persisted.contains("correct horse battery"))
    }

    func testWrongPasswordShowsMessageAndStaysLoggedOut() async {
        StubURLProtocol.handler = { _ in
            (
                401,
                Data(
                    #"{"error":{"code":"INVALID_CREDENTIALS","message":"server-msg","fields":[]}}"#
                        .utf8)
            )
        }
        do {
            try await store.login(username: "alice", password: "wrong password 12345")
            XCTFail("401 应抛错")
        } catch {
            XCTAssertEqual(error.localizedDescription, "用户名或密码错误")
        }
        XCTAssertNil(store.current)
        XCTAssertNil(keychain.token(for: userA))
    }

    func testRegisterRejectsTakenUsernameAndShortPassword() async {
        XCTAssertEqual(
            AccountStore.inputError(username: "alice", password: "short", isRegistering: true),
            "密码需 15–128 个字符")
        XCTAssertEqual(
            AccountStore.inputError(
                username: "a b", password: String(repeating: "x", count: 15), isRegistering: true),
            "用户名需 3–32 位，只能用字母、数字和下划线")
        XCTAssertNil(AccountStore.inputError(username: "a", password: "b", isRegistering: false))

        StubURLProtocol.handler = { _ in
            (
                409,
                Data(
                    #"{"error":{"code":"USERNAME_TAKEN","message":"server-msg","fields":[]}}"#
                        .utf8)
            )
        }
        do {
            try await store.register(username: "alice", password: "correct horse battery")
            XCTFail("409 应抛错")
        } catch {
            XCTAssertEqual(error.localizedDescription, "用户名已被使用")
        }
        XCTAssertEqual(StubURLProtocol.requests.first?.url?.path(), "/api/v1/auth/register")
    }

    func testLogoutKeepsRecordsAndSwitchedAccountSeesOnlyItsOwn() async throws {
        stubServer()
        let container = try WorkoutStore.makeContainer(inMemory: true)
        func workouts() throws -> [Workout] {
            let userID = try XCTUnwrap(store.current?.userID)
            return try WorkoutStore(context: ModelContext(container), userID: userID).workouts()
        }

        try await store.login(username: "alice", password: "correct horse battery")
        try WorkoutStore(context: ModelContext(container), userID: userA).create(
            startedAt: Date(), timeZone: "Asia/Shanghai", origin: .phone,
            sets: [
                WorkoutSet(
                    position: 0, exerciseID: "push_up", finalRepCount: 20, recordSource: .manual)
            ])
        XCTAssertEqual(try workouts().count, 1)

        await store.logout()
        let logout = try XCTUnwrap(StubURLProtocol.requests.last)
        XCTAssertEqual(logout.url?.path(), "/api/v1/auth/logout")
        XCTAssertEqual(logout.value(forHTTPHeaderField: "Authorization"), "Bearer token-a")
        XCTAssertNil(store.current)
        XCTAssertNil(keychain.token(for: userA))

        try await store.login(username: "bob", password: "another long passphrase")
        XCTAssertEqual(store.current?.userID, userB)
        XCTAssertTrue(try workouts().isEmpty)

        // D-31：退出不删记录，A 重新登录后记录还在
        await store.logout()
        try await store.login(username: "alice", password: "correct horse battery")
        XCTAssertEqual(try workouts().map(\.userID), [userA])
    }

    func testLogoutCompletesLocallyWhenRevokeFails() async throws {
        stubServer()
        try await store.login(username: "alice", password: "correct horse battery")
        StubURLProtocol.handler = { _ in (503, Data()) }

        await store.logout()
        XCTAssertNil(store.current)
        XCTAssertNil(keychain.token(for: userA))
    }
}
