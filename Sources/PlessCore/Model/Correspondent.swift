import Foundation

/// Korrespondent: Absender/Vertragspartner, z. B. „Allianz".
public struct Correspondent: Identifiable, Equatable, Sendable {
    public var id: Int64?
    public var name: String

    public init(id: Int64? = nil, name: String) {
        self.id = id
        self.name = name
    }
}
