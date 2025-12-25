// main.swift
// ETermExtensionHost
//
// Plugin logic execution process entry point

import Foundation
import ETermKit

fputs("[ExtensionHost] Starting...\n", stderr)

// MARK: - Entry Point

/// Parse command line arguments
/// Usage: ETermExtensionHost --socket <path>
func parseArguments() -> String? {
    let args = CommandLine.arguments

    var i = 1
    while i < args.count {
        if args[i] == "--socket" && i + 1 < args.count {
            return args[i + 1]
        }
        i += 1
    }
    return nil
}

guard let socketPath = parseArguments() else {
    fputs("Usage: ETermExtensionHost --socket <path>\n", stderr)
    exit(1)
}

fputs("[ExtensionHost] Socket path: \(socketPath)\n", stderr)

// Create and run Host
fputs("[ExtensionHost] Creating host...\n", stderr)
let host = ExtensionHost(socketPath: socketPath)
fputs("[ExtensionHost] Host created, starting run loop...\n", stderr)

// Use RunLoop to keep running
Task {
    do {
        try await host.run()
    } catch {
        fputs("Extension Host error: \(error)\n", stderr)
        exit(1)
    }
}

RunLoop.main.run()
