import Foundation
import CryptoKit

public enum FileHash {
    /// SHA-256 einer Datei als Hex-String (für Dedup).
    public static func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
