import Foundation

/// Tag: flaches Label, mehrere pro Dokument.
public struct Tag: Identifiable, Equatable, Sendable {
    public var id: Int64?
    public var name: String
    public var color: String?

    public init(id: Int64? = nil, name: String, color: String? = nil) {
        self.id = id
        self.name = name
        self.color = color
    }
}
