import AuthenticationServices
import Foundation
import UIKit

/// Manages Google OAuth 2.0 sign-in for Google Drive backup.
///
/// Uses the native `ASWebAuthenticationSession` for a dependency-free
/// OAuth flow. The access token is stored securely in the Keychain and
/// is consumed by `CloudBackupManager` for Drive API uploads/downloads.
final class GoogleDriveAuthManager: NSObject, ObservableObject {

    static let shared = GoogleDriveAuthManager()

    // MARK: - Configuration
    //
    // ⚠️ IMPORTANT: Replace with your own Google OAuth 2.0 Client ID.
    //
    // Steps:
    //  1. Go to https://console.cloud.google.com/apis/credentials
    //  2. Create a new OAuth 2.0 Client ID
    //  3. Choose "iOS" as the application type
    //  4. Set the bundle identifier to: com.vpnhide.app
    //  5. Copy the Client ID here (format: xxxxx.apps.googleusercontent.com)
    //
    private let clientID = "921038203170-jqr5fnv02b9c35a5hb6let64k0hulkgn.apps.googleusercontent.com"

    /// Must match the `CFBundleURLSchemes` entry in project.yml
    /// (the app's bundle ID is used as the deep-link scheme).
    private let redirectScheme = "com.vpnhide.app"

    // MARK: - Published

    @Published var isSignedIn: Bool = false
    @Published var isAuthenticating = false

    // MARK: - Private

    private let tokenKey = "google.oauth.accessToken"
    private let refreshTokenKey = "google.oauth.refreshToken"
    private var authSession: ASWebAuthenticationSession?
    private var completionHandler: ((Result<String, Error>) -> Void)?

    private override init() {
        super.init()
        loadSavedSession()
    }

    // MARK: - Public API

    /// The current Google Drive access token, or `nil` if not signed in.
    var accessToken: String? {
        KeychainManager.shared.readKey(named: tokenKey).flatMap {
            String(data: $0, encoding: .utf8)
        }
    }

    /// Starts the Google OAuth 2.0 sign-in flow.
    ///
    /// - Parameter completion: Called with the access token on success,
    ///   or an error if the user cancels / the flow fails.
    func signIn(completion: @escaping (Result<String, Error>) -> Void) {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        completionHandler = completion

        // Request offline access + the Drive file scope (minimal permission:
        // can only see files the app creates).
        let scopes = "https://www.googleapis.com/auth/drive.file"
        let redirectURI = "\(redirectScheme)://oauth"

        guard let authURL = makeAuthURL(scopes: scopes, redirectURI: redirectURI) else {
            isAuthenticating = false
            completion(.failure(GoogleAuthError.invalidURL))
            return
        }

        let session = ASWebAuthenticationSession(
            url: authURL,
            callbackURLScheme: redirectScheme
        ) { [weak self] callbackURL, error in
            self?.isAuthenticating = false

            if let error {
                self?.finish(with: .failure(error))
                return
            }
            guard let callbackURL else {
                self?.finish(with: .failure(GoogleAuthError.noCallbackURL))
                return
            }
            self?.handleCallback(callbackURL, redirectURI: redirectURI)
        }

        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        authSession = session
        session.start()
    }

    /// Signs out by clearing stored credentials.
    func signOut() {
        try? KeychainManager.shared.deleteKey(named: tokenKey)
        try? KeychainManager.shared.deleteKey(named: refreshTokenKey)
        isSignedIn = false
    }

    // MARK: - OAuth URL Construction

    private func makeAuthURL(scopes: String, redirectURI: String) -> URL? {
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "state", value: UUID().uuidString)
        ]
        return components?.url
    }

    // MARK: - Callback Handling

    private func handleCallback(_ url: URL, redirectURI: String) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
            finish(with: .failure(GoogleAuthError.missingAuthCode))
            return
        }

        exchangeCodeForToken(code: code, redirectURI: redirectURI)
    }

    // MARK: - Token Exchange

    private func exchangeCodeForToken(code: String, redirectURI: String) {
        guard let tokenURL = URL(string: "https://oauth2.googleapis.com/token") else {
            finish(with: .failure(GoogleAuthError.invalidURL))
            return
        }

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = "code=\(code)" +
            "&client_id=\(clientID)" +
            "&redirect_uri=\(redirectURI)" +
            "&grant_type=authorization_code"
        request.httpBody = body.data(using: .utf8)

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }

                if let error {
                    self.finish(with: .failure(error))
                    return
                }

                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let accessToken = json["access_token"] as? String else {
                    self.finish(with: .failure(GoogleAuthError.tokenExchangeFailed))
                    return
                }

                // Persist the access token (and refresh token if returned)
                try? KeychainManager.shared.saveKey(
                    Data(accessToken.utf8),
                    named: self.tokenKey
                )
                if let refreshToken = json["refresh_token"] as? String {
                    try? KeychainManager.shared.saveKey(
                        Data(refreshToken.utf8),
                        named: self.refreshTokenKey
                    )
                }

                self.isSignedIn = true
                self.finish(with: .success(accessToken))
            }
        }.resume()
    }

    // MARK: - Helpers

    private func finish(with result: Result<String, Error>) {
        completionHandler?(result)
        completionHandler = nil
    }

    private func loadSavedSession() {
        isSignedIn = accessToken != nil
    }

    // MARK: - Errors

    enum GoogleAuthError: LocalizedError {
        case invalidURL
        case noCallbackURL
        case missingAuthCode
        case tokenExchangeFailed

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "Could not build the Google sign-in URL."
            case .noCallbackURL:
                return "Google sign-in was cancelled."
            case .missingAuthCode:
                return "Google sign-in did not return an authorization code."
            case .tokenExchangeFailed:
                return "Could not exchange the authorization code for an access token."
            }
        }
    }
}

// MARK: - ASWebAuthenticationPresentationContextProviding

extension GoogleDriveAuthManager: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // Prefer the key window of the active scene.
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        return window ?? ASPresentationAnchor()
    }
}