import Foundation
import os

private let logger = Logger(subsystem: "repflow", category: "account")

/// 本机当前登录的账号。界面按 `current.userID` 读写训练；token 在 Keychain，这里只记是谁。
struct Account: Codable, Equatable {
    let userID: UUID
    let username: String
}

/// 注册、登录、退出，以及「当前登录账号」的唯一来源。
@MainActor
final class AccountStore: ObservableObject {
    @Published private(set) var current: Account?

    /// nil 表示本机构建没配后端地址
    private let api: APIClient?
    private let keychain: TokenKeychain
    private let defaults: UserDefaults
    private static let currentKey = "currentAccount"

    init(
        api: APIClient?, keychain: TokenKeychain = TokenKeychain(),
        defaults: UserDefaults = .standard
    ) {
        self.api = api
        self.keychain = keychain
        self.defaults = defaults
        // 杀掉重开不用重新登录；token 不在了（例如被系统清掉）就当未登录
        if let data = defaults.data(forKey: Self.currentKey),
            let saved = try? JSONDecoder().decode(Account.self, from: data),
            keychain.token(for: saved.userID) != nil
        {
            current = saved
        }
    }

    func register(username: String, password: String) async throws {
        try signIn(
            with: await client().register(Credentials(username: username, password: password)))
    }

    func login(username: String, password: String) async throws {
        try signIn(with: await client().login(Credentials(username: username, password: password)))
    }

    /// D-31：只清 token 和当前账号，本地训练一条不删，同账号再登录还能看到并续传。
    /// 先在本地退出再通知后端，离线或请求失败也不拦住用户（契约允许，旧 token 可能有效至到期）。
    func logout() async {
        guard let account = current else { return }
        let token = keychain.token(for: account.userID)
        keychain.delete(for: account.userID)
        defaults.removeObject(forKey: Self.currentKey)
        current = nil
        logger.info("logged out locally: user=\(account.userID)")

        guard let api, let token else { return }
        do {
            try await api.logout(token: token)
        } catch {
            logger.warning(
                "revoke token failed, kept local logout: user=\(account.userID), error=\(error)")
        }
    }

    /// 上传只能用记录归属账号的 token，不能拿当前账号的去传别人的记录
    func token(for userID: UUID) -> String? {
        keychain.token(for: userID)
    }

    /// 注册时按契约先在本地拦下必然 422 的输入，提示更具体；登录只查非空，其余由后端判定
    static func inputError(username: String, password: String, isRegistering: Bool) -> String? {
        if username.isEmpty || password.isEmpty { return "请填写用户名和密码" }
        guard isRegistering else { return nil }
        if username.wholeMatch(of: /[A-Za-z0-9_]{3,32}/) == nil {
            return "用户名需 3–32 位，只能用字母、数字和下划线"
        }
        // 契约按 Unicode 码点计长，不能用 String.count（按字形簇）
        if !(15...128).contains(password.unicodeScalars.count) { return "密码需 15–128 个字符" }
        return nil
    }

    private func client() throws -> APIClient {
        guard let api else { throw AccountError.serverNotConfigured }
        return api
    }

    private func signIn(with result: AuthResult) throws {
        try keychain.save(result.accessToken, for: result.userID)
        let account = Account(userID: result.userID, username: result.username)
        defaults.set(try JSONEncoder().encode(account), forKey: Self.currentKey)
        current = account
        logger.info("signed in: user=\(result.userID)")
    }
}

enum AccountError: Error, LocalizedError {
    case serverNotConfigured

    var errorDescription: String? {
        "未配置后端地址：在 Config/Local.xcconfig 填写 REPFLOW_API_BASE_URL 后重新构建"
    }
}
