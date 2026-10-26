import AppKit
import CryptoKit
import Foundation
import Network
import Security

enum GoogleError: LocalizedError {
    case notConfigured
    case notSignedIn(String)
    case api(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Add your Google OAuth client ID in Settings › Google first."
        case .notSignedIn(let a): "\(a) is signed out — sign in again in Settings › Google."
        case .api(let m): m
        case .cancelled: "Sign-in was cancelled."
        }
    }
}

// MARK: - Keychain

enum Keychain {
    private static let service = "com.local.Yoman.google"

    static func set(_ value: String, account: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func delete(account: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                       kSecAttrAccount as String: account] as CFDictionary)
    }
}

// MARK: - OAuth (installed-app flow: PKCE + loopback redirect)

@MainActor
final class GoogleAuth {
    static let scopes = "openid email https://www.googleapis.com/auth/calendar"
    private static let clientSecretKey = "__client_secret__"

    private var accessTokens: [String: (token: String, expiry: Date)] = [:]
    private var server: LoopbackServer?

    var clientID: String {
        get { UserDefaults.standard.string(forKey: "googleClientID") ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespaces), forKey: "googleClientID") }
    }

    /// Google issues a "secret" for Desktop clients; it isn't confidential but the token endpoint requires it.
    var clientSecret: String {
        get { Keychain.get(account: Self.clientSecretKey) ?? "" }
        set { Keychain.set(newValue.trimmingCharacters(in: .whitespaces), account: Self.clientSecretKey) }
    }

    var isConfigured: Bool { !clientID.isEmpty }

    /// Opens the browser, waits for the redirect, exchanges the code. Returns (email, refreshToken).
    func signIn() async throws -> (email: String, refreshToken: String) {
        guard isConfigured else { throw GoogleError.notConfigured }
        let server = LoopbackServer()
        self.server = server
        defer { server.stop(); self.server = nil }
        let port = try await server.start()
        let redirect = "http://127.0.0.1:\(port)"
        let verifier = Self.randomString(64)
        let state = Self.randomString(24)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL

        var c = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        c.queryItems = [
            .init(name: "client_id", value: clientID), .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"), .init(name: "scope", value: Self.scopes),
            .init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256"),
            .init(name: "access_type", value: "offline"), .init(name: "prompt", value: "consent select_account"),
            .init(name: "state", value: state),
        ]
        NSWorkspace.shared.open(c.url!)

        let params = try await server.waitForCallback(timeout: 300)
        if let err = params["error"] { throw GoogleError.api("Google sign-in failed: \(err)") }
        guard params["state"] == state, let code = params["code"] else { throw GoogleError.api("Unexpected sign-in response.") }

        let json = try await Self.postForm("https://oauth2.googleapis.com/token", [
            "client_id": clientID, "client_secret": clientSecret, "code": code, "code_verifier": verifier,
            "redirect_uri": redirect, "grant_type": "authorization_code",
        ])
        guard let refresh = json["refresh_token"] as? String, let access = json["access_token"] as? String else {
            throw GoogleError.api("Google did not return a refresh token.")
        }
        let info = try await Self.getJSON("https://openidconnect.googleapis.com/v1/userinfo", token: access)
        guard let email = info["email"] as? String else { throw GoogleError.api("Could not read the account email.") }
        accessTokens[email] = (access, Date().addingTimeInterval(TimeInterval((json["expires_in"] as? Int) ?? 3600) - 60))
        Keychain.set(refresh, account: email)
        return (email, refresh)
    }

    func cancelSignIn() { server?.cancel() }

    func signOut(_ email: String) {
        if let t = Keychain.get(account: email) {
            var r = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke?token=\(t)")!)
            r.httpMethod = "POST"
            URLSession.shared.dataTask(with: r).resume()
        }
        Keychain.delete(account: email)
        accessTokens[email] = nil
    }

    func accessToken(for email: String) async throws -> String {
        if let t = accessTokens[email], t.expiry > Date() { return t.token }
        guard let refresh = Keychain.get(account: email) else { throw GoogleError.notSignedIn(email) }
        let json: [String: Any]
        do {
            json = try await Self.postForm("https://oauth2.googleapis.com/token", [
                "client_id": clientID, "client_secret": clientSecret, "refresh_token": refresh, "grant_type": "refresh_token",
            ])
        } catch GoogleError.api(let m) where m.contains("invalid_grant") {
            throw GoogleError.notSignedIn(email)
        }
        guard let access = json["access_token"] as? String else { throw GoogleError.notSignedIn(email) }
        accessTokens[email] = (access, Date().addingTimeInterval(TimeInterval((json["expires_in"] as? Int) ?? 3600) - 60))
        return access
    }

    // MARK: HTTP helpers

    static func postForm(_ url: String, _ params: [String: String]) async throws -> [String: Any] {
        var r = URLRequest(url: URL(string: url)!)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        r.httpBody = params.map { "\($0)=\($1.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: r)
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw GoogleError.api("\(json["error"] ?? "error"): \(json["error_description"] ?? "token request failed")")
        }
        return json
    }

    static func getJSON(_ url: String, token: String) async throws -> [String: Any] {
        var r = URLRequest(url: URL(string: url)!)
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: r)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private static func randomString(_ n: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var rng = SystemRandomNumberGenerator()
        return String((0..<n).map { _ in chars.randomElement(using: &rng)! })
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Loopback redirect receiver (127.0.0.1 only)

@MainActor
final class LoopbackServer {
    private var listener: NWListener?
    private var startContinuation: CheckedContinuation<UInt16, Error>?
    private var continuation: CheckedContinuation<[String: String], Error>?
    private var pending: Result<[String: String], Error>?

    func start() async throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let l = try NWListener(using: params)
        listener = l
        l.newConnectionHandler = { [weak self] conn in
            MainActor.assumeIsolated { self?.handle(conn) }
        }
        return try await withCheckedThrowingContinuation { cont in
            startContinuation = cont
            l.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    guard let self, let c = self.startContinuation else { return }
                    switch state {
                    case .ready: self.startContinuation = nil; c.resume(returning: l.port?.rawValue ?? 0)
                    case .failed(let e): self.startContinuation = nil; c.resume(throwing: e)
                    default: break
                    }
                }
            }
            l.start(queue: .main)
        }
    }

    func waitForCallback(timeout: TimeInterval) async throws -> [String: String] {
        if let p = pending { return try p.get() }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            MainActor.assumeIsolated { self?.deliver(.failure(GoogleError.cancelled)) }
        }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func cancel() { deliver(.failure(GoogleError.cancelled)) }

    func stop() { listener?.cancel(); listener = nil }

    private func deliver(_ r: Result<[String: String], Error>) {
        if let c = continuation { continuation = nil; c.resume(with: r) } else if pending == nil { pending = r }
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .main)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            MainActor.assumeIsolated {
                let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                let items = URLComponents(string: "http://127.0.0.1\(path)")?.queryItems ?? []
                let params = Dictionary(items.compactMap { i in i.value.map { (i.name, $0) } }, uniquingKeysWith: { a, _ in a })
                let isCallback = params["code"] != nil || params["error"] != nil
                let body = isCallback
                    ? "<html><body style='font-family:-apple-system;text-align:center;padding-top:80px'><h2>✅ Yoman is connected</h2><p>You can close this tab.</p></body></html>"
                    : "Not found"
                let resp = "HTTP/1.1 \(isCallback ? "200 OK" : "404 Not Found")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in conn.cancel() })
                if isCallback {
                    self?.deliver(.success(params))
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        }
    }
}
