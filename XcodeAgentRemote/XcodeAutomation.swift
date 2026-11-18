//
//  XcodeAutomation.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/18.
//

import AppKit

/// Controlling Xcode with Apple Events (AppleScript).
///
/// Permissions related set up:
/// - `Info.plist` `NSAppleEventsUsageDescription` (the text shown in the permission prompt)
/// - `Hardened runtime`: the Apple Events entitlement (`com.apple.security.automation.apple-events`)
nonisolated enum XcodeAutomation {

    /// Error that could occur when closing an Xcode project with Apple script
    nonisolated enum CloseProjectError: LocalizedError {
        /// The user has not allowed this app to control Xcode (System Settings → Privacy & Security → Automation).
        case notPermitted
        case scriptFailed(number: Int, message: String)

        var errorDescription: String? {
            switch self {
            case .notPermitted:
                "Not allowed to control Xcode. Allow it in System Settings → Privacy & Security → Automation."
            case .scriptFailed(let number, let message):
                "AppleScript error \(number): \(message)"
            }
        }
    }

    /// Xcode and Xcode-beta use the same bundle id.
    static private let bundleIdentifier = "com.apple.dt.Xcode"

    /// setting URL to open up System Settings → Privacy & Security → Automation directly
    static private let settingURL =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"

    static private var isXcodeRunning: Bool {
        !NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ).isEmpty
    }
}

extension XcodeAutomation {
    /// Closes the project's window in Xcode (its workspace document), saving any unsaved edits.
    /// - Parameter project: the `.xcodeproj` / `.xcworkspace` Xcode has open.
    /// - Returns: whether Xcode had the project open (and closed it). `false` if Xcode is not running.
    ///
    /// Note:
    /// `NSAppleScript` requires `@MainActor`.
    /// This class is not thread-safe. Initializing, compiling, or executing an NSAppleScript from a background thread causes random crashes, hangs, or Apple Event manager failures.
    @MainActor @discardableResult
    static func closeProject(at project: URL) throws -> Bool {
        guard isXcodeRunning else { return false }

        // Xcode reports a document's path without a trailing slash.
        var path = project.standardizedFileURL.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        let escaped =
            path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let source = """
            tell application id "\(bundleIdentifier)"
                set openCount to count of (every workspace document whose path is "\(escaped)")
                if openCount > 0 then close (every workspace document whose path is "\(escaped)") saving yes
                return openCount
            end tell
            """
        var errorInfo: NSDictionary?
        guard
            let result = NSAppleScript(source: source)?.executeAndReturnError(
                &errorInfo
            )
        else {
            let number = errorInfo?[NSAppleScript.errorNumber] as? Int ?? 0
            if number == Int(errAEEventNotPermitted) {
                throw CloseProjectError.notPermitted
            }
            let message =
                errorInfo?[NSAppleScript.errorMessage] as? String
                ?? "unknown error"
            throw CloseProjectError.scriptFailed(
                number: number,
                message: message
            )
        }
        return result.int32Value > 0
    }
}

/// Ask for automation permission
extension XcodeAutomation {
    enum PermissionStatus: Equatable, Sendable {
        case granted
        case denied
        /// Not asked yet (only returned when not asking).
        case notDetermined
        /// The prompt can only be shown, and the answer only checked, while Xcode is running.
        case xcodeNotRunning
        case unknown(OSStatus)
    }

    /// Whether this app may control Xcode with Apple Events.
    ///
    /// `askIfNeeded`: a Boolean;
    /// - if true, and if this application does not yet have permission to send events to the target application, then prompt the user to obtain permission.
    /// - If false, do not prompt the user.
    ///
    /// After the user answered, it only returns the answer regardless of the value of `askIfNeeded`
    /// A denied permission can only be changed in System Settings → Privacy & Security → Automation.
    ///
    /// Note
    /// -  Runs off the main thread: the call waits while the prompt is shown.
    @MainActor
    static func automationPermission(askIfNeeded: Bool = true) async
        -> PermissionStatus
    {
        await Task.detached {
            let target = NSAppleEventDescriptor(
                bundleIdentifier: bundleIdentifier
            )
            let status = AEDeterminePermissionToAutomateTarget(
                target.aeDesc,
                typeWildCard,
                typeWildCard,
                askIfNeeded
            )
            switch status {
            case noErr: return .granted
            case OSStatus(errAEEventNotPermitted): return .denied
            case OSStatus(errAEEventWouldRequireUserConsent):
                return .notDetermined
            case OSStatus(procNotFound): return .xcodeNotRunning
            default: return .unknown(status)
            }
        }.value
    }

    /// Opens System Settings → Privacy & Security → Automation (to change a denied permission).
    @MainActor
    static func openAutomationSettings() {
        if let url = URL(
            string: self.settingURL
        ) {
            NSWorkspace.shared.open(url)
        }
    }
}
