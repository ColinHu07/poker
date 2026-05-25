import Foundation
import GoogleSignIn
import SwiftUI
import UIKit

/// Real Google Sign-In manager (replaces the earlier stub).
///
/// ## Client configuration
/// The `CLIENT_ID` / `REVERSED_CLIENT_ID` for this iOS OAuth client live in
/// `Info.plist`:
///   - `GIDClientID`            = CLIENT_ID       (iOS OAuth client id)
///   - `CFBundleURLTypes[…]`    = REVERSED_CLIENT_ID (URL scheme for callback)
///
/// Current values (from `client_73159526960-…apps.googleusercontent.com.plist`):
///   CLIENT_ID          = 73159526960-bnkmdrbl4m4chf6mdc4blpb7b6nv5sm9.apps.googleusercontent.com
///   REVERSED_CLIENT_ID = com.googleusercontent.apps.73159526960-bnkmdrbl4m4chf6mdc4blpb7b6nv5sm9
///   BUNDLE_ID          = PokerVision
///
/// If you ever rotate the OAuth client, update BOTH the Info.plist values.
@MainActor
final class GoogleAuthManager: ObservableObject {
    static let shared = GoogleAuthManager()

    @Published private(set) var isSignedIn: Bool = false
    @Published private(set) var userEmail: String?
    @Published private(set) var userName: String?
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var isBusy: Bool = false

    private init() {}

    // MARK: - Lifecycle

    /// Call once at app launch to restore a previously-signed-in user.
    func restorePreviousSignInIfAvailable() {
        guard GIDSignIn.sharedInstance.hasPreviousSignIn() else {
            NSLog("[GoogleAuth] no previous sign-in")
            return
        }
        isBusy = true
        GIDSignIn.sharedInstance.restorePreviousSignIn { [weak self] user, error in
            Task { @MainActor in
                guard let self else { return }
                self.isBusy = false
                if let error {
                    NSLog("[GoogleAuth] restore failed: %@", String(describing: error))
                    self.isSignedIn = false
                    return
                }
                self.apply(user: user)
                NSLog("[GoogleAuth] restored session for %@", self.userEmail ?? "?")
            }
        }
    }

    /// Handles the deep-link callback from the Google sign-in web flow.
    /// Wire this up in your SwiftUI App's `.onOpenURL`.
    @discardableResult
    func handle(url: URL) -> Bool {
        GIDSignIn.sharedInstance.handle(url)
    }

    // MARK: - Sign in / out

    func signIn() {
        guard !isBusy else { return }
        guard let presenter = Self.topPresentingController() else {
            lastErrorMessage = "No presenting view controller available"
            NSLog("[GoogleAuth] signIn: no presenter")
            return
        }
        lastErrorMessage = nil
        isBusy = true
        NSLog("[GoogleAuth] signIn: presenting picker")
        GIDSignIn.sharedInstance.signIn(withPresenting: presenter) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                self.isBusy = false
                if let error {
                    self.handleSignInError(error)
                    return
                }
                self.apply(user: result?.user)
                NSLog("[GoogleAuth] signIn success: %@", self.userEmail ?? "?")
            }
        }
    }

    func signOut() {
        GIDSignIn.sharedInstance.signOut()
        isSignedIn = false
        userEmail = nil
        userName = nil
        lastErrorMessage = nil
        NSLog("[GoogleAuth] signOut")
    }

    // MARK: - Internals

    private func apply(user: GIDGoogleUser?) {
        if let profile = user?.profile {
            userEmail = profile.email
            userName = profile.name
            isSignedIn = true
        } else {
            userEmail = nil
            userName = nil
            isSignedIn = false
        }
    }

    private func handleSignInError(_ error: Error) {
        let ns = error as NSError
        NSLog(
            "[GoogleAuth] signIn error domain=%@ code=%d userInfo=%@",
            ns.domain, ns.code, String(describing: ns.userInfo)
        )
        if ns.domain == kGIDSignInErrorDomain,
            let code = GIDSignInError.Code(rawValue: ns.code)
        {
            switch code {
            case .canceled:
                lastErrorMessage = nil  // silent cancel
                return
            case .hasNoAuthInKeychain:
                lastErrorMessage = "Not signed in yet."
            case .unknown:
                lastErrorMessage = "Sign-in failed. Please try again."
            default:
                lastErrorMessage = "Sign-in failed (\(code.rawValue))."
            }
        } else {
            lastErrorMessage =
                "Sign-in failed: \(ns.localizedDescription)."
        }
        // If your OAuth consent screen is in "Testing" mode, Google blocks
        // non-test accounts with a 403 / access_denied error.
        let desc = ns.localizedDescription.lowercased()
        if desc.contains("access_denied") || desc.contains("not allowed") || ns.code == -5
            || desc.contains("disallowed")
        {
            lastErrorMessage =
                "Access denied. If your Google OAuth app is in Testing mode, add your Gmail under "
                + "Google Auth Platform → Audience → Test users."
        }
    }

    // MARK: - UIKit presenter lookup

    static func topPresentingController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes
        guard
            let windowScene = scenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive })
                ?? scenes.compactMap({ $0 as? UIWindowScene }).first,
            let window = windowScene.windows.first(where: { $0.isKeyWindow })
                ?? windowScene.windows.first,
            var top = window.rootViewController
        else { return nil }
        while let presented = top.presentedViewController { top = presented }
        return top
    }
}
