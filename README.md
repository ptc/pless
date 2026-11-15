# pless

Native macOS-App für lokales Dokumentenmanagement (Paperless — aber lokal & nativ).
PDFs importieren, per On-Device-OCR indizieren, an einem Ort mit vernünftigen
Dateinamen ablegen, durchsuchen, und über **MCP** an eine lokale KI anbinden.
Kein Cloud, Single User.

## Build & Test (Xcode 27.2 installiert, SwiftPM-only — kein Xcode-Projekt nötig)

```bash
swift build --package-path /Users/ptc/dev/ppless
swift run   --package-path /Users/ptc/dev/ppless PlessTests          # Tests (MiniTest-Runner, Exit-Code 0 = grün)
swift run   --package-path /Users/ptc/dev/ppless Pless                 # App (GUI)
swift run   --package-path /Users/ptc/dev/ppless Pless --vault <pfad>  # App mit anderem Vault
swift run   --package-path /Users/ptc/dev/ppless Pless mcp --vault <pfad>  # MCP-Server (stdio)
```

## App-Bundle (.app)

```bash
bash Scripts/make-app.sh        # Release-Build + Bundle + ad-hoc-Signing → dist/Pless.app
open dist/Pless.app             # starten (oder nach /Applications kopieren)
```

`dist/` liegt nicht im git. Ad-hoc signiert — reicht lokal; für Verteilung außerhalb
dieses Macs braucht es später ein Developer-ID-Signing (Xcode-Projekt).

## Vault-Layout (alles liegt in einem Ordner, Default `~/Documents/Pless`)

```
<vault>/
├── pless.db                  ← SQLite: Metadaten + FTS5-Volltextindex
├── documents/YYYY/MM/…pdf    ← Ablage mit generiertem Namen ({date}_{correspondent}_{title}.pdf)
├── inbox/                    ← Import-Ordner (Watch via DispatchSource; Pfad in Settings änderbar)
│   └── _abgelehnt/           ← Duplikate & unleserliche Dateien
└── thumbnails/               ← Cache (regenerierbar)
```

## MCP-Anbindung (lokale KI, z. B. Claude Desktop)

`pless mcp --vault <pfad>` spricht JSON-RPC 2.0 über stdio (protocolVersion
`2025-06-18`). Tools: `search_documents`, `get_document`, `list_documents`,
`list_categories`, `update_document`, `assign_tag`, `get_stats`.

Config-Snippet (auch in den App-Settings unter „MCP“ zum Kopieren):

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

## Bekannte Einschränkungen

- Share Extension (Apple-Teilen) fehlt noch: braucht .app-Packaging + Signing
  (Xcode-Projekt) — bis dahin landen geteilte PDFs manuell im Import-Ordner.
- Kein Papierkorb in der UI (Soft Delete `deleted_at` ist im Schema vorbereitet).
- OCR-Sprachen fest auf de/en (in Settings umschaltbar), `accurate`-Modus.
- Tests laufen mit MiniTest (CLT-Altlast); XCTest/Swift Testing optional später.

## Vorgehen

Siehe `AGENTS.md` (verbindlich) und `docs/implementierung.md` (Roadmap &
Fortschritt — fertige Features werden dort abgehakt).
