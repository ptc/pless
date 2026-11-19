# pless — technischer Hintergrund

Interna für Entwickler:innen. Die Roadmap mit Phasen & Fortschritt liegt in
[implementierung.md](implementierung.md), die Produktbeschreibung im [README](../README.md).

## Installation & Release

**Release (Endanwender):** `Pless-macOS.zip` (+ `.sha256` zum Prüfen) von den
[GitHub Releases](https://github.com/ptc/pless/releases/latest) laden, entpacken und
`Pless.app` nach `/Applications` kopieren. Die App ist ad-hoc signiert (kein Apple-Zertifikat),
daher meldet macOS beim ersten Start „Pless ist beschädigt“ — kein echter Schaden, einmalig
im Terminal: `xattr -cr /Applications/Pless.app` (entfernt das Quarantine-Attribut).

**Release-Prozess:** `.github/workflows/release.yml` — Tag-Push baut via `Scripts/make-app.sh`
das Bundle, packt `dist/Pless-macOS.zip` + SHA-256 und veröffentlicht beides als GitHub Release
(`gh release create` / `gh release upload --clobber`).

## Build, Run & CLI

```bash
swift build --package-path /Users/ptc/dev/ppless
swift run   --package-path /Users/ptc/dev/ppless PlessTests                # Tests (Exit-Code 0 = grün)
swift run   --package-path /Users/ptc/dev/ppless Pless                       # App (GUI)
swift run   --package-path /Users/ptc/dev/ppless Pless --vault <pfad>        # App mit anderem Vault
swift run   --package-path /Users/ptc/dev/ppless Pless mcp --vault <pfad>    # MCP-Server (stdio)
```

## Architektur

- **Swift 6, Swift Package Manager only** — kein Xcode-Projekt, keine externen Pakete.
- Logik lebt UI-frei in `Sources/PlessCore` (voll testbar ohne App); `Sources/Pless` ist
  nur App-Shell (`@main`) + CLI-Subkommandos (`mcp`).
- **SQLite direkt** via `import SQLite3` (FTS5 ist in der System-SQLite enthalten);
  `pless.db` liegt im Vault-Ordner selbst. Schema-Versionen über `PRAGMA user_version`.
- **MCP** als eigene JSON-RPC-2.0-Implementierung über stdio (protocolVersion `2025-06-18`).
- System-Frameworks: AppKit, SwiftUI, PDFKit, Vision, CryptoKit.
- Tests: MiniTest-Runner (`swift run PlessTests`, Exit-Code 0 = grün) — die
  Kommandozeilen-Toolchain liefert weder XCTest noch Swift-Testing-Makros.

## Vault-Layout

```
<vault>/                       Default ~/Documents/Pless, in Settings änderbar
├── pless.db                   SQLite: Metadaten + FTS5-Volltextindex + sync_map
├── documents/YYYY/MM/…pdf     Ablage, Dateiname nach Template {date}_{correspondent}_{title}.pdf
├── inbox/                     Import-Ordner (Watcher via DispatchSource + Poll-Fallback;
│   └── _abgelehnt/            Duplikate & unleserliche Dateien   Pfad optional änderbar)
└── thumbnails/                PNG-Cache (regenerierbar, Format-Marker gegen Orientierungswechsel)
```

## Datenbank-Schema & Migrationen

| Version | Inhalt |
|---|---|
| V1 | `documents`, `correspondents`, `categories`, `tags`, `document_tags` |
| V2 | FTS5-Volltextindex `documents_fts` (Titel, OCR-Text, Korrespondent) + Trigger |
| V3 | `sync_map(document_id, paperless_id, sha256, synced_at)` — paperless-Mapping |
| V4 | `documents.sync_state` (`synced` / `not_synced` / `unknown`), Backfill aus `sync_map` |
| V5 | `sync_map.meta_sha256` — Metadaten-Hash beim letzten Push |

## Sync nach paperless-ngx (opt-in, Phase 13)

**Grundsatz:** ohne konfigurierte paperless-URL + API-Token (UserDefaults + Keychain,
nicht in `pless.db`) wird kein Netzwerk-Call ausgeführt. „Verbindung testen“ = `GET /api/`.

- **Client:** `PaperlessClient` in PlessCore mit injizierbarem `HTTPTransport`-Protocol
  (App: URLSession, Tests: Fake). Find-or-create für Correspondents / Document Types / Tags
  (nur exakter case-insensitiver Name-Treffer zählt — nie `results.first`, sonst landet
  alles in derselben Kategorie), `post_document` (multipart), Checksum-Suche, `ping`,
  paginiertes `listNamed` (folgt `next`) für den Pull, `updateDocument` (PATCH).
- **Push (Einweg):** `SyncService` pusht alle neuen/geänderten Dokumente. Mapping:
  Korrespondent → Correspondent, Kategorie → Document Type, Tag → Tag; PDF via
  `POST /api/documents/post_document/` mit Vault-Dateinamen (→ `original_filename`),
  Titel → `title`, Datum → `created`.
- **Idempotenz:** `sync_map` + Checksum-Check `GET /api/documents/?checksum=<sha256>`.
  Datei geändert (neuer sha256) → Re-Upload; nur Metadaten geändert (`meta_sha256`
  weicht ab) → `PATCH /api/documents/<id>/` (title/created nur bei Wert, sonst 400;
  null-Referenzen leeren correspondent/document_type), kein Re-Upload.
- **Forced Sync:** `forceMetadata: true` (Dropdown am Sync-Button / Menü in den Details)
  pusht Metadaten per PATCH auch bei unverändertem Hash — z. B. um falsch gemappte
  Kategorien zu korrigieren.
- **Pull (Stammdaten):** `pullMetadata()` importiert alle Document Types als Kategorien
  und alle Correspondents als Korrespondenten (paginiert, case-insensitiv idempotent).
- **Sync-Stand pro PDF:** `documents.sync_state` (V4) als Wolken-Badge auf jeder Karte
  (oben rechts) und in den Details: `cloud.fill` grün = synced, `cloud` orange =
  not_synced (auch direkt nach Metadaten-Edit oder fehlgeschlagenem Push), Wolke+„?“
  grau = unknown (nicht konfiguriert/nie gelaufen; `cloud.questionmark` existiert nicht
  in jedem SF-Symbols-Katalog, daher komponiert).

## MCP-Protokoll

`pless mcp --vault <pfad>`: JSON-RPC 2.0, eine Nachricht pro Zeile (stdio).
Tools: `search_documents`, `get_document`, `list_documents`, `list_categories`,
`update_document` (inkl. Datei-Umbenennen), `assign_tag`, `get_stats`.
Fehler als JSON-RPC-Error (-32700/-32601/…), `notifications/initialized` ohne Antwort.

**Client-Config** (z. B. Claude Desktop; liegt auch in den App-Settings unter „MCP“ zum Kopieren):

```json
{
  "mcpServers": {
    "pless": {
      "command": "<Pfad-zum-Binary>/Pless",
      "args": ["mcp", "--vault", "/Users/ptc/Documents/Pless"]
    }
  }
}
```

## Tests

MiniTest (eigener Runner in `Sources/MiniTest`, Registrierung in `Tests/PlessTests/AllTests.swift`).
Sync-Tests mit FakeTransport (find-or-create, multipart-Payload, Idempotenz via Checksum,
PATCH, Pull, Fehlerpfade) — zuletzt 94 Tests grün.

## App-Bundle & Signing

`Scripts/make-app.sh` baut Release + `dist/Pless.app` (ad-hoc signiert via codesign,
Icon via `Scripts/make-icon.swift`). `dist/` ist gitignored. Offen: Developer-ID-Signing,
Share Extension + App Group (braucht Xcode-Projekt).

## Rechtliches & Haftung

- **Benutzung auf eigene Gefahr:** privates Projekt im frühen Entwicklungsstand (0.1.x), ohne
  jegliche Gewährleistung — weder Funktionsfähigkeit noch Datenintegrität. Vault regelmäßig
  sichern (normaler Ordner, z. B. Time Machine).
- pless ist **nicht** von paperless-ngx und wird von paperless-ngx nicht unterstützt.
  „paperless“ und „paperless-ngx“ sind Marken der jeweiligen Organisationen; pless ist ein
  unabhängiges Projekt. Der optionale Sync nutzt ausschließlich die öffentliche API von paperless-ngx.
- Lizenz: **GPL-3.0-or-later** (siehe [LICENSE](../LICENSE)); Forks sind willkommen, externe
  Commits/PRs werden nicht angenommen.

## Bekannte Einschränkungen (technisch)

- Share Extension fehlt (siehe oben); Papierkorb-UI fehlt (Soft Delete `deleted_at`
  ist im Schema vorbereitet).
- Sync ist Einweg-Push: Änderungen direkt in paperless-ngx spiegelt pless nicht zurück;
  ein remote gelöschtes Dokument wird beim nächsten Sync aber automatisch neu hochgeladen.
- OCR (Vision, on-device): Sprachen, Genauigkeit (`accurate`/`fast`), Sprachkorrektur und
  Render-Auflösung (200/300/400 dpi, Default 300) sind in den Einstellungen konfigurierbar.
- Tests via MiniTest statt XCTest/Swift Testing (CLT-Altlast).
