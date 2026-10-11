import Foundation
import Security

nonisolated struct LicenseRecord: Codable, Sendable {
  var key: String?
  var token: String?
  var trialCreations = 0
  var pendingWorktreePaths: [UUID: String]?
}

nonisolated struct LicenseKeychain: Sendable {
  var service =
    LicenseBuild.isEnforced
    ? "app.supabit.supacode.license" : "app.supabit.supacode.license.development"

  func load() throws -> LicenseRecord {
    var query = identity
    query[kSecReturnData] = true
    query[kSecMatchLimit] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return LicenseRecord() }
    guard status == errSecSuccess, let data = result as? Data,
      let record = try? JSONDecoder().decode(LicenseRecord.self, from: data),
      record.trialCreations >= 0, record.trialCreations <= LicenseSnapshot.freeCreationLimit
    else { throw LicenseError.storageUnavailable }
    return record
  }

  func save(_ record: LicenseRecord) throws {
    let data = try JSONEncoder().encode(record)
    let attributes: [CFString: Any] = [kSecValueData: data]
    let status = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      var item = identity
      item[kSecValueData] = data
      item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
        throw LicenseError.storageUnavailable
      }
    } else if status != errSecSuccess {
      throw LicenseError.storageUnavailable
    }
  }

  private var identity: [CFString: Any] {
    [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: "license-and-trial",
      kSecAttrSynchronizable: false,
    ]
  }
}
