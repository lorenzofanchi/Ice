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
    // ponytail: only the numbers we verified. System items missing from this
    // list can't be hidden, which keeps them visible rather than lost.
    private static let systemItemNumbers: [String: Int] = [
        "com.apple.menuextra.clock": 2,
        "com.apple.menuextra.sound": 5,
        "com.apple.menuextra.wifi": 6,
        "com.apple.menuextra.controlcenter": 8,
    ]

    /// All system item numbers MenuBarAgent knows about.
    private static let allSystemItemNumbers = Array(0...9)

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
    private var restriction: Restriction?

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
