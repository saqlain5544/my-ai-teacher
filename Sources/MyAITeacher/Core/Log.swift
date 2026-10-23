import Foundation
import os

/// Unified-log channels (Console.app, `log stream --predicate 'subsystem == "com.saqlain.myaiteacher"'`). Failures that the
/// app recovers from on its own (a dropped write, a cache that could not be saved) go here instead of vanishing in a `try?`.
enum Log {
    static let subsystem = "com.saqlain.myaiteacher"
    static let db = Logger(subsystem: subsystem, category: "db")
    static let agent = Logger(subsystem: subsystem, category: "agent")
    static let net = Logger(subsystem: subsystem, category: "net")
}
