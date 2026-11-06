import Foundation

/// 契约 `docs/api/openapi.yaml` 的 HTTP 客户端。账号接口在这里，上传（#97）复用 `send`。
struct APIClient {
    /// 只含协议、主机和端口，`/api/v1` 前缀由这里拼
    let baseURL: URL
    var session: URLSession = .shared

    /// 从 Info.plist 读后端地址；值由不入库的 Local.xcconfig 注入。没配或不是 HTTPS 时返回 nil，
    /// 不加 ATS 例外，所以明文 HTTP 地址即使放行也连不上。
    static func configured(bundle: Bundle = .main) -> APIClient? {
        guard let raw = bundle.object(forInfoDictionaryKey: "RepFlowAPIBaseURL") as? String,
            let url = URL(string: raw), url.scheme == "https", url.host() != nil
        else { return nil }
        return APIClient(baseURL: url)
    }

    func register(_ credentials: Credentials) async throws -> AuthResult {
        try decode(await send("auth/register", body: try JSONEncoder().encode(credentials)))
    }

    func login(_ credentials: Credentials) async throws -> AuthResult {
        try decode(await send("auth/login", body: try JSONEncoder().encode(credentials)))
    }

    /// 只撤销当前这一个 token，其他设备的会话不受影响
    func logout(token: String) async throws {
        _ = try await send("auth/logout", token: token)
    }

    /// 发一个请求，2xx 返回正文，其余按契约错误体抛 `APIError`
    func send(
        _ path: String, method: String = "POST", token: String? = nil, body: Data? = nil
    ) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: "api/v1/" + path))
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw APIError.unreachable(error.code)
        }
        guard let http = response as? HTTPURLResponse else {
            throw APIError.badResponse(status: 0)
        }
        guard (200..<300).contains(http.statusCode) else {
            guard let body = try? JSONDecoder().decode(ErrorBody.self, from: data) else {
                throw APIError.badResponse(status: http.statusCode)
            }
            throw APIError.server(
                status: http.statusCode, code: body.error.code, message: body.error.message)
        }
        return data
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.undecodable
        }
    }
}

struct Credentials: Encodable {
    let username: String
    let password: String
}

/// 契约 AuthResult。`token_type` 恒为 Bearer、`expires_at` 客户端不用（过期由 401 发现），不解码。
struct AuthResult: Decodable {
    let userID: UUID
    let username: String
    let accessToken: String

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case username
        case accessToken = "access_token"
    }
}

private struct ErrorBody: Decodable {
    struct Detail: Decodable {
        let code: String
        let message: String
    }
    let error: Detail
}

enum APIError: Error, LocalizedError {
    case unreachable(URLError.Code)
    /// 契约错误体；`code` 是 INVALID_CREDENTIALS 之类的枚举值
    case server(status: Int, code: String, message: String)
    case badResponse(status: Int)
    /// 2xx 但正文不符合契约；成功码有 200 也有 201，不报具体状态码
    case undecodable

    var errorDescription: String? {
        switch self {
        case .unreachable:
            return "无法连接服务器，请检查网络后重试"
        case .server(_, "INVALID_CREDENTIALS", _):
            return "用户名或密码错误"
        case .server(_, "USERNAME_TAKEN", _):
            return "用户名已被使用"
        case .server(_, "INTERNAL_ERROR", _), .server(_, "SERVICE_UNAVAILABLE", _):
            return "服务暂不可用，请稍后重试"
        case .server(_, _, let message):
            // 契约保证 message 是可读中文且不含凭证，其余错误码直接展示
            return message
        case .badResponse(let status):
            return "服务器响应异常（HTTP \(status)）"
        case .undecodable:
            return "服务器响应异常，请稍后重试"
        }
    }
}
