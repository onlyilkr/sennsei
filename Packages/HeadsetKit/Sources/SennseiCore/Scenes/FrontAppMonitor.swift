import Foundation

/// Reports the bundle identifier of the frontmost app (nil when unknown) every time it changes.
///
/// Contract for implementations:
/// - Emit the current front app right after a stream is subscribed, so a scene can apply at once.
/// - `changes` must return a fresh stream on every access: `AppModel.start()` reads it again after a
///   reconnect, and an `AsyncStream` has a single consumer.
public protocol FrontAppMonitor: Sendable {
    var changes: AsyncStream<String?> { get }
}
