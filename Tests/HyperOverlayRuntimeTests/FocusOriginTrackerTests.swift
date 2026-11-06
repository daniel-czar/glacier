import AppKit
import HyperOverlayRuntime
import Testing

@Test @MainActor func freshIntentClearsOldOriginWhenHostIsFrontmost() {
    let hostPID: pid_t = 900
    var frontmost: pid_t? = 101
    let tracker = FocusOriginTracker(frontmostProcessID: { frontmost })
    tracker.captureOrigin(excluding: hostPID)
    #expect(tracker.capturedProcessID == 101)

    frontmost = hostPID
    tracker.captureOrigin(excluding: hostPID, preserveExistingWhenExcluded: false)
    #expect(tracker.capturedProcessID == nil)
}

@Test @MainActor func freshIntentClearsOldOriginWhenNoAppIsFrontmost() {
    let hostPID: pid_t = 900
    var frontmost: pid_t? = 101
    let tracker = FocusOriginTracker(frontmostProcessID: { frontmost })
    tracker.captureOrigin(excluding: hostPID)

    frontmost = nil
    tracker.captureOrigin(excluding: hostPID, preserveExistingWhenExcluded: false)
    #expect(tracker.capturedProcessID == nil)
}

@Test @MainActor func ownSurfaceReplacementPreservesTheExternalOrigin() {
    let hostPID: pid_t = 900
    var frontmost: pid_t? = 101
    let tracker = FocusOriginTracker(frontmostProcessID: { frontmost })
    tracker.captureOrigin(excluding: hostPID)

    frontmost = hostPID
    tracker.captureOrigin(excluding: hostPID)
    #expect(tracker.capturedProcessID == 101)
}

@Test @MainActor func freshIntentReplacesAnOldOriginWithTheNewExternalApp() {
    let hostPID: pid_t = 900
    var frontmost: pid_t? = 101
    let tracker = FocusOriginTracker(frontmostProcessID: { frontmost })
    tracker.captureOrigin(excluding: hostPID)

    frontmost = 202
    tracker.captureOrigin(excluding: hostPID, preserveExistingWhenExcluded: false)
    #expect(tracker.capturedProcessID == 202)
}
