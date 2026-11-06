import AppKit

/// A real NSMenu whose action targets live exactly as long as its current items.
/// NSMenu's target and delegate references do not retain their objects.
@MainActor
final class NativeWorkspaceStatusMenu: NSMenu, NSMenuDelegate {
    var menuTargets: [NativeWorkspaceMenuTarget] = []
    private let populate: @MainActor (NSMenu) -> Void
    private let onOpen: @MainActor (NativeWorkspaceStatusMenu) -> Void

    init(title: String, populate: @escaping @MainActor (NSMenu) -> Void,
         onOpen: @escaping @MainActor (NativeWorkspaceStatusMenu) -> Void = { _ in }) {
        self.populate = populate
        self.onOpen = onOpen
        super.init(title: title)
        autoenablesItems = false
        delegate = self
        rebuild()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self else { return }
        rebuild()
        onOpen(self)
    }

    func rebuild() {
        removeAllItems()
        menuTargets.removeAll(keepingCapacity: true)
        populate(self)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
