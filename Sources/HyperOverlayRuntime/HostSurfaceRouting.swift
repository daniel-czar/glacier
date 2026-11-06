import Foundation

/// The resident host's narrow routing decisions before replacing a surface.
public enum HostSurfaceRouting {
    /// Keep a captured external origin through a host-owned surface. A missing
    /// capture stays missing; the host itself must never become a paste target.
    public static func clipboardOrigin(
        explicitPID: pid_t?, explicitOrigin: Bool = false,
        omniVisible: Bool, omniOriginPID: pid_t?,
        frontmostPID: pid_t?, hostPID: pid_t = ProcessInfo.processInfo.processIdentifier
    ) -> pid_t? {
        if explicitOrigin { return explicitPID }
        if let explicitPID { return explicitPID }
        // A visible background workspace does not own the current external app.
        if let frontmostPID, frontmostPID != hostPID { return frontmostPID }
        if omniVisible { return omniOriginPID == hostPID ? nil : omniOriginPID }
        return nil
    }
}
