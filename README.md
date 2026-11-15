# pless

Native macOS-App für lokales Dokumentenmanagement (Paperless — aber lokal & nativ).
PDFs importieren, per On-Device-OCR indizieren, an einem Ort mit vernünftigen
Dateinamen ablegen, durchsuchen, und über **MCP** an eine lokale KI anbinden.
Kein Cloud, Single User.

## Build & Test (nur Command Line Tools nötig, kein Xcode)

```bash
swift build --package-path /Users/ptc/dev/ppless
swift run   --package-path /Users/ptc/dev/ppless PlessTests   # Tests (MiniTest-Runner, Exit-Code 0 = grün)
swift run   --package-path /Users/ptc/dev/ppless Pless          # App
swift run   --package-path /Users/ptc/dev/ppless Pless mcp      # MCP-Server (stdio)
```

## Vorgehen

Siehe `AGENTS.md` (verbindlich) und `docs/implementierung.md` (Roadmap &
Fortschritt — fertige Features werden dort abgehakt).
