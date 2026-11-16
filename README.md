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

`dist/` liegt nicht im git. Ad-hoc signiert — reicht lokal.
## Vault-Layout (alles liegt in einem Ordner, Default `~/Documents/Pless`)

```
<vault>/
├── pless.db                  ← SQLite: Metadaten + FTS5-Volltextindex + sync_map (paperless-ngx)
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

## Sync nach paperless-ngx (Einweg-Push, opt-in)

Opt-in-Ausnahme vom Grundsatz „keine Netzwerk-Calls“: erst aktiv, wenn in den
Settings (Cmd+,) eine **paperless-URL** + **API-Token** hinterlegt sind (Token im
Keychain, nicht in `pless.db`); „Verbindung testen“ prüft per `GET /api/`.
Ohne Konfiguration führt die App keinen einzigen Netzwerk-Call aus.

- **Push:** „Sync“-Button in der Toolbar (alle neuen/geänderten Dokumente) oder
  „Synchronisieren“ in den Details (einzeln); Fortschritt/Ergebnis in der Statusleiste
  (hochgeladen / aktualisiert / übersprungen / fehlgeschlagen). Per **Dropdown am
  Sync-Button** (Toolbar) bzw. Menü in den Details gibt es zusätzlich einen
  **erzwungenen Metadaten-Sync**: alle bereits gesyncten Dokumente bekommen
  Kategorie/Korrespondent/Tags per `PATCH` neu — auch ohne lokale Änderung
  (z. B. um falsch gemappte Kategorien zu korrigieren).
- **Mapping:** Korrespondent → paperless *Correspondent*, Kategorie → *Document
  Type*, Tag → *Tag* (jeweils find-or-create per Name, case-insensitiv); PDF via
  `POST /api/documents/post_document/` (multipart) mit Vault-Dateinamen
  (→ `original_filename`), Titel → `title`, Dokumentdatum → `created`.
- **Idempotenz:** Tabelle `sync_map(document_id, paperless_id, sha256, synced_at,
  meta_sha256)` in `pless.db` (Schema V5) + Checksum-Check
  `GET /api/documents/?checksum=<sha256>` — identische Dokumente werden übersprungen.
  Datei geändert (neuer sha256) → Re-Upload; nur Metadaten geändert (z. B. Kategorie
  nachträglich gesetzt — `meta_sha256` weicht ab) → `PATCH /api/documents/<id>/`,
  die Datei wird nicht erneut hochgeladen.
- **Sync-Stand pro PDF:** persistiert in `documents.sync_state`
  (`synced` / `not_synced` / `unknown`, Schema V4) und als Wolken-Badge auf jeder
  Karte in der Liste sowie in den Details sichtbar: `cloud.fill` grün =
  synchronisiert, `cloud` orange = Push offen (z. B. direkt nach einem Metadaten-Edit
  oder nach einem fehlgeschlagenen Push), `cloud.questionmark` grau = unbekannt
  (paperless nicht konfiguriert oder nie gelaufen).

## Bekannte Einschränkungen

- Share Extension (Apple-Teilen) fehlt noch: braucht .app-Packaging + Signing
  (Xcode-Projekt) — bis dahin landen geteilte PDFs manuell im Import-Ordner.
- Kein Papierkorb in der UI (Soft Delete `deleted_at` ist im Schema vorbereitet).
- Sync ist Einweg-Push: Änderungen, die direkt in paperless-ngx gemacht werden,
  spiegelt pless nicht zurück (ein remote gelöschtes Dokument wird beim nächsten
  Sync allerdings automatisch neu hochgeladen).
- OCR-Sprachen fest auf de/en (in Settings umschaltbar), `accurate`-Modus.
- Tests laufen mit MiniTest (CLT-Altlast); XCTest/Swift Testing optional später.

## Vorgehen

Siehe `AGENTS.md` (verbindlich) und `docs/implementierung.md` (Roadmap &
Fortschritt — fertige Features werden dort abgehakt).
