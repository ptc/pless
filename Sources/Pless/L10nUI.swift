import Foundation
import PlessCore

/// Globaler Lookup für UI-Strings. Sprachwechsel wird über `.id(state.language)`
/// an den View-Roots re-rendert, sodass alle T()-Aufrufe neu ausgewertet werden.
func T(_ key: String) -> String { L10n.t(key) }

/// Format-Variante für interpolierte Texte (Key mit %@ / %d-Platzhaltern).
func TF(_ key: String, _ args: CVarArg...) -> String { L10n.t(key, args) }
