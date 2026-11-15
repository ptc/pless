import Foundation
import SQLite3

public struct SearchFilter: Sendable, Equatable {
    public var query: String?          // Volltext (FTS5), nil/leer = nur Filter
    public var tag: String?
    public var correspondent: String?
    public var category: String?
    public var fromDate: String?       // yyyy-MM-dd inklusive
    public var toDate: String?         // yyyy-MM-dd inklusive
    public var limit: Int
    public var offset: Int

    public init(query: String? = nil, tag: String? = nil, correspondent: String? = nil,
                category: String? = nil, fromDate: String? = nil, toDate: String? = nil,
                limit: Int = 50, offset: Int = 0) {
        self.query = query
        self.tag = tag
        self.correspondent = correspondent
        self.category = category
        self.fromDate = fromDate
        self.toDate = toDate
        self.limit = limit
        self.offset = offset
    }
}

public struct SearchHit: Sendable, Equatable {
    public var document: Document
    public var snippet: String         // mit «Match»-Markern (nur bei Volltext)
    public var rank: Double             // bm25 (nur bei Volltext, kleiner = besser)
}

extension Database {
    /// Roh-Query in sicheren FTS5-MATCH-Ausdruck umwandeln: `Allianz Rechnung` → `"Allianz" AND "Rechnung"`.
    public static func ftsQuery(_ raw: String) -> String? {
        let terms = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        guard !terms.isEmpty else { return nil }
        return terms.joined(separator: " AND ")
    }

    public func search(_ filter: SearchFilter) throws -> [SearchHit] {
        var clauses: [String] = ["d.deleted_at IS NULL"]
        var binds: [Bind] = []
        if let tag = filter.tag {
            clauses.append("d.id IN (SELECT dt.document_id FROM document_tags dt JOIN tags t ON t.id = dt.tag_id WHERE t.name = ?)")
            binds.append(.s(tag))
        }
        if let c = filter.correspondent {
            clauses.append("d.correspondent_id IN (SELECT id FROM correspondents WHERE name = ?)")
            binds.append(.s(c))
        }
        if let cat = filter.category {
            clauses.append("d.category_id IN (SELECT id FROM categories WHERE name = ?)")
            binds.append(.s(cat))
        }
        if let from = filter.fromDate { clauses.append("d.document_date >= ?"); binds.append(.s(from)) }
        if let to = filter.toDate { clauses.append("d.document_date <= ?"); binds.append(.s(to)) }

        let cols = "d.id, d.uuid, d.sha256, d.filename, d.relative_path, d.title, d.correspondent_id, d.category_id, d.document_date, d.added_at, d.page_count, d.ocr_text, d.ocr_done, d.needs_review, d.notes, d.deleted_at"
        let match = Self.ftsQuery(filter.query ?? "")

        let sql: String
        if match != nil {
            sql = """
            SELECT \(cols), snippet(documents_fts, 1, '«', '»', '…', 12), bm25(documents_fts)
            FROM documents_fts
            JOIN documents d ON d.id = documents_fts.rowid
            WHERE documents_fts MATCH ? AND \(clauses.joined(separator: " AND "))
            ORDER BY rank
            LIMIT ? OFFSET ?
            """
            binds = [.s(match!)] + binds + [.i(Int64(filter.limit)), .i(Int64(filter.offset))]
        } else {
            sql = "SELECT \(cols) FROM documents d WHERE \(clauses.joined(separator: " AND ")) ORDER BY d.added_at DESC, d.id DESC LIMIT ? OFFSET ?"
            binds = binds + [.i(Int64(filter.limit)), .i(Int64(filter.offset))]
        }

        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        for (i, b) in binds.enumerated() {
            switch b {
            case .s(let v): bind(stmt, Int32(i + 1), v)
            case .i(let v): bind(stmt, Int32(i + 1), v)
            }
        }
        var hits: [SearchHit] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                let doc = mapDocument(stmt)
                if match != nil {
                    hits.append(SearchHit(document: doc,
                                          snippet: colText(stmt, 16) ?? "",
                                          rank: sqlite3_column_double(stmt, 17)))
                } else {
                    hits.append(SearchHit(document: doc, snippet: "", rank: 0))
                }
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw PlessError.database("search: \(errMsg()) [\(sql.prefix(60))]")
            }
        }
        return hits
    }
}

enum Bind {
    case s(String)
    case i(Int64)
}
