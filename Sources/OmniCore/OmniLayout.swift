import Foundation

/// Fixed on-disk layout of the Omni Intent application and of the owner
/// control plane it fronts.
///
/// These roots are deliberately not caller- or environment-selectable: the
/// candidate envelope is the confinement boundary that isolated candidates,
/// development compositions, packaging and verification are allowed to write
/// into, so it must stay a compile-time constant. Everything else the runtime
/// may reach (installed roots, the Tooling control plane) is enumerated
/// separately and stays forbidden.
///
/// Every path is anchored on the current user's home directory as recorded in
/// the directory service (the passwd entry), never on a literal user name and
/// never on the process environment: `$HOME` is ignored by Foundation already,
/// and `CFFIXED_USER_HOME`, which Foundation does honour, is bypassed by the
/// passwd lookup. The layout is therefore the same for any account while a
/// launch environment cannot steer it. A fork that keeps a different owner
/// layout changes it here, in one place.
public enum OmniLayout {
    /// The current user's home directory, resolved from the directory service.
    public static let homeDirectory = directoryServiceHomeDirectory()

    /// Expand only the current-user `~` spelling through the trusted home.
    /// Other tilde spellings retain Foundation's existing user lookup behavior.
    public static func expandingCurrentUserTilde(_ path: String) -> String {
        if path == "~" { return homeDirectory.path }
        if path.hasPrefix("~/") { return homeDirectory.path + String(path.dropFirst()) }
        return (path as NSString).expandingTildeInPath
    }

    // MARK: Owner control plane

    /// The owner control plane: the `~/Tooling` checkout that holds the shell
    /// toolkit, capture APIs, style guides and this repository.
    public static let toolingRoot = homeDirectory
        .appendingPathComponent("Tooling", isDirectory: true)

    /// The owner knowledge graph that Base Capture and Link Collector write into.
    public static let baseRoot = homeDirectory
        .appendingPathComponent("Base", isDirectory: true)

    /// The personal task ledger's capture file (`ledger add` appends here).
    public static let ledgerCapture = homeDirectory
        .appendingPathComponent(".ledger/capture.txt", isDirectory: false)

    /// The office reminder queue, an append-only Markdown list.
    public static let officeQueue = toolingRoot
        .appendingPathComponent("office/QUEUE.md", isDirectory: false)

    /// Shell toolkit helpers the resident host may launch by script name.
    public static let shellToolkitBin = toolingRoot
        .appendingPathComponent("shell-toolkit/bin", isDirectory: true)

    /// The ledger CLI the owner adapters invoke for exact appends.
    public static let ledgerScript = shellToolkitBin
        .appendingPathComponent("ledger.py", isDirectory: false)

    /// The Python runtime that carries the owner capture APIs. It is the only
    /// executable the bounded owner process runner is allowed to spawn.
    public static let ownerPython = toolingRoot
        .appendingPathComponent("base-capture/.venv/bin/python", isDirectory: false)

    /// Adopted writing style guides pinned by the `/email` composer.
    public static let styleguideRoot = toolingRoot
        .appendingPathComponent("styleguide", isDirectory: true)

    // MARK: This repository

    /// Source repository: documentation, frozen contracts, scripts and tests.
    public static let repositoryRoot = toolingRoot
        .appendingPathComponent("apps/omni-intent", isDirectory: true)

    /// The hash-pinned Phase 1 freeze root verified by `Scripts/verify_phase1_contracts.sh`.
    public static let phase1ContractsRoot = repositoryRoot
        .appendingPathComponent("contracts/phase-1", isDirectory: true)

    /// Replica-confined owner bridge used by the development adapters.
    public static let ownerBridgeScript = repositoryRoot
        .appendingPathComponent("Scripts/omni_owner_bridge.py", isDirectory: false)

    /// Exact installed owner bridge; deliberately separate from the replica bridge.
    public static let installedOwnerBridgeScript = repositoryRoot
        .appendingPathComponent("Scripts/omni_installed_owner_bridge.py", isDirectory: false)

    // MARK: Application state

    /// The only home-directory subtree isolated candidates, development
    /// compositions, packaging and verification may write. Support roots live
    /// directly below it and must stay short: the candidate socket
    /// `<support>/hyper-overlay.sock` is bound by the macOS `sun_path` limit.
    ///
    /// Distinct from the reserved installed-live root
    /// `~/Library/Application Support/DanielTooling/omni-intent`, which remains
    /// forbidden to every candidate.
    public static let candidateEnvelope = homeDirectory
        .appendingPathComponent("Library/Application Support/OmniIntent", isDirectory: true)

    /// Canonical everyday owner state. The explicit installed composition is
    /// the only runtime admitted here; candidate validation still rejects it.
    public static let installedRoot = homeDirectory
        .appendingPathComponent("Library/Application Support/DanielTooling/omni-intent", isDirectory: true)
}

/// Resolves the effective user's home directory from the passwd entry.
///
/// `FileManager.homeDirectoryForCurrentUser` and `NSHomeDirectory()` honour
/// `CFFIXED_USER_HOME`, so a LaunchAgent environment or a parent process could
/// redirect every owner destination and every spawned executable through them.
/// The passwd lookup cannot be redirected by the environment. Failure to
/// resolve is fatal: nothing below `OmniLayout` is trustworthy without an anchor.
/// `HyperOverlayCore.OverlayPaths` carries an identical private copy because
/// that module has no dependencies; a test asserts the two roots agree.
func directoryServiceHomeDirectory() -> URL {
    var entry = passwd()
    var result: UnsafeMutablePointer<passwd>? = nil
    let suggested = sysconf(_SC_GETPW_R_SIZE_MAX)
    var capacity = suggested > 0 ? Int(suggested) : 4096
    var status: Int32 = ERANGE
    while status == ERANGE, capacity <= 1 << 20 {
        var buffer = [CChar](repeating: 0, count: capacity)
        status = getpwuid_r(getuid(), &entry, &buffer, buffer.count, &result)
        if status == 0, result != nil, let directory = entry.pw_dir, directory.pointee != 0 {
            return URL(fileURLWithPath: String(cString: directory), isDirectory: true)
        }
        capacity *= 4
    }
    fatalError("OmniLayout: the current user's home directory could not be resolved from the directory service (getpwuid_r status \(status))")
}
