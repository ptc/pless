import MiniTest

/// Zentrale Registrierung aller Test-Suiten.
func registerAllTests() {
    VaultTests.register()
    DatabaseTests.register()
    NamingTests.register()
    IngestTests.register()
}
