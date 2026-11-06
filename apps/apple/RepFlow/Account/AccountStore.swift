import Foundation
import SwiftData
import os

private let logger = Logger(subsystem: "repflow", category: "account")

/// 注册、登录、退出，以及「当前登录账号」的唯一来源。
@MainActor
final class AccountStore: ObservableObject {
    @Published private(set) var current: Account?
    /// 当前账号的 token 在上传时被后端判定失效（401），需要重新登录才能继续同步
    @Published private(set) var isSessionExpired = false

    /// nil 表示本机构建没配后端地址
    private let api: APIClient?
    private let context: ModelContext
    private let keychain: TokenKeychain
    private let defaults: UserDefaults
    /// 最近一次登录的账号。退出不清：有 token 就是当前账号，没有就只用来预填用户名
    private static let lastUserKey = "lastUserID"

    init(
        api: APIClient?, context: ModelContext, keychain: TokenKeychain = TokenKeychain(),
        defaults: UserDefaults = .standard
    ) {
        self.api = api
        self.context = context
        self.keychain = keychain
        self.defaults = defaults
        // 杀掉重开不用重新登录；token 不在了（退出、401 或被系统清掉）就当未登录
        if let last = lastAccount(), keychain.token(for: last.userID) != nil {
            current = last
        }
    }

    /// 登录页预填用户名用
    func lastAccount() -> Account? {
        guard let raw = defaults.string(forKey: Self.lastUserKey),
            let userID = UUID(uuidString: raw)
        else { return nil }
        return try? context.fetch(
            FetchDescriptor<Account>(predicate: #Predicate { $0.userID == userID })
        ).first
    }

    func register(username: String, password: String) async throws {
        try signIn(
            with: await client().register(Credentials(username: username, password: password)))
    }

    func login(username: String, password: String) async throws {
        try signIn(with: await client().login(Credentials(username: username, password: password)))
    }

    /// D-31：只清 token，本地训练和 Account 记录一条不删，同账号再登录还能看到并续传。
    /// 先在本地退出再通知后端，离线或请求失败也不拦住用户（契约允许，旧 token 可能有效至到期）。
    func logout() async {
        guard let account = current else { return }
        let token = keychain.token(for: account.userID)
        keychain.delete(for: account.userID)
        current = nil
        isSessionExpired = false
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

    /// 上传收到 401 时调用：删掉失效的 token，免得后续请求反复带着它；记录和任务都不动，
    /// 同账号重新登录拿到新 token 后继续上传
    func expireToken(_ token: String, for userID: UUID) {
        // 请求在途时可能已经重新登录换了新 token，旧 token 的 401 不能把新的也删掉
        guard keychain.token(for: userID) == token else { return }
        keychain.delete(for: userID)
        if current?.userID == userID { isSessionExpired = true }
        logger.warning("token rejected by server, needs relogin: user=\(userID)")
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
        let userID = result.userID
        let account: Account
        if let existing = try context.fetch(
            FetchDescriptor<Account>(predicate: #Predicate { $0.userID == userID })
        ).first {
            account = existing
            account.username = result.username
        } else {
            account = Account(userID: userID, username: result.username)
            context.insert(account)
        }
        try context.save()
        defaults.set(userID.uuidString, forKey: Self.lastUserKey)
        current = account
        isSessionExpired = false
        logger.info("signed in: user=\(result.userID)")
    }
}

enum AccountError: Error, LocalizedError {
    case serverNotConfigured

    var errorDescription: String? {
        "未配置后端地址：在 Config/Local.xcconfig 填写 REPFLOW_API_BASE_URL 后重新构建"
    }
}
