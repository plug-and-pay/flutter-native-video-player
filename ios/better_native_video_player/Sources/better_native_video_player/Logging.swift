import Foundation

/// Debug-only logging for the plugin.
///
/// Replaces bare `print(...)` calls: the `@autoclosure` parameter means the
/// message — typically an interpolated string — is never even evaluated in
/// release builds, so log statements on hot paths (per-event, per-tick) cost
/// nothing in production.
@inline(__always)
func npLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    print(message())
    #endif
}
