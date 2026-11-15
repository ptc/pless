import Foundation

public enum PlessError: Error, Equatable {
    case vaultNotFound(URL)
    case io(String)
    case database(String)
    case duplicateSHA256(String)
    case notFound(String)
    case invalidDocument(String)
}

extension PlessError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .vaultNotFound(let u): return "Vault nicht gefunden: \(u.path)"
        case .io(let m): return m
        case .database(let m): return "Datenbankfehler: \(m)"
        case .duplicateSHA256(let sha): return "Duplikat — SHA-256 bereits im Vault (\(sha.prefix(12))…)"
        case .notFound(let m): return "Nicht gefunden: \(m)"
        case .invalidDocument(let m): return "Ungültiges Dokument: \(m)"
        }
    }
}
