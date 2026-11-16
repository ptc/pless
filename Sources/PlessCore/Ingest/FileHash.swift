import Foundation
import CryptoKit

public enum FileHash {
    /// SHA-256 einer Datei als Hex-String (für Dedup).
    public static func sha256(of url: URL) throws -> String {
        try sha256(of: Data(contentsOf: url))
    }

    /// SHA-256 beliebiger Daten als Hex-String (z. B. Metadaten-Hash für den Sync-Abgleich).
    public static func sha256(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
