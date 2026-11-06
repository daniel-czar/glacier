import AppKit

public enum AppKitTermination {
    /// terminateLater can run a nested AppKit loop inside a main-queue signal
    /// callback. The main dispatch queue cannot reenter itself to deliver a reply.
    public nonisolated static func replyAfterCleanup() {
        RunLoop.main.perform(inModes: [.common, .modalPanel]) {
            MainActor.assumeIsolated { NSApp.reply(toApplicationShouldTerminate: true) }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }
}
