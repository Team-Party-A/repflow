import Foundation
import Security

/// 按 user_id 存登录 token。每个账号一条，切换账号不覆盖别人的；密码从不落盘。
struct TokenKeychain {
    /// 测试用独立的 service，避免碰到真实登录态
    var service = "repflow.access-token"

    func save(_ token: String, for userID: UUID) throws {
        delete(for: userID)
        var query = baseQuery(userID)
        query[kSecValueData as String] = Data(token.utf8)
        // 上传可能在锁屏后进行，首次解锁后即可读；不随备份迁到其他设备
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError(operation: "add", userID: userID, status: status)
        }
    }

    func token(for userID: UUID) -> String? {
        var query = baseQuery(userID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    func delete(for userID: UUID) {
        SecItemDelete(baseQuery(userID) as CFDictionary)
    }

    private func baseQuery(_ userID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: userID.uuidString.lowercased(),
        ]
    }
}

struct KeychainError: Error, LocalizedError {
    let operation: String
    let userID: UUID
    let status: OSStatus

    var errorDescription: String? {
        "保存登录凭据失败（\(operation) user=\(userID) status=\(status)）"
    }
}
