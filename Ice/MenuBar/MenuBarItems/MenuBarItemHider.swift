//
//  MenuBarItemHider.swift
//  Ice
//

import Cocoa
import Combine
import OSLog

/// Hides the items in hidden sections on macOS 27 and later.
///
/// macOS 27 lays out the menu bar in the MenuBarAgent process, which never
/// lets items be pushed offscreen, so expanding a control item hides nothing.
/// Instead, we use MenuBarAgent's assessment mode, which takes a list of the
/// apps and system items that may stay visible and hides everything else.
/// The restriction ends when the assertion is invalidated or Ice quits.
// ponytail: private API from MenuBarClientCore, and it works per app, not
// per item. An app with items in both a visible and a hidden section stays
// visible. Now Playing, Focus and other system items MenuBarAgent can't allow,
// and apps it can't identify (no bundle identifier, or not installed), hide
// whenever any section is hidden.
@MainActor
final class MenuBarItemHider {
    /// Numbers MenuBarAgent uses for the system items it can allow, keyed by
    /// the items' accessibility identifiers. Battery (0) is always shown.
    // ponytail: system items missing from this list can't be hidden, which
    // keeps them visible rather than lost.
    private static let systemItemNumbers: [String: Int] = [
        "com.apple.menuextra.bluetooth": 1,
        "com.apple.menuextra.clock": 2,
        "com.apple.menuextra.display": 3,
        "com.apple.menuextra.displays": 3,
        "com.apple.menuextra.textinput": 4,
        "com.apple.menuextra.keyboard": 4,
        "com.apple.menuextra.sound": 5,
        "com.apple.menuextra.wifi": 6,
        "com.apple.menuextra.screen-mirroring": 7,
        "com.apple.menuextra.controlcenter": 8,
    ]

    /// The app that shows the input menu, which MenuBarAgent allows as
    /// system item 4 rather than by its bundle identifier.
    private static let textInputMenuAgent = "com.apple.TextInputMenuAgent"

    /// All system item numbers MenuBarAgent knows about.
    private static let allSystemItemNumbers = Array(0..<64)

    /// Logger for the hider.
    private let logger = Logger(category: "MenuBarItemHider")

    /// An active assessment mode assertion, with what it allows.
    private struct Restriction {
        let assertion: NSObject
        let allowedBundles: Set<String>
        let allowedSystemItems: [Int]
        let hiddenSections: Set<MenuBarSection.Name>
    }

    /// A release that waits for control items to change before showing items.
    private var pendingRelease: Task<Void, Never>?

    /// The active restriction, if any.
    ///
    /// MenuBarAgent shows an item if any active assertion allows it, so all
    /// hidden sections share one restriction.
    private var restriction: Restriction? {
        didSet {
            restrictionDate = .now
            picture = nil
        }
    }

    /// Sections that were just shown, whose items are still fading in.
    private var fadingSections = Set<MenuBarSection.Name>()

    /// The shared app state.
    private weak var appState: AppState?

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    /// A Boolean value that indicates whether items are currently hidden.
    ///
    /// Hidden items are missing from MenuBarAgent's layout while this is
    /// `true`, so the item cache must not be updated.
    var isHiding: Bool {
        restriction != nil
    }

    /// The sections whose items are hidden, or haven't finished fading in.
    var hiddenSections: Set<MenuBarSection.Name> {
        fadingSections.union(restriction?.hiddenSections ?? [])
    }

    /// The number of operations that need every item shown, for example
    /// item moves. Items are hidden again once they've all finished.
    private var suspensionCount = 0 {
        didSet {
            update()
        }
    }

    /// A Boolean value that indicates whether every item is shown.
    var isSuspended: Bool {
        suspensionCount > 0
    }

    /// Shows every item until a matching call to ``resume()``.
    func suspend() {
        suspensionCount += 1
    }

    /// Hides items again, once every ``suspend()`` call has been matched.
    func resume() {
        suspensionCount = max(suspensionCount - 1, 0)
    }

    /// A picture of the menu bar left of the hidden section's control item,
    /// where hidden items appear.
    private struct Picture {
        let image: CGImage
        /// The pictured area, in AppKit coordinates.
        let frame: CGRect
        /// The app whose menus were in the menu bar.
        let frontmostApp: pid_t?
        let date: Date
        /// The number of items in the menu bar, if known.
        var itemCount: Int?
    }

    /// A picture taken while items were hidden, ready to cover them.
    private var picture: Picture?

    /// A Boolean value that indicates whether ``picture`` is being taken.
    private var isTakingPicture = false

    /// When the active restriction was last changed.
    private var restrictionDate = Date.distantPast

    /// MenuBarAgent's windows, which take a while to look up.
    private var agentWindowIDs = [CGDirectDisplayID: [CGWindowID]]()

    /// The window that shows ``picture`` while every item is briefly shown.
    private lazy var cover: NSWindow = {
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(NSWindow.Level.popUpMenu.rawValue - 1)
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.backgroundColor = .clear
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.contentView?.wantsLayer = true
        return window
    }()

    /// The number of operations that need ``cover``.
    private var coverCount = 0

    /// A Boolean value that indicates whether hidden items are covered.
    var isCovering: Bool {
        coverCount > 0 && cover.isVisible
    }

    /// The number of items in the menu bar when they're hidden, if known.
    private var coveredItemCount: Int?

    /// Takes a picture to cover hidden items with, if the pointer is in the
    /// menu bar, where the clock is clicked, and there's no recent one.
    @available(macOS 27.0, *)
    func preparePicture() {
        let mouseLocation = NSEvent.mouseLocation
        guard
            restriction != nil,
            NSScreen.screens.contains(where: { $0.frame.contains(mouseLocation) && mouseLocation.y >= $0.visibleFrame.maxY }),
            !isSuspended,
            !isTakingPicture,
            fadingSections.isEmpty,
            Date.now.timeIntervalSince(restrictionDate) > 1, // Items fade out.
            !isPictureUsable(picture),
            let frame = pictureFrame(),
            let screen = NSScreen.screens.first(where: { $0.frame.contains(frame) })
        else {
            return
        }
        isTakingPicture = true
        let displayID = screen.displayID
        let knownWindowIDs = agentWindowIDs[displayID]
        let frontmostApp = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let date = restrictionDate
        Task.detached { [weak self] in
            let windowIDs = knownWindowIDs ?? MenuBarItem.getMenuBarAgentWindowIDs(on: displayID)
            let image = Self.capture(frame, agentWindowIDs: windowIDs)
            let itemCount = MenuBarItem.getMenuBarAgentLayoutSignature(on: displayID).count
            await self?.finishPreparingPicture(image, frame: frame, frontmostApp: frontmostApp, itemCount: itemCount, restrictionDate: date, displayID: displayID, agentWindowIDs: windowIDs)
        }
    }

    /// Stores a picture taken by ``preparePicture()``.
    private func finishPreparingPicture(
        _ image: CGImage?,
        frame: CGRect,
        frontmostApp: pid_t?,
        itemCount: Int,
        restrictionDate date: Date,
        displayID: CGDirectDisplayID,
        agentWindowIDs windowIDs: [CGWindowID]
    ) {
        isTakingPicture = false
        agentWindowIDs[displayID] = windowIDs
        // Items may have been shown meanwhile.
        guard let image, restrictionDate == date, !isSuspended else {
            return
        }
        picture = Picture(image: image, frame: frame, frontmostApp: frontmostApp, date: .now, itemCount: itemCount)
    }

    /// Returns a Boolean value that indicates whether the given picture
    /// still shows the menu bar as it is.
    // ponytail: assumes nothing but the frontmost app changes the menu bar
    // within a few seconds. Wallpaper and appearance changes aren't caught.
    private func isPictureUsable(_ picture: Picture?) -> Bool {
        guard let picture else {
            return false
        }
        return Date.now.timeIntervalSince(picture.date) < 5 &&
            picture.frontmostApp == NSWorkspace.shared.frontmostApplication?.processIdentifier &&
            picture.frame == pictureFrame()
    }

    /// Shows every item, like ``suspend()``, beneath a picture of the menu
    /// bar as it was, so hidden items don't flash.
    @available(macOS 27.0, *)
    func suspendCovered() {
        coverCount += 1
        if coverCount == 1, isHiding, let picture = usablePicture() {
            coveredItemCount = picture.itemCount
            cover.contentView?.layer?.contents = picture.image
            cover.setFrame(picture.frame, display: false)
            cover.orderFrontRegardless()
            CATransaction.flush()
        }
        suspend()
    }

    /// Hides items again, like ``resume()``, and lifts the cover once they're
    /// hidden.
    @available(macOS 27.0, *)
    func resumeCovered() async {
        resume()
        coverCount -= 1
        guard coverCount == 0, cover.isVisible else {
            return
        }
        // MenuBarAgent shows the items well after the restriction ends, and
        // only hides them again once they've finished appearing. Wait until
        // they've come and gone, without slowing down what was opened.
        // ponytail: polls accessibility for up to 2 s. Items leave it shortly
        // after they've faded out, so the cover stays a bit longer than needed.
        let start = ContinuousClock.now
        try? await Task.sleep(for: .milliseconds(400))
        var maxCount = 0
        while ContinuousClock.now - start < .seconds(2) {
            if coverCount > 0 {
                return // Another operation took over the cover.
            }
            let count = MenuBarItem.getMenuBarAgentLayoutSignature().count
            maxCount = max(maxCount, count)
            if count < maxCount || count <= coveredItemCount ?? -1 {
                break
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard coverCount == 0 else {
            return
        }
        cover.orderOut(nil)
    }

    /// Returns the prepared picture if it's usable, or takes one.
    @available(macOS 27.0, *)
    private func usablePicture() -> Picture? {
        if isPictureUsable(picture) {
            return picture
        }
        guard
            let frame = pictureFrame(),
            let screen = NSScreen.screens.first(where: { $0.frame.contains(frame) })
        else {
            return nil
        }
        let windowIDs = agentWindowIDs[screen.displayID] ?? MenuBarItem.getMenuBarAgentWindowIDs(on: screen.displayID)
        agentWindowIDs[screen.displayID] = windowIDs
        return Self.capture(frame, agentWindowIDs: windowIDs).map { image in
            Picture(image: image, frame: frame, frontmostApp: NSWorkspace.shared.frontmostApplication?.processIdentifier, date: .now)
        }
    }

    /// Returns the area left of the hidden section's control item where
    /// hidden items appear, in AppKit coordinates.
    // ponytail: only the display the control items are on. Other displays
    // still flash the hidden items.
    private func pictureFrame() -> CGRect? {
        guard
            let appState,
            ScreenCapture.cachedCheckPermissions(),
            let controlItem = appState.menuBarManager.section(withName: .hidden)?.controlItem,
            controlItem.isAddedToMenuBar,
            let controlItemFrame = controlItem.frame,
            let screen = NSScreen.screens.first(where: { $0.frame.intersects(controlItemFrame) })
        else {
            return nil
        }
        // Generous room for every hidden item, as the empty menu bar can be
        // covered freely.
        let cache = appState.itemManager.itemCache
        let width = (cache[.hidden] + cache[.alwaysHidden]).reduce(0) { $0 + $1.bounds.width } * 1.5 + 80
        let minX = max(controlItemFrame.minX - width, screen.frame.minX)
        // Leave out the bottom of the menu bar, which items don't reach, but
        // the shadow of a window just below it does. Its shadow changes when
        // Notification Center opens.
        let menuBarHeight = WindowInfo.menuBarWindow(for: screen.displayID)?.bounds.height
            ?? screen.frame.maxY - controlItemFrame.minY
        let height = menuBarHeight - 4
        return CGRect(x: minX, y: screen.frame.maxY - height, width: controlItemFrame.minX - minX, height: height)
    }

    /// Captures the given area of the screen, in AppKit coordinates.
    private nonisolated static func capture(_ frame: CGRect, agentWindowIDs: [CGWindowID]) -> CGImage? {
        let primaryScreenHeight = CGDisplayBounds(CGMainDisplayID()).height
        let screenBounds = CGRect(
            x: frame.minX,
            y: primaryScreenHeight - frame.maxY,
            width: frame.width,
            height: frame.height
        )
        // A picture with items in it would show them.
        let items = ScreenCapture.captureWindows(with: agentWindowIDs, screenBounds: screenBounds, option: .nominalResolution)
        guard items?.isTransparent(alphaThreshold: 0.05) == true else {
            return nil
        }
        let windowIDs = agentWindowIDs + WindowInfo
            .createWindows(option: .onScreen)
            .filter { $0.bounds.intersects(screenBounds) }
            .map { $0.windowID }
        return ScreenCapture.captureWindows(with: windowIDs, screenBounds: screenBounds)
    }

    /// The progress of capturing item images before items are first hidden.
    private enum InitialCapture {
        case pending, capturing, done
    }

    /// The progress of capturing item images before items are first hidden.
    private var initialCapture = InitialCapture.pending

    /// Sets up the hider.
    func performSetup(with appState: AppState) {
        self.appState = appState

        guard
            dlopen("/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore", RTLD_NOW) != nil,
            NSClassFromString("MBAssessmentModeConfiguration") != nil,
            NSClassFromString("MBAssessmentModeAssertion") != nil
        else {
            logger.error("MenuBarClientCore is unavailable, so items can't be hidden")
            return
        }

        let stateChanges = appState.menuBarManager.sections.map { section in
            section.controlItem.$state.removeDuplicates().replace(with: ())
        }

        Publishers.MergeMany(stateChanges)
            .merge(with: appState.itemManager.$itemCache.replace(with: ()))
            .merge(with: NSWorkspace.shared.publisher(for: \.runningApplications).replace(with: ()))
            .receive(on: DispatchQueue.main) // @Published emits before the value is set.
            .sink { [weak self] in
                self?.update()
            }
            .store(in: &cancellables)
    }

    /// Hides the items in the hidden sections, and shows the rest.
    private func update() {
        guard let appState else {
            return
        }
        guard !isSuspended else {
            release()
            return
        }

        let cache = appState.itemManager.itemCache
        let hiddenNames = Set(appState.menuBarManager.sections.lazy.filter { section in
            section.name != .visible &&
            section.controlItem.isAddedToMenuBar &&
            section.controlItem.state == .hideSection
        }.map { $0.name })

        // An app or system item that also has an item in a shown section has
        // to stay visible.
        let shownItems = MenuBarSection.Name.allCases.filter { !hiddenNames.contains($0) }.flatMap { cache[$0] }
        let shownBundles = Set(shownItems.compactMap(bundleIdentifier)).union([Constants.bundleIdentifier])
        let shownSystemItems = Set(shownItems.compactMap(systemItemNumber))

        // Allow every running app except the hidden ones, so apps that launch
        // later stay visible until they're cached.
        let runningBundles = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })

        var hiddenBundles = Set<String>()
        var hiddenSystemItems = Set<Int>()
        var hiddenSections = Set<MenuBarSection.Name>()
        for name in hiddenNames {
            let bundles = Set(cache[name].compactMap(bundleIdentifier)).subtracting(shownBundles)
            let systemItems = Set(cache[name].compactMap(systemItemNumber)).subtracting(shownSystemItems)
            if !bundles.isEmpty || !systemItems.isEmpty {
                hiddenBundles.formUnion(bundles)
                hiddenSystemItems.formUnion(systemItems)
                hiddenSections.insert(name)
            }
        }

        guard !hiddenSections.isEmpty else {
            // The control items' chevrons take a moment to appear. Show the
            // items with them.
            release(after: .milliseconds(125))
            return
        }
        pendingRelease?.cancel() // Still hiding.
        pendingRelease = nil

        // Hidden items can't be captured, so capture them before hiding them
        // the first time. After that, they're captured whenever shown.
        switch initialCapture {
        case .pending:
            initialCapture = .capturing
            Task {
                await appState.imageCache.updateCacheWithoutChecks(sections: MenuBarSection.Name.allCases)
                initialCapture = .done
                update()
            }
            return
        case .capturing:
            return // Updates again when done.
        case .done:
            break
        }

        let allowedBundles = runningBundles.subtracting(hiddenBundles)
        let allowedSystemItems = Self.allSystemItemNumbers.filter { !hiddenSystemItems.contains($0) }

        if
            let restriction,
            restriction.allowedBundles == allowedBundles,
            restriction.allowedSystemItems == allowedSystemItems
        {
            return
        }

        // Sections that were hidden and now aren't fade back in.
        for name in (restriction?.hiddenSections ?? []).subtracting(hiddenSections) {
            markFading(name)
        }

        activate(allowedBundles: allowedBundles, allowedSystemItems: allowedSystemItems, hiddenSections: hiddenSections)
    }

    /// Returns the bundle identifier of the app that created the given item.
    ///
    /// Uses the identifier recorded when the item was listed. Looking up its
    /// app by pid fails once the app relaunches, which would leave the
    /// relaunched app visible.
    private func bundleIdentifier(for item: MenuBarItem) -> String? {
        guard
            item.tag.namespace != .menuBarAgent,
            case .string(let identifier) = item.tag.namespace
        else {
            return nil
        }
        return identifier
    }

    /// Returns MenuBarAgent's number for the given system item.
    private func systemItemNumber(for item: MenuBarItem) -> Int? {
        if bundleIdentifier(for: item) == Self.textInputMenuAgent {
            return 4
        }
        guard item.tag.namespace == .menuBarAgent else {
            return nil
        }
        return Self.systemItemNumbers[item.tag.title]
    }

    /// Replaces the active restriction with one that allows only the given
    /// apps and system items.
    private func activate(allowedBundles: Set<String>, allowedSystemItems: [Int], hiddenSections: Set<MenuBarSection.Name>) {
        guard
            let configClass = NSClassFromString("MBAssessmentModeConfiguration") as? NSObject.Type,
            let assertionClass = NSClassFromString("MBAssessmentModeAssertion") as? NSObject.Type,
            // `init` consumes the object from `alloc`, and returns a retained one.
            let allocated = configClass.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() as? NSObject,
            let config = allocated.perform(
                NSSelectorFromString("initWithAllowedSystemItems:allowedBundleIdentifiers:"),
                with: allowedSystemItems.map { NSNumber(value: $0) },
                with: Array(allowedBundles)
            )?.takeRetainedValue()
        else {
            logger.error("Failed to create assessment mode configuration")
            return
        }

        // Invalidating the old assertion before the new one is active briefly
        // shows every item, so wait until MenuBarAgent confirms the new one.
        let old = restriction?.assertion
        let completion: @convention(block) (NSError?) -> Void = { [logger] error in
            if let error {
                logger.error("Failed to hide menu bar items: \(error, privacy: .public)")
            }
            Task { @MainActor in
                old?.perform(NSSelectorFromString("invalidate"))
            }
        }

        let assertion = assertionClass.init()
        assertion.perform(
            NSSelectorFromString("activateWithConfiguration:completionHandler:"),
            with: config,
            with: unsafeBitCast(completion, to: AnyObject.self)
        )

        restriction = Restriction(
            assertion: assertion,
            allowedBundles: allowedBundles,
            allowedSystemItems: allowedSystemItems,
            hiddenSections: hiddenSections
        )
        logger.debug("Hiding \(hiddenSections.map { $0.logString }, privacy: .public)")
    }

    /// Waits until MenuBarAgent has faded out the items being hidden.
    func waitUntilItemsAreHidden() async {
        // The restriction is applied after the sections' states change.
        for _ in 0..<15 where restriction == nil {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard restriction != nil else {
            return // Nothing to hide.
        }
        // ponytail: fixed duration of MenuBarAgent's fade-out, which we can't
        // observe. Items leave its accessibility hierarchy well after they
        // fade out, so that's too late to wait for.
        try? await Task.sleep(for: .milliseconds(175))
    }

    /// Releases the active restriction after the given delay, showing every
    /// item.
    ///
    /// The restriction stays active until it's released, so items aren't
    /// cached while still hidden.
    private func release(after delay: Duration = .zero) {
        pendingRelease?.cancel()
        pendingRelease = nil
        guard let restriction else {
            return
        }
        guard delay > .zero else {
            finishReleasing(restriction)
            return
        }
        pendingRelease = Task {
            try? await Task.sleep(for: delay)
            if !Task.isCancelled {
                finishReleasing(restriction)
            }
        }
    }

    /// Invalidates the given restriction, showing the items it hid.
    private func finishReleasing(_ released: Restriction) {
        released.assertion.perform(NSSelectorFromString("invalidate"))
        if restriction?.assertion === released.assertion {
            restriction = nil
        }
        for name in released.hiddenSections {
            markFading(name)
        }
        logger.debug("Released restriction")
    }

    /// Treats the given section as hidden while its items fade back in, so
    /// their images aren't captured before they're drawn.
    private func markFading(_ section: MenuBarSection.Name) {
        fadingSections.insert(section)
        Task {
            try? await Task.sleep(for: .seconds(1))
            fadingSections.remove(section)
        }
    }
}
