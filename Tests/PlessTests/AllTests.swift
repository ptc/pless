import MiniTest

/// Zentrale Registrierung aller Test-Suiten.
func registerAllTests() {
    VaultTests.register()
    DatabaseTests.register()
    NamingTests.register()
    IngestTests.register()
    OCRTests.register()
    SearchTests.register()
    ThumbnailTests.register()
    MetadataTests.register()
    InboxWatcherTests.register()
    HeuristicsTests.register()
    DateDisplayTests.register()
    RecoveryTests.register()
    MCPTests.register()
}
