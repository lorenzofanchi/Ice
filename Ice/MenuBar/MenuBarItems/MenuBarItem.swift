//
//  MenuBarItem.swift
//  Ice
//

import AXSwift
import Cocoa
import os

/// A structural representation of a menu bar item.
struct MenuBarItem: CustomStringConvertible {
    /// The tag associated with this item.
    let tag: MenuBarItemTag

    /// The item's window identifier.
    let windowID: CGWindowID

    /// The identifier of the process that owns the item.
    let ownerPID: pid_t

    /// The identifier of the process that created the item.
    let sourcePID: pid_t?

    /// The item's bounds, specified in screen coordinates.
    let bounds: CGRect

    /// The item's window title.
    let title: String?

    /// A Boolean value that indicates whether the item is on screen.
    let isOnScreen: Bool

    /// A Boolean value that indicates whether this item can be moved.
    var isMovable: Bool {
        tag.isMovable
    }

    /// A Boolean value that indicates whether this item can be hidden.
    var canBeHidden: Bool {
        tag.canBeHidden
    }

    /// A Boolean value that indicates whether this item is one of Ice's
    /// control items.
    var isControlItem: Bool {
        tag.isControlItem
    }

    /// A Boolean value that indicates whether this item is a "BentoBox"
    /// item owned by the Control Center.
    var isBentoBox: Bool {
        tag.isBentoBox
    }

    /// A Boolean value that indicates whether this item is a
    /// system-created clone of an actual item, and therefore invalid
    /// for management.
    var isSystemClone: Bool {
        tag.isSystemClone
    }

    /// The application that owns the item.
    ///
    /// - Note: In macOS 26 and later, this property always returns the
    ///   Control Center. To get the actual application that created the
    ///   item, use ``sourceApplication``.
    var owningApplication: NSRunningApplication? {
        NSRunningApplication(processIdentifier: ownerPID)
    }

    /// The application that created the item.
    ///
    /// - Note: Prior to macOS 26, this property and ``owningApplication``
    ///   are functionally equivalent.
    var sourceApplication: NSRunningApplication? {
        guard let sourcePID else {
            return nil
        }
        return NSRunningApplication(processIdentifier: sourcePID)
    }

    // TODO: Generate this once, during initialization.
    /// A name associated with the item, suited for display.
    var displayName: String {
        /// Converts "UpperCamelCase" to "Title Case".
        ///
        /// Ignores cases where a single lowercase letter immediately
        /// precedes an uppercase letter (i.e. "WiFi").
        func toTitleCase<S: StringProtocol>(_ s: S) -> String {
            String(s).replacing(/([a-z]{2})([A-Z])/) { $0.output.1 + " " + $0.output.2 }
        }

        guard !isControlItem else {
            return Constants.displayName
        }

        lazy var fallbackName = "Menu Bar Item"

        guard let sourceApplication else {
            return fallbackName
        }

        lazy var sourceName = sourceApplication.localizedName ?? sourceApplication.bundleIdentifier

        guard let title else {
            return sourceName ?? fallbackName
        }

        lazy var bestName = sourceName ?? title

        guard !isBentoBox else {
            if tag == .controlCenter {
                return bestName
            }
            return title
        }

        // Most items use their computed "best name", but we handle
        // a few special cases for system items.
        let displayName = switch tag.namespace {
        case .menuBarAgent:
            title
        case .passwords, .weather, .textInputMenuAgent:
            // "PasswordsMenuBarExtra" -> "Passwords"
            // "WeatherMenu" -> "Weather"
            // "TextInputMenuAgent" -> "Text Input"
            toTitleCase(bestName.replacing(/Menu.*/, with: ""))
        case .controlCenter:
            if let match = title.prefixMatch(of: /Hearing/) {
                // Changed from "Hearing" to "Hearing_GlowE" in macOS 15.4
                toTitleCase(match.output)
            } else {
                toTitleCase(title)
            }
        case .systemUIServer:
            if let match = title.firstMatch(of: /TimeMachine/) {
                // Sonoma:  "TimeMachine.TMMenuExtraHost"
                // Sequoia: "TimeMachineMenuExtra.TMMenuExtraHost"
                // Tahoe:   "com.apple.menuextra.TimeMachine"
                toTitleCase(match.output)
            } else {
                toTitleCase(title)
            }
        default:
            bestName
        }

        // Provide some extra context if the name is just a UUID.
        if UUID(uuidString: displayName) != nil, let sourceName {
            return "\(sourceName) (\(displayName))"
        }

        return displayName
    }

    /// A textual representation of the item.
    var description: String {
        "\(displayName) (\(tag))"
    }

    /// A string to use for logging purposes.
    var logString: String {
        "<\(tag) (windowID: \(windowID))>"
    }

    /// Creates a menu bar item without checks.
    ///
    /// This initializer does not perform validity checks on its parameters.
    /// Only call it if you are certain the window is a valid menu bar item.
    private init(uncheckedItemWindow itemWindow: WindowInfo) {
        self.tag = MenuBarItemTag(uncheckedItemWindow: itemWindow)
        self.windowID = itemWindow.windowID
        self.ownerPID = itemWindow.ownerPID
        self.sourcePID = itemWindow.ownerPID
        self.bounds = itemWindow.bounds
        self.title = itemWindow.title
        self.isOnScreen = itemWindow.isOnScreen
    }

    /// Creates a menu bar item without checks.
    ///
    /// This initializer does not perform validity checks on its parameters.
    /// Only call it if you are certain the window is a valid menu bar item
    /// and the source pid belongs to the application that created it.
    @available(macOS 26.0, *)
    private init(uncheckedItemWindow itemWindow: WindowInfo, sourcePID: pid_t?) {
        self.tag = MenuBarItemTag(uncheckedItemWindow: itemWindow, sourcePID: sourcePID)
        self.windowID = itemWindow.windowID
        self.ownerPID = itemWindow.ownerPID
        self.sourcePID = sourcePID
        self.bounds = itemWindow.bounds
        self.title = itemWindow.title
        self.isOnScreen = itemWindow.isOnScreen
    }
}

// MARK: - MenuBarItem List

extension MenuBarItem {
    /// Options that specify the menu bar items in a list.
    struct ListOption: OptionSet {
        let rawValue: Int

        /// Specifies menu bar items that are currently on screen.
        static let onScreen = ListOption(rawValue: 1 << 0)

        /// Specifies menu bar items on the currently active space.
        static let activeSpace = ListOption(rawValue: 1 << 1)
    }

    /// Creates and returns a list of menu bar items windows for the given display.
    ///
    /// - Parameters:
    ///   - display: An identifier for a display. Pass `nil` to return the menu bar
    ///     item windows across all available displays.
    ///   - option: Options that filter the returned list. Pass an empty option set
    ///     to return all available menu bar item windows.
    static func getMenuBarItemWindows(on display: CGDirectDisplayID? = nil, option: ListOption) -> [WindowInfo] {
        var bridgingOption: Bridging.MenuBarWindowListOption = .itemsOnly
        var displayBoundsPredicate: (CGWindowID) -> Bool = { _ in true }

        if let display {
            bridgingOption.insert(.onScreen)
            let displayBounds = CGDisplayBounds(display)
            displayBoundsPredicate = { windowID in
                Bridging.windowIntersectsDisplayBounds(windowID, displayBounds)
            }
        } else if option.contains(.onScreen) {
            bridgingOption.insert(.onScreen)
        }
        if option.contains(.activeSpace) {
            bridgingOption.insert(.activeSpace)
        }

        return Bridging.getMenuBarWindowList(option: bridgingOption)
            .reversed().compactMap { windowID in
                guard
                    displayBoundsPredicate(windowID),
                    let window = WindowInfo(windowID: windowID)
                else {
                    return nil
                }
                return window
            }
    }

    /// Creates and returns a list of menu bar items using experimental
    /// source pid retrieval for macOS 26.
    @available(macOS 26.0, *)
    private static func getMenuBarItemsExperimental(on display: CGDirectDisplayID?, option: ListOption) async -> [MenuBarItem] {
        var items = [MenuBarItem]()
        for window in getMenuBarItemWindows(on: display, option: option) {
            let sourcePID = await MenuBarItemService.Connection.shared.sourcePID(for: window)
            let item = MenuBarItem(uncheckedItemWindow: window, sourcePID: sourcePID)
            items.append(item)
        }
        return items
    }

    /// Creates and returns a list of menu bar items, defaulting to the
    /// legacy source pid behavior, prior to macOS 26.
    private static func getMenuBarItemsLegacyMethod(on display: CGDirectDisplayID?, option: ListOption) -> [MenuBarItem] {
        getMenuBarItemWindows(on: display, option: option).map { window in
            MenuBarItem(uncheckedItemWindow: window)
        }
    }

    /// Creates and returns a list of menu bar items for the given display.
    ///
    /// - Parameters:
    ///   - display: An identifier for a display. Pass `nil` to return the menu bar
    ///     items across all available displays.
    ///   - option: Options that filter the returned list. Pass an empty option set
    ///     to return all available menu bar items.
    static func getMenuBarItems(on display: CGDirectDisplayID? = nil, option: ListOption) async -> [MenuBarItem] {
        if #available(macOS 27.0, *) {
            await getMenuBarItemsFromMenuBarAgent(on: display)
        } else if #available(macOS 26.0, *) {
            await getMenuBarItemsExperimental(on: display, option: option)
        } else {
            getMenuBarItemsLegacyMethod(on: display, option: option)
        }
    }
}

// MARK: - MenuBarAgent (macOS 27)

extension MenuBarItem {
    /// Fake window identifiers for items in macOS 27, keyed by tag.
    ///
    /// In macOS 27, menu bar items are no longer windows. They are scenes
    /// hosted by the MenuBarAgent process, so we find them through its
    /// accessibility hierarchy instead.
    // ponytail: fake IDs keep the windowID-keyed code working. Window APIs
    // (bounds, capture, events) fail for them, so moving and clicking items
    // don't work yet; those need to be rebuilt on screen coordinates.
    private static let fakeWindowIDs = OSAllocatedUnfairLock(initialState: [MenuBarItemTag: CGWindowID]())

    /// Creates a menu bar item from an item hosted by MenuBarAgent.
    private init(tag: MenuBarItemTag, title: String, agentPID: pid_t, sourcePID: pid_t, bounds: CGRect) {
        self.tag = tag
        self.windowID = Self.fakeWindowIDs.withLock { ids in
            if let id = ids[tag] {
                return id
            }
            let id = 0x8000_0000 + CGWindowID(ids.count) // Far above real window IDs.
            ids[tag] = id
            return id
        }
        self.ownerPID = agentPID
        self.sourcePID = sourcePID
        self.bounds = bounds
        self.title = title
        self.isOnScreen = true
    }

    /// Returns the frames of Ice's own status item windows that are in the
    /// menu bar, with their titles, which match the items' autosave names.
    @MainActor
    private static func iceStatusItemFrames() -> [(title: String, frame: CGRect)] {
        NSApp.windows.compactMap { window in
            // Items that aren't in the menu bar have zero-height windows.
            guard window.className == "NSStatusBarWindow", window.frame.height > 0 else {
                return nil
            }
            return (window.title, window.frame)
        }
    }

    /// Returns the identifiers of MenuBarAgent's menu bar windows for the
    /// display with the active menu bar.
    @available(macOS 27.0, *)
    static func getMenuBarAgentWindowIDs() -> [CGWindowID] {
        guard
            let displayID = Bridging.getActiveMenuBarDisplayID(),
            let agent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first,
            let windows = try? Application(agent)?.windows()
        else {
            return []
        }
        let displayOrigin = CGDisplayBounds(displayID).origin
        return windows.compactMap { window in
            let frame: CGRect? = try? window.attribute(.frame)
            var windowID: CGWindowID = 0
            guard
                frame?.origin == displayOrigin,
                _AXUIElementGetWindow(window.element, &windowID) == .success
            else {
                return nil
            }
            return windowID
        }
    }

    /// The bounds of each system item when items were last listed, keyed by
    /// accessibility identifier.
    private static let systemItemBounds = OSAllocatedUnfairLock(initialState: [String: CGRect]())

    /// Returns the bounds of the system item with the given accessibility
    /// identifier when items were last listed.
    @available(macOS 27.0, *)
    static func lastKnownBounds(ofSystemItem identifier: String) -> CGRect? {
        systemItemBounds.withLock { $0[identifier] }
    }

    /// Returns MenuBarAgent, and the accessibility elements that contain the
    /// menu bar items on the given display.
    ///
    /// Each container holds one item. System items are hosted by MenuBarAgent
    /// itself. Other items are remote elements owned by the app that created
    /// them.
    @available(macOS 27.0, *)
    private static func getMenuBarAgentContainers(on display: CGDirectDisplayID?) -> (NSRunningApplication, [UIElement])? {
        guard
            let displayID = display ?? Bridging.getActiveMenuBarDisplayID(),
            let agent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first,
            let windows = try? Application(agent)?.windows()
        else {
            return nil
        }

        let displayOrigin = CGDisplayBounds(displayID).origin

        // MenuBarAgent keeps several menu bar windows per display, and
        // we can't tell which one is showing.
        // ponytail: take the one with the most items; find the right one
        // if this picks a stale window (e.g. after switching spaces).
        let containers = windows
            .filter { window in
                let frame: CGRect? = try? window.attribute(.frame)
                return frame?.origin == displayOrigin
            }
            .map { window -> [UIElement] in (try? window.arrayAttribute(.children)) ?? [] }
            .max { $0.count < $1.count } ?? []

        return (agent, containers)
    }

    /// Presses the system item with the given accessibility identifier on
    /// the given display, as if it was clicked.
    @available(macOS 27.0, *)
    static func pressSystemItem(withIdentifier identifier: String, on display: CGDirectDisplayID?) {
        guard let (_, containers) = getMenuBarAgentContainers(on: display) else {
            return
        }
        for container in containers {
            // System items are a menu extra inside a hosting view.
            guard
                let hostingView: UIElement = (try? container.arrayAttribute(.children))?.first,
                let extra: UIElement = (try? hostingView.arrayAttribute(.children))?.first,
                (try? extra.attribute(.identifier)) as String? == identifier
            else {
                continue
            }
            try? extra.performAction(.press)
            return
        }
    }

    /// Creates and returns a list of menu bar items for the given display
    /// from MenuBarAgent's accessibility hierarchy.
    ///
    /// Only MenuBarAgent is queried. Items owned by other apps are identified
    /// by their element's pid, which doesn't message the app, so a hung app
    /// can't block us. Never read attributes of those elements.
    @available(macOS 27.0, *)
    private static func getMenuBarItemsFromMenuBarAgent(on display: CGDirectDisplayID?) async -> [MenuBarItem] {
        let iceFrames = await MainActor.run { iceStatusItemFrames() }

        guard let (agent, containers) = getMenuBarAgentContainers(on: display) else {
            return []
        }

        let placed = containers
            .compactMap { container -> (UIElement, CGRect)? in
                guard let frame: CGRect = try? container.attribute(.frame) else {
                    return nil
                }
                return (container, frame)
            }
            .sorted { $0.1.minX < $1.1.minX }

        // System items' frames leave out the padding around them, while
        // other items' frames include it. Split each gap between its two
        // neighbors so every item gets its padding, like item windows had.
        // The items at either end reuse the gap on their other side.
        let gaps = zip(placed, placed.dropFirst()).map { max($1.1.minX - $0.1.maxX, 0) / 2 }
        let padded = placed.indices.map { index in
            let left = index > 0 ? gaps[index - 1] : gaps.first ?? 0
            let right = index < gaps.count ? gaps[index] : gaps.last ?? 0
            let frame = placed[index].1
            return (
                placed[index].0,
                CGRect(x: frame.minX - left, y: frame.minY, width: frame.width + left + right, height: frame.height)
            )
        }

        let contents = padded.compactMap { container, frame -> (UIElement, CGRect, pid_t)? in
            guard
                let content: UIElement = (try? container.arrayAttribute(.children))?.first,
                let pid = try? content.pid()
            else {
                return nil
            }
            return (content, frame, pid)
        }

        // Our windows' frames lag behind when items shift, so match them to
        // our items by order, which doesn't change. Fall back to position if
        // they don't line up.
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownFrames = contents.filter { $0.2 == ownPID }.map { $0.1 }
        let sortedIceFrames = iceFrames.sorted { $0.frame.midX < $1.frame.midX }
        func autosaveName(for frame: CGRect) -> String? {
            if sortedIceFrames.count == ownFrames.count, let index = ownFrames.firstIndex(of: frame) {
                return sortedIceFrames[index].title
            }
            return iceFrames.first { (frame.minX...frame.maxX).contains($0.frame.midX) }?.title
        }

        var itemCounts = [pid_t: Int]()

        return contents
            .map { content, frame, pid in

                let tag: MenuBarItemTag
                var title: String?
                if pid == agent.processIdentifier {
                    // System items, e.g. "com.apple.menuextra.clock", inside
                    // a hosting view. The description has the name, followed
                    // by any state, e.g. "Wi‑Fi, connected, 3 bars".
                    let extra: UIElement = (try? content.arrayAttribute(.children))?.first ?? content
                    let identifier: String? = try? extra.attribute(.identifier)
                    let description: String? = try? extra.attribute(.description)
                    tag = MenuBarItemTag(namespace: .menuBarAgent, title: identifier ?? "")
                    title = description?.split(separator: ",").first.map(String.init)
                    if let identifier {
                        systemItemBounds.withLock { $0[identifier] = frame }
                    }
                } else if pid == ownPID {
                    // Our own items. Match them to our windows instead of
                    // querying our own process, which could deadlock.
                    tag = MenuBarItemTag(namespace: .ice, title: autosaveName(for: frame) ?? "")
                } else {
                    // ponytail: numbered by position, so two items from the
                    // same app swap tags if they swap places.
                    let app = NSRunningApplication(processIdentifier: pid)
                    let index = itemCounts[pid, default: 0]
                    itemCounts[pid] = index + 1
                    tag = MenuBarItemTag(
                        namespace: .optional(app?.bundleIdentifier ?? app?.localizedName),
                        title: "Item-\(index)"
                    )
                }

                return MenuBarItem(tag: tag, title: title ?? tag.title, agentPID: agent.processIdentifier, sourcePID: pid, bounds: frame)
            }
    }
}

// MARK: MenuBarItem: Equatable
extension MenuBarItem: Equatable {
    static func == (lhs: MenuBarItem, rhs: MenuBarItem) -> Bool {
        lhs.tag == rhs.tag &&
        lhs.windowID == rhs.windowID &&
        lhs.ownerPID == rhs.ownerPID &&
        lhs.sourcePID == rhs.sourcePID &&
        NSStringFromRect(lhs.bounds) == NSStringFromRect(rhs.bounds) &&
        lhs.title == rhs.title &&
        lhs.isOnScreen == rhs.isOnScreen
    }
}

// MARK: MenuBarItem: Hashable
extension MenuBarItem: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(tag)
        hasher.combine(windowID)
        hasher.combine(ownerPID)
        hasher.combine(sourcePID)
        hasher.combine(NSStringFromRect(bounds))
        hasher.combine(title)
        hasher.combine(isOnScreen)
    }
}

// MARK: - MenuBarItemTag Helper

private extension MenuBarItemTag {
    /// Creates a tag without checks.
    ///
    /// This initializer does not perform validity checks on its parameters.
    /// Only call it if you are certain the window is a valid menu bar item.
    init(uncheckedItemWindow itemWindow: WindowInfo) {
        self.namespace = Namespace(uncheckedItemWindow: itemWindow)
        self.title = itemWindow.title ?? ""
    }

    /// Creates a tag without checks.
    ///
    /// This initializer does not perform validity checks on its parameters.
    /// Only call it if you are certain the window is a valid menu bar item
    /// and the source pid belongs to the application that created it.
    @available(macOS 26.0, *)
    init(uncheckedItemWindow itemWindow: WindowInfo, sourcePID: pid_t?) {
        self.namespace = Namespace(uncheckedItemWindow: itemWindow, sourcePID: sourcePID)
        self.title = itemWindow.title ?? ""
    }
}

// MARK: - MenuBarItemTag.Namespace Helper

private extension MenuBarItemTag.Namespace {
    private static var uuidCache = [CGWindowID: UUID]()

    /// Creates a namespace without checks.
    ///
    /// This initializer does not perform validity checks on its parameters.
    /// Only call it if you are certain the window is a valid menu bar item.
    init(uncheckedItemWindow itemWindow: WindowInfo) {
        // Most apps have a bundle ID, but we should be able to handle apps
        // that don't. We should also be able to handle daemons and helpers,
        // which are more likely not to have a bundle ID.
        //
        // Use the name of the owning process as a fallback. The non-localized
        // name seems less likely to change, so let's prefer it as a (somewhat)
        // stable identifier.
        if let app = itemWindow.owningApplication {
            self = .optional(app.bundleIdentifier ?? itemWindow.ownerName ?? app.localizedName)
        } else {
            self = .optional(itemWindow.ownerName)
        }
    }

    /// Creates a namespace without checks.
    ///
    /// This initializer does not perform validity checks on its parameters.
    /// Only call it if you are certain the window is a valid menu bar item
    /// and the source pid belongs to the application that created it.
    @available(macOS 26.0, *)
    init(uncheckedItemWindow itemWindow: WindowInfo, sourcePID: pid_t?) {
        // Most apps have a bundle ID, but we should be able to handle apps
        // that don't. We should also be able to handle daemons and helpers,
        // which are more likely not to have a bundle ID.
        if let sourcePID, let app = NSRunningApplication(processIdentifier: sourcePID) {
            self = .optional(app.bundleIdentifier ?? app.localizedName)
        } else if let uuid = Self.uuidCache[itemWindow.windowID] {
            self = .uuid(uuid)
        } else {
            let uuid = UUID()
            Self.uuidCache[itemWindow.windowID] = uuid
            self = .uuid(uuid)
        }
    }
}
