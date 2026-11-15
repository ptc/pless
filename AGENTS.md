# AGENTS.md — pless

## Was ist das?

pless ist eine native macOS-App (Swift 6, Swift Package Manager) für lokales
Dokumentenmanagement à la Paperless: PDF-Dokumente importieren, per On-Device-OCR
(Vision) indizieren, an einem Ort ablegen, per FTS5 durchsuchen und über MCP
(Model Context Protocol — offener Standard) an eine lokale KI anbinden.

Grundsätze: **kein Cloud, nur lokal, Single User.** Keine Netzwerk-Calls, keine
Analytics, keine externen Services.

## Umgebung & Kommandos

- Aktuell nur Command Line Tools aktiv (Swift 6.4); **Xcode wird später zu Hause installiert**. Alles läuft über SwiftPM:
  - Build: `swift build --package-path /Users/ptc/dev/ppless`
  - Tests: `swift run --package-path /Users/ptc/dev/ppless PlessTests` (MiniTest-Runner, Exit-Code 0 = grün)
  - Run: `swift run --package-path /Users/ptc/dev/ppless Pless`
  - MCP-Server (stdio): `swift run --package-path /Users/ptc/dev/ppless Pless mcp --vault <pfad>`
  - Sobald Xcode da ist: volle Toolchain ohne sudo via `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift ...` (XCTest/Swift Testing, Signing, .app-Packaging für die Share Extension). Bis dahin CLT + MiniTest.
- **Keine externen Swift-Pakete.** SQLite direkt via `import SQLite3` (FTS5 ist
  in der System-SQLite enthalten), MCP als eigene JSON-RPC-2.0-Implementierung
  über stdio.
- System-Frameworks: AppKit, SwiftUI, PDFKit, Vision, CryptoKit, SQLite3.

## Vorgehen (verbindlich für diese Repo)

1. Nächste Aufgaben kommen aus der Roadmap in `docs/implementierung.md` —
   fertige Features dort abhaken (`[x]`) und im Fortschritts-Log mit Commit eintragen.
2. Iterativ arbeiten: kleine Schritte, **kleine, häufige Commits** mit
   Conventional-Commit-Messages (`feat:`, `fix:`, `test:`, `docs:`, `chore:`).
3. **Tests gehören zu jedem Feature**: `Tests/PlessTests` (MiniTest-Runner,
   Registrierung in `AllTests.swift`). Vor jedem Commit muss
   `swift run --package-path /Users/ptc/dev/ppless PlessTests` Exit-Code 0 liefern.
   Hintergrund: CLT liefert weder XCTest noch die Swift-Testing-Makros — deshalb MiniTest.
4. Logik lebt UI-frei in `Sources/PlessCore` (voll testbar ohne App);
   `Sources/Pless` ist nur App-Shell (`@main`) + CLI-Subkommandos.
5. Plan- und Architektur-Änderungen zuerst in `docs/implementierung.md` festhalten.

## Code-Konventionen

- Swift 5 Language Mode; in `PlessCore` `public` nur wo nötig.
- Fehler als `throws` mit eigener `PlessError`-Enum.
- UI: reiner SwiftUI-Code, **keine Storyboards/Xcassets**, SF Symbols,
  Dark Mode unterstützen, schlichtes macOS-Design (Sidebar + Toolbar + Suche).
- Vault portabel halten: `pless.db` liegt **im Vault-Ordner** selbst.

## Ablage & Dateinamen

- Vault: Default `~/Documents/Pless` (in den Settings konfigurierbar).
  Layout siehe `docs/implementierung.md` (`pless.db`, `documents/YYYY/MM/`,
  `inbox/`, `thumbnails/`).
- Dateinamen-Template: `{date}_{correspondent}_{title}.pdf`, sanitized
  (keine Umlaute/Sonderzeichen-Probleme), bei Kollision `-2`, `-3`, …
