import Foundation

/// Kategorie: genau eine pro Dokument, optional hierarchisch über parentId.
public struct Category: Identifiable, Equatable, Sendable {
    public var id: Int64?
    public var name: String
    public var parentId: Int64?
    public var color: String?                 // z. B. "#FF3B30"

    public init(id: Int64? = nil, name: String, parentId: Int64? = nil, color: String? = nil) {
        self.id = id
        self.name = name
        self.parentId = parentId
        self.color = color
    }
}
