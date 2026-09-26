//
//  main.swift
//  ShelfRow
//

import Foundation
import SwiftUI

// One binary, two ways in. Given a command it answers on the terminal and
// leaves; given anything else — including the arguments Xcode and
// LaunchServices add — it opens the window, which is what it is for.
//
// A separate tool would have had to carry its own copy of the library: the
// models, the settings, and the rules about what registering a book means. The
// two copies would have parted ways at the first change to either.
if ShelfRowCLI.isCommandLine(CommandLine.arguments) {
    // Top-level code is not on the main actor, but this is the main thread
    // before anything else exists, which is what the isolation is protecting.
    exit(MainActor.assumeIsolated { ShelfRowCLI.run() })
} else {
    ShelfRowApp.main()
}
