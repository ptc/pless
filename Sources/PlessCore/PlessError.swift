import Foundation

public enum PlessError: Error, Equatable {
    case vaultNotFound(URL)
    case io(String)
    case database(String)
    case duplicateSHA256(String)
    case notFound(String)
    case invalidDocument(String)
}
