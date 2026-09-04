//
//  PermissionsView.swift
//  Ice
//

import SwiftUI

struct PermissionsView: View {
    @EnvironmentObject var permissionsManager: PermissionsManager
    @Environment(\.openWindow) private var openWindow

    private var continueButtonText: LocalizedStringKey {
        if case .hasRequiredPermissions = permissionsManager.permissionsState {
            "Continue in Limited Mode"
        } else {
            "Continue"
        }
    }

    private var continueButtonForegroundStyle: some ShapeStyle {
        if case .hasRequiredPermissions = permissionsManager.permissionsState {
            AnyShapeStyle(.yellow)
        } else {
            AnyShapeStyle(.primary)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView
                .padding(.vertical)

            explanationView
            permissionsGroupStack

            footerView
                .padding(.vertical)
        }
        .padding(.horizontal)
        .fixedSize()
        .readWindow { window in
            guard let window else {
                return
            }
            window.styleMask.remove([.closable, .miniaturizable])
            if let contentView = window.contentView {
                with(contentView.safeAreaInsets) { insets in
                    insets.bottom = -insets.bottom
                    insets.left = -insets.left
                    insets.right = -insets.right
                    insets.top = -insets.top
                    contentView.additionalSafeAreaInsets = insets
                }
            }
        }
    }

    @ViewBuilder
    private var headerView: some View {
        Label {
            Text("Permissions")
                .font(.system(size: 36))
        } icon: {
            if let nsImage = NSImage(named: NSImage.applicationIconName) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 75, height: 75)
            }
        }
    }

    @ViewBuilder
    private var explanationView: some View {
        IceSection {
            VStack {
                Text("Ice needs permission to manage the menu bar.")
                Text("Absolutely no personal information is collected or stored.")
                    .bold()
                    .foregroundStyle(.red)
            }
            .padding()
        }
        .font(.title3)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var permissionsGroupStack: some View {
        VStack(spacing: 7.5) {
            ForEach(permissionsManager.allPermissions) { permission in
                PermissionBox(permission: permission)
            }
        }
    }

    @ViewBuilder
    private var footerView: some View {
        HStack {
            quitButton
            continueButton
        }
        .controlSize(.large)
    }

    @ViewBuilder
    private var quitButton: some View {
        Button {
            NSApp.terminate(nil)
        } label: {
            Text("Quit")
                .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var continueButton: some View {
        Button {
            guard let appState = permissionsManager.appState else {
                return
            }
            appState.performSetup()
            appState.permissionsWindow?.close()
            appState.appDelegate?.openSettingsWindow()
        } label: {
            Text(continueButtonText)
                .frame(maxWidth: .infinity)
                .foregroundStyle(continueButtonForegroundStyle)
        }
        .disabled(permissionsManager.permissionsState == .missingPermissions)
    }
}

/// A box describing one permission, with a button to grant it.
///
/// Observes the permission directly so the box updates the moment
/// the permission is granted.
private struct PermissionBox: View {
    @EnvironmentObject var permissionsManager: PermissionsManager
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var permission: Permission

    var body: some View {
        IceSection {
            VStack(spacing: 10) {
                Text(permission.title)
                    .font(.title)
                    .underline()

                VStack(spacing: 0) {
                    Text("Ice needs this to:")
                        .font(.title3)
                        .bold()

                    VStack(alignment: .leading) {
                        ForEach(permission.details, id: \.self) { detail in
                            HStack {
                                Text("•").bold()
                                Text(detail)
                            }
                        }
                    }
                }

                if permission.hasPermission {
                    grantedChip
                } else {
                    grantButton
                }

                if !permission.isRequired {
                    IceGroupBox {
                        AnnotationView(
                            alignment: .center,
                            font: .callout.bold()
                        ) {
                            Label {
                                Text("Ice can work in a limited mode without this permission.")
                            } icon: {
                                Image(systemName: "checkmark.shield")
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                }

                // Screen Recording only takes effect after a relaunch. If the user
                // granted it in System Settings and chose not to relaunch from there,
                // the check above never flips, so offer the relaunch here.
                if permission is ScreenRecordingPermission, !permission.hasPermission {
                    HStack {
                        Text("Already granted it? Screen Recording takes effect after Ice is relaunched.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button("Relaunch Ice") {
                            relaunch()
                        }
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity)
        }
    }

    private var grantedChip: some View {
        Label("Permission Granted", systemImage: "checkmark.circle.fill")
            .font(.callout.bold())
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(.green.opacity(0.15)))
            .foregroundStyle(.green)
    }

    private var grantButton: some View {
        Button("Grant Permission") {
            guard let appState = permissionsManager.appState else {
                return
            }
            permission.performRequest()
            Task {
                await permission.waitForPermission()
                appState.activate(withPolicy: .regular)
                openWindow(id: Constants.permissionsWindowID)
            }
        }
    }

    /// Launches a new instance of Ice, then quits this one.
    private func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }
}
