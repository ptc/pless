import Foundation

/// Ausgang eines einzelnen Assertion-Fehlers.
public struct TestFailure: Error, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

/// Minimales Test-Framework (CLT-kompatibel, ohne Makros).
/// Tests registrieren sich per `MiniTest.test(...)`, laufen über `MiniTest.run()`.
public enum MiniTest {
    public typealias Body = () throws -> Void
    private static var registry: [(name: String, body: Body)] = []

    public static func test(_ name: String, _ body: @escaping Body) {
        registry.append((name, body))
    }

    /// Führt alle registrierten Tests aus. Rückgabe: Anzahl fehlgeschlagener Tests.
    public static func run() -> Int32 {
        var failed: Int32 = 0
        for t in registry {
            do {
                try t.body()
                write("PASS  \(t.name)")
            } catch {
                failed += 1
                write("FAIL  \(t.name)\n      \(error)")
            }
        }
        write("== \(registry.count) Tests, \(failed) fehlgeschlagen ==")
        return failed
    }

    // MARK: - Assertions

    public static func expect(_ condition: Bool, _ message: String = "Bedingung nicht erfüllt", file: String = #fileID, line: Int = #line) throws {
        if !condition { throw TestFailure("\(file):\(line): \(message)") }
    }

    public static func expectEqual<T: Equatable>(_ actual: T, _ expected: T, file: String = #fileID, line: Int = #line) throws {
        if actual != expected {
            throw TestFailure("\(file):\(line): erwartet \(expected), erhalten \(actual)")
        }
    }

    public static func expectThrows<E: Error & Equatable>(_ expected: E, _ body: () throws -> Void, file: String = #fileID, line: Int = #line) throws {
        do {
            try body()
        } catch let error as E {
            if error == expected { return }
            throw TestFailure("\(file):\(line): erwartet \(expected), erhalten \(error)")
        } catch {
            throw TestFailure("\(file):\(line): Fehlertyp \(E.self) erwartet, erhalten \(error)")
        }
        throw TestFailure("\(file):\(line): Fehler \(expected) erwartet, aber keiner geworfen")
    }

    private static func write(_ s: String) {
        FileHandle.standardOutput.write(Data((s + "\n").utf8))
    }
}
