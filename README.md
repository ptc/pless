# pless

Native macOS-App für lokales Dokumentenmanagement — Paperless, aber lokal & nativ:
PDFs importieren, per On-Device-OCR indizieren, an einem Ort mit vernünftigen
Dateinamen ablegen, durchsuchen und über **MCP** an eine lokale KI anbinden.
Kein Cloud, Single User.

## Was pless kann

- **Import:** PDFs per Drag & Drop, über „Ablage > Importieren…“ oder automatisch aus
  dem Posteingang (`inbox/`); Duplikate werden erkannt und landen in `_abgelehnt/`.
- **OCR & Suche:** Texterkennung direkt auf dem Mac (Vision, de/en) und
  Volltextsuche über Titel, OCR-Text und Korrespondent — alles in einer lokalen Datenbank.
- **Ablage & Metadaten:** PDFs landen in `documents/YYYY/MM/` mit Namen nach Schema
  (`{date}_{correspondent}_{title}.pdf`); Titel, Datum, Korrespondent, Kategorie, Tags
  und Notizen bequem in der App bearbeiten, dazu Thumbnails und eine Detailansicht.
- **KI-Anbindung:** eigener MCP-Server über stdio — eine lokale KI kann Dokumente
  suchen/lesen, Metadaten ändern und Tags zuweisen (Config unten).
- **paperless-ngx Sync (opt-in):** auf Wunsch Push zu einer selbst gehosteten
  paperless-Instanz, inkl. Import von Kategorien/Korrespondenten aus paperless und
  Wolken-Symbol pro PDF für den Sync-Stand (grün = synchronisiert, orange = offen,
  grau = unbekannt). Technischer Hintergrund: [docs/technik.md](docs/technik.md).

## Build & Test (Xcode installiert, SwiftPM-only — kein Xcode-Projekt nötig)

```bash
swift build --package-path /Users/ptc/dev/ppless
swift run   --package-path /Users/ptc/dev/ppless PlessTests                # Tests (Exit-Code 0 = grün)
swift run   --package-path /Users/ptc/dev/ppless Pless                       # App (GUI)
swift run   --package-path /Users/ptc/dev/ppless Pless --vault <pfad>        # App mit anderem Vault
swift run   --package-path /Users/ptc/dev/ppless Pless mcp --vault <pfad>    # MCP-Server (stdio)
```

## App-Bundle (.app)

```bash
bash Scripts/make-app.sh        # Release-Build + Bundle + Signing → dist/Pless.app
open dist/Pless.app             # starten (oder nach /Applications kopieren)
```

`dist/` liegt nicht im git.

## Ablage (Vault)

Alles liegt in einem Ordner (Default `~/Documents/Pless`, in den Einstellungen änderbar):
`pless.db` (lokale Datenbank), `documents/YYYY/MM/` (die PDFs), `inbox/` (Import-Ordner),
`thumbnails/` (Cache). Details zum Layout und Schema: [docs/technik.md](docs/technik.md).

## MCP-Anbindung (lokale KI, z. B. Claude Desktop)

`pless mcp --vault <pfad>` stellt der KI Werkzeuge bereit: Dokumente suchen und lesen,
Metadaten aktualisieren, Tags zuweisen, Statistiken abrufen.

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

## Doku

- [docs/technik.md](docs/technik.md) — technischer Hintergrund: Architektur, Datenbank-Schema
  und Migrationen, Sync-Design (Push/Pull/PATCH), MCP-Protokoll, Tests, App-Bundle
- [docs/implementierung.md](docs/implementierung.md) — Roadmap & Fortschritts-Log
- `AGENTS.md` — Vorgehen & Konventionen im Repo

## Bekannte Einschränkungen

- Share Extension (Apple-Teilen) fehlt noch — geteilte PDFs landen manuell im Posteingang.
- Kein Papierkorb in der UI (Soft Delete ist im Schema vorbereitet).
- Der paperless-Sync ist ein Einweg-Push: Änderungen, die direkt in paperless-ngx
  gemacht werden, spiegelt pless nicht zurück.
- OCR-Sprachen sind de/en (in den Einstellungen umschaltbar).
