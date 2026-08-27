//
//  Logger.swift
//  Omacy
//
//  Copyright © 2026 Guillaume Louel. Licensed under the MIT License.
//

import Foundation
import os.log

/// Logging configuration shared between the host app and the screensaver extension.
///
/// Open Console.app and filter by:
///   subsystem == "be.zenjoy.omacy"
/// to see logs from the host app and the appex extension at the same time. Every
/// log entry's category and PID make it clear which process the line came from.
enum AppexLog {
    static let subsystem = "be.zenjoy.omacy"

    static func logger(_ category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }
}
