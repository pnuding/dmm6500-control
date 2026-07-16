import SwiftUI
import AppKit

/// Without this, closing the main window leaves the app running with no
/// visible window (standard SwiftUI/AppKit default) - only quittable via
/// the Dock icon or Cmd+Q, which reads as "the window didn't actually
/// close" for a small single-purpose utility like this one. Closing the
/// last open window (main or Graph) now quits the app outright.
final class AppDelegate: NSObject, NSApplicationDelegate {
    // Set once from ContentView's .onAppear, below - not available yet at
    // AppDelegate construction time (NSApplicationDelegateAdaptor builds
    // this before the App's own @StateObject is guaranteed attached to a
    // rendered scene).
    var model: AppModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // Best-effort: release the instrument's remote-control lockout before
    // the process actually exits, so it doesn't sit there afterward still
    // reporting an active LAN session (see AppModel.releaseRemoteControl).
    // .terminateLater defers the actual quit until NSApp.reply(...) is
    // called, giving the async SCPI round-trip a chance to complete first.
    //
    // Raced against a short timeout rather than trusting
    // DeviceClient.scpi()'s own internal deadlines to bound this: if the
    // device drops offline right as the app quits, the poll loop's *own*
    // in-flight read()/measure() call can already be sitting inside
    // DeviceClient's actor-serialized lock, waiting on its receive-side
    // deadline (up to 10s, deliberately generous for slow-but-legitimate
    // replies during normal use). releaseRemoteControl() has to wait its
    // turn for that same lock before it can even attempt to send
    // anything, then potentially hit connectLocked()'s own ~4s
    // connect-attempt deadline on top of that.
    //
    // An earlier version of this raced the two with withTaskGroup +
    // cancelAll() - which does NOT work: withTaskGroup always awaits
    // *every* child task before it returns, regardless of cancelAll();
    // cancellation is only a cooperative flag, and nothing in
    // DeviceClient ever checks Task.isCancelled mid-operation. So that
    // "race" still fully waited out whichever internal timeout the slow
    // side hit - no different from not racing at all, which is exactly
    // why quitting still took ~30s against an already-dropped device.
    // The correct way to truly abandon the loser (not just cancel and
    // then wait for it anyway) is two independent, unstructured Tasks -
    // neither awaited by this function - racing via the same
    // first-one-wins ResumeGuard pattern DeviceClient.withDeadline
    // already uses internally. If releaseRemoteControl() loses the race,
    // it's simply left running in the background and discarded once the
    // process exits - there's nothing left to clean up either way.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.connected else { return .terminateNow }
        let resumeGuard = ResumeGuard()
        Task {
            await model.releaseRemoteControl()
            if resumeGuard.markIfFirst() {
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if resumeGuard.markIfFirst() {
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }
}

@main
struct DMM6500ControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .onAppear { appDelegate.model = model }
        }
        // ContentView now reports a single fixed intrinsic size via
        // .fixedSize() (its min/ideal/max all collapse to the same
        // value), so .contentSize locks the window to exactly that size -
        // no drag-resize handles do anything meaningful since there's no
        // range between min and max to resize within. This replaces an
        // earlier .contentMinSize + hardcoded minWidth approach, which
        // still let the window get resized (and stay, via AppKit's
        // frame-autosave) narrower than English text needed, let alone
        // longer locales like German.
        .windowResizability(.contentSize)

        // A real separate window (not a popover) so it can stay open
        // permanently alongside the main window while you keep working.
        Window("Graph", id: "graph") {
            GraphView()
                .environmentObject(model)
                .padding()
                .frame(minWidth: 480, minHeight: 480)
        }
    }
}
