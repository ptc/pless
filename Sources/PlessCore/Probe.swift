// Compile probe: verifies the CLT SDK provides all frameworks we need.
import Foundation
import CryptoKit
import SQLite3
#if canImport(AppKit)
import AppKit
#endif
#if canImport(SwiftUI)
import SwiftUI
#endif
#if canImport(Vision)
import Vision
#endif
#if canImport(PDFKit)
import PDFKit
#endif

public enum Probe {
    public static func ok() -> String {
        var parts: [String] = []
        parts.append("crypto:ok")
        parts.append("sqlite:\(String(cString: sqlite3_libversion()))")
        #if canImport(AppKit)
        parts.append("appkit:yes")
        #endif
        #if canImport(SwiftUI)
        parts.append("swiftui:yes")
        #endif
        #if canImport(Vision)
        parts.append("vision:yes")
        #endif
        #if canImport(PDFKit)
        parts.append("pdfkit:yes")
        #endif
        return parts.joined(separator: " ")
    }
}
