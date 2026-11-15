import Foundation
import MiniTest
import PlessCore

enum VaultTests {
    static func register() {
        MiniTest.test("Vault: Ordnerstruktur wird angelegt") { try createsFolderStructure() }
        MiniTest.test("Vault: stageIntoInbox verschiebt Datei in die Inbox") { try stageIntoInboxMovesFile() }
        MiniTest.test("Vault: documentsFolder legt YYYY/MM an") { try documentsFolderCreatesYearMonth() }
        MiniTest.test("Vault: bestehender Vault ohne createIfNeeded") { try existingVaultWithoutCreate() }
        MiniTest.test("Vault: fehlender Vault wirft vaultNotFound") { try missingVaultThrows() }
        MiniTest.test("Vault: eigener Import-Ordner (inboxOverride) wird verwendet") { try inboxOverrideUsed() }
    }

    private static func inboxOverrideUsed() throws {
        let root = makeTempDir()
        let custom = makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: custom)
        }
        let vault = try Vault(root: root, inboxOverride: custom)
        try MiniTest.expectEqual(vault.inboxURL.path, custom.path)
        try MiniTest.expect(vault.rejectedURL.path.hasPrefix(custom.path), "_abgelehnt unter dem eigenen Ordner")
        try MiniTest.expect(FileManager.default.fileExists(atPath: custom.path), "eigener Ordner wurde angelegt")
        // stageIntoInbox landet im eigenen Ordner
        let src = root.appendingPathComponent("x.pdf")
        try Data("pdf".utf8).write(to: src)
        let staged = try vault.stageIntoInbox(fileAt: src)
        try MiniTest.expect(staged.path.hasPrefix(custom.path), "staging im Override: \(staged.path)")
    }

    private static func makeTempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pless-test-\(UUID().uuidString)", isDirectory: true)
    }

    private static func createsFolderStructure() throws {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = try Vault(root: root)
        let fm = FileManager.default
        try MiniTest.expect(fm.fileExists(atPath: vault.documentsURL.path))
        try MiniTest.expect(fm.fileExists(atPath: vault.inboxURL.path))
        try MiniTest.expect(fm.fileExists(atPath: vault.rejectedURL.path))
        try MiniTest.expect(fm.fileExists(atPath: vault.thumbnailsURL.path))
        try MiniTest.expectEqual(vault.databaseURL.lastPathComponent, "pless.db")
    }

    private static func stageIntoInboxMovesFile() throws {
        let root = makeTempDir()
        let srcDir = makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: srcDir)
        }
        let vault = try Vault(root: root)
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        let src = srcDir.appendingPathComponent("scan.pdf")
        try Data("dummy".utf8).write(to: src)
        let dest = try vault.stageIntoInbox(fileAt: src)
        try MiniTest.expect(FileManager.default.fileExists(atPath: dest.path))
        try MiniTest.expect(!FileManager.default.fileExists(atPath: src.path))
        try MiniTest.expectEqual(dest.deletingLastPathComponent(), vault.inboxURL)
    }

    private static func documentsFolderCreatesYearMonth() throws {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = try Vault(root: root)
        let folder = try vault.documentsFolder(year: 2026, month: 2)
        try MiniTest.expectEqual(folder.lastPathComponent, "02")
        try MiniTest.expectEqual(folder.deletingLastPathComponent().lastPathComponent, "2026")
        try MiniTest.expect(FileManager.default.fileExists(atPath: folder.path))
    }

    private static func existingVaultWithoutCreate() throws {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try Vault(root: root, createIfNeeded: false)
    }

    private static func missingVaultThrows() throws {
        let root = makeTempDir().appendingPathComponent("gibt-es-nicht")
        try MiniTest.expectThrows(PlessError.vaultNotFound(root)) {
            _ = try Vault(root: root, createIfNeeded: false)
        }
    }
}
