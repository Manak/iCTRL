import Foundation

/// One HTTP request, reduced to what authentication and routing need.
struct BridgeHTTPRequest {
    let method: String
    /// Path without the query string.
    let path: String
    /// Header names lowercased.
    let headers: [String: String]
    let body: Data
}

/// Decides whether a request may reach the MCP endpoint. Kept small and
/// pluggable so OAuth 2.1 can be added later without touching the server.
protocol BridgeAuthenticator {
    /// True only if the request is authentic AND addressed to the MCP
    /// endpoint. Anything else gets an identical plain 404 from the server.
    func authorize(_ request: BridgeHTTPRequest) -> Bool
}

/// Where the current secret comes from (the keychain, on the phone).
protocol BridgeSecretSource {
    /// nil means "no secret set": every request is rejected.
    var currentSecret: String? { get }
}

enum BridgeSecret {
    /// 32 random bytes (256 bits), base64url without padding: 43 characters.
    static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        var rng = SystemRandomNumberGenerator()
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255, using: &rng) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Compares without stopping at the first difference, so response time
    /// does not reveal how much of a guess was right.
    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var diff = UInt8(x.count == y.count ? 0 : 1)
        // Always walk the full length of the expected value.
        for i in 0..<y.count {
            diff |= (i < x.count ? x[i] : 0) ^ y[i]
        }
        return diff == 0
    }
}

/// Authentication by a long secret in the URL path: `/<secret>/mcp`.
/// The secret is read on every request, so rotation takes effect at once.
struct BridgePathSecretAuthenticator: BridgeAuthenticator {
    let secrets: BridgeSecretSource
    /// Shortest secret that will ever be accepted, whatever is stored.
    static let minimumLength = 32

    func authorize(_ request: BridgeHTTPRequest) -> Bool {
        guard let secret = secrets.currentSecret, secret.count >= Self.minimumLength else { return false }
        let parts = request.path.split(separator: "/", omittingEmptySubsequences: false)
        // "/<secret>/mcp" splits into ["", "<secret>", "mcp"].
        let candidate = parts.count == 3 && parts[0].isEmpty ? String(parts[1]) : ""
        let shapeOK = parts.count == 3 && parts[0].isEmpty && parts[2] == "mcp"
        // Compare even when the shape is wrong, to keep timing uniform.
        let secretOK = BridgeSecret.constantTimeEquals(candidate, secret)
        return shapeOK && secretOK
    }
}

/// Path secret plus a static bearer token header, for Claude accounts that
/// have the connector "Request headers" option. Both must match.
struct BridgePathAndBearerAuthenticator: BridgeAuthenticator {
    let path: BridgePathSecretAuthenticator
    let bearer: BridgeSecretSource

    func authorize(_ request: BridgeHTTPRequest) -> Bool {
        let pathOK = path.authorize(request)
        guard let token = bearer.currentSecret, token.count >= BridgePathSecretAuthenticator.minimumLength else {
            return false
        }
        let header = request.headers["authorization"] ?? ""
        let tokenOK = BridgeSecret.constantTimeEquals(header, "Bearer " + token)
        return pathOK && tokenOK
    }
}
