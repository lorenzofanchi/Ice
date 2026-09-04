//
//  PermissionsManager.swift
//  Ice
//

import Cocoa
import Combine

/// A type that manages the permissions of the app.
@MainActor
final class PermissionsManager: ObservableObject {
    /// The state of the granted permissions for the app.
    enum PermissionsState {
        case missingPermissions
        case hasAllPermissions
        case hasRequiredPermissions
    }

    /// The state of the granted permissions for the app.
    @Published var permissionsState = PermissionsState.missingPermissions

    let accessibilityPermission: AccessibilityPermission

    let screenRecordingPermission: ScreenRecordingPermission

    let allPermissions: [Permission]

    private(set) weak var appState: AppState?

    private var cancellables = Set<AnyCancellable>()

    /// Set once the app has finished setup; checks may be stopped only after this.
    private var hasCompletedSetup = false

    var requiredPermissions: [Permission] {
        allPermissions.filter { $0.isRequired }
    }

    init(appState: AppState) {
        self.appState = appState
        self.accessibilityPermission = AccessibilityPermission()
        self.screenRecordingPermission = ScreenRecordingPermission()
        self.allPermissions = [
            accessibilityPermission,
            screenRecordingPermission,
        ]
        configureCancellables()
    }

    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        Publishers.Merge(
            accessibilityPermission.$hasPermission.mapToVoid(),
            screenRecordingPermission.$hasPermission.mapToVoid()
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in
            guard let self else {
                return
            }
            if allPermissions.allSatisfy({ $0.hasPermission }) {
                permissionsState = .hasAllPermissions
            } else if requiredPermissions.allSatisfy({ $0.hasPermission }) {
                permissionsState = .hasRequiredPermissions
            } else {
                permissionsState = .missingPermissions
            }
        }
        .store(in: &c)

        // Permissions can be revoked later (macOS 15+ re-prompts for Screen Recording
        // periodically), so poll while the app is active and its windows are visible.
        // Only stop when setup has completed; before that the permissions window relies
        // on polling while the user is over in System Settings.
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                self?.startAllChecks()
            }
            .store(in: &c)
        NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .sink { [weak self] _ in
                guard let self, hasCompletedSetup else {
                    return
                }
                stopAllChecks()
            }
            .store(in: &c)

        cancellables = c
    }

    /// Starts running all permissions checks.
    func startAllChecks() {
        for permission in allPermissions {
            permission.startCheck()
        }
    }

    /// Stops running all permissions checks.
    func stopAllChecks() {
        hasCompletedSetup = true
        for permission in allPermissions {
            permission.stopCheck()
        }
    }
}
