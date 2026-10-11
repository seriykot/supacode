import Foundation

nonisolated struct LicenseCredential: Equatable, Sendable {
  let rawValue: String
  let licenseID: String

  init?(_ value: String) {
    let value = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    let parts = value.split(separator: "-", omittingEmptySubsequences: false)
    guard
      parts.count == 3,
      parts[0] == "SUPACODE",
      parts[1].count == 26,
      parts[2].count == 26,
      let id = Self.decodeBase32(parts[1]),
      id.count == 16,
      Self.decodeBase32(parts[2])?.count == 16
    else { return nil }

    rawValue = value
    licenseID = id.map { String(format: "%02x", $0) }.joined()
  }

  private static func decodeBase32(_ value: Substring) -> [UInt8]? {
    let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8)
    var bits = 0
    var buffer: UInt64 = 0
    var decoded: [UInt8] = []

    for byte in value.utf8 {
      guard let index = alphabet.firstIndex(of: byte) else { return nil }
      buffer = (buffer << 5) | UInt64(index)
      bits += 5
      if bits >= 8 {
        bits -= 8
        decoded.append(UInt8((buffer >> UInt64(bits)) & 255))
      }
    }

    guard bits == 2, buffer & 3 == 0 else { return nil }
    return decoded
  }
}
