/// Everything the navigation shows, as a value: the selected tab, one stack per tab and the
/// modal stack, each modal with a stack of its own (06 §3, DECISIONS U5).
///
/// The focus rules are pure functions of this value (09 §5, 00-index §5): a screen is focused
/// when it is the top of its stack, nothing is presented over it, and (for a tab's screens) its
/// tab is selected. A screen under a sheet is unfocused, as in RN.
public struct RouterState: Sendable, Hashable {
    /// Never ``AppTab/add``.
    public var selectedTab: AppTab
    /// The stacks of the four destination tabs; a missing tab is an empty stack.
    public var paths: [AppTab: [PushEntry]]
    /// Presented sheets and covers, bottom first: sheet over sheet (Add → New container → New
    /// space), cover over sheet (Add → camera).
    public var modals: [ModalEntry]

    public init(selectedTab: AppTab = .home, paths: [AppTab: [PushEntry]] = [:], modals: [ModalEntry] = []) {
        precondition(selectedTab.isDestination, "Add is an action, never the selected tab")
        self.selectedTab = selectedTab
        self.paths = paths
        self.modals = modals
    }

    /// `tab`'s stack.
    public func path(_ tab: AppTab) -> [PushEntry] {
        paths[tab] ?? []
    }

    /// The modal presented on top, if any.
    public var topModal: ModalEntry? { modals.last }

    /// The modal with this presentation id.
    public func modal(_ id: Int) -> ModalEntry? {
        modals.first { $0.id == id }
    }

    // MARK: Focus

    /// Whether the screen at `position` is in front.
    public func isFocused(_ position: ScreenPosition) -> Bool {
        switch position {
        case .tabRoot(let tab):
            return tab == selectedTab && modals.isEmpty && path(tab).isEmpty
        case .tabPush(let tab, let index):
            return tab == selectedTab && modals.isEmpty && index >= 0 && index == path(tab).count - 1
        case .modalRoot(let level):
            return level >= 0 && level == modals.count - 1 && modals[level].path.isEmpty
        case .modalPush(let level, let index):
            guard level >= 0, level == modals.count - 1 else { return false }
            return index >= 0 && index == modals[level].path.count - 1
        }
    }

    /// Whether the screen at `address` is in front; false for a screen that is not shown.
    public func isFocused(_ address: ScreenAddress) -> Bool {
        position(of: address).map(isFocused) ?? false
    }

    /// Where the screen at `address` is, or nil when it is not shown.
    public func position(of address: ScreenAddress) -> ScreenPosition? {
        switch address {
        case .tabRoot(let tab):
            return tab.isDestination ? .tabRoot(tab) : nil
        case .push(let id):
            for tab in AppTab.destinations {
                if let index = path(tab).firstIndex(where: { $0.id == id }) { return .tabPush(tab, index: index) }
            }
            for (level, modal) in modals.enumerated() {
                if let index = modal.path.firstIndex(where: { $0.id == id }) { return .modalPush(level: level, index: index) }
            }
            return nil
        case .modal(let screenID):
            return modals.firstIndex { $0.screenID == screenID }.map { .modalRoot(level: $0) }
        }
    }

    /// The tab shell's own focus, for the shared drop-zone read and the tab bar's toast chrome
    /// (06 §7.1, §16.1): in RN, "the tab shell is the top of the root stack". Natively the tab
    /// bar stays on screen over pushed screens (per-tab stacks), so the shell counts as in front
    /// whenever no sheet or cover is presented.
    public var isTabShellFocused: Bool { modals.isEmpty }

    /// The screen in front.
    public var frontAddress: ScreenAddress {
        if let top = modals.last {
            return top.path.last?.address ?? top.address
        }
        return path(selectedTab).last?.address ?? .tabRoot(selectedTab)
    }

    /// Whether anything is pushed on the selected tab or presented over it (RN `router.canDismiss()`).
    public var canDismiss: Bool {
        !modals.isEmpty || !path(selectedTab).isEmpty
    }

    /// Every screen shown, tab roots included.
    public var addresses: Set<ScreenAddress> {
        Set(orderedAddresses)
    }

    /// Every screen shown, bottom first: each tab's root and stack in bar order, then each
    /// modal's root and stack in presentation order.
    public var orderedAddresses: [ScreenAddress] {
        var all: [ScreenAddress] = []
        for tab in AppTab.destinations {
            all.append(.tabRoot(tab))
            all += path(tab).map(\.address)
        }
        for modal in modals {
            all.append(modal.address)
            all += modal.path.map(\.address)
        }
        return all
    }

    /// The modal whose root or stack holds `address`, as an index into ``modals``.
    public func modalLevel(containing address: ScreenAddress) -> Int? {
        switch position(of: address) {
        case .modalRoot(let level)?, .modalPush(let level, _)?: level
        default: nil
        }
    }
}
