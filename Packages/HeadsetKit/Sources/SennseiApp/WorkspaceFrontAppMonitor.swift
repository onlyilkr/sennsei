import AppKit
import SennseiCore

/// Reports the bundle identifier of the frontmost app via `NSWorkspace` activation notifications.
/// Every access of `changes` builds a fresh stream that first emits the current front app.
/// Sennsei's own bundle id is never emitted: its menu bar panel can activate the app, and that must
/// neither restore a scene nor pin a manual override to Sennsei itself.
struct WorkspaceFrontAppMonitor: FrontAppMonitor {
    var changes: AsyncStream<String?> {
        AsyncStream { continuation in
            let center = NSWorkspace.shared.notificationCenter
            let own = Bundle.main.bundleIdentifier
            // Observer first, then the current app: nothing can change in the gap unnoticed.
            let observer = center.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil
            ) { note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let id = app?.bundleIdentifier
                if id != nil, id == own { return }
                continuation.yield(id)
            }
            nonisolated(unsafe) let token = observer
            continuation.onTermination = { _ in center.removeObserver(token) }
            let current = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            if current == nil || current != own { continuation.yield(current) }
        }
    }
}
