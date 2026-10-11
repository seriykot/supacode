import Foundation

nonisolated struct LicenseEntitlement: Equatable, Sendable {
  enum Status: String, Codable, Sendable {
    case active
    case deactivated
    case revoked
    case transferred
  }

  let licenseID: String
  let deviceID: String
  let status: Status
  let updatesThrough: LicenseDay?
  let revision: Int
  let issuedAt: Int64
  let revocationReason: String?
}
