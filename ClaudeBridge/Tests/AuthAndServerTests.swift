import XCTest
@testable import ClaudeBridgeCore

private let secret = "s3cr3t-s3cr3t-s3cr3t-s3cr3t-s3cr3t-s3cr3t-0"

private func request(_ path: String, method: String = "POST", headers: [String: String] = [:], json: Any? = nil) -> BridgeHTTPRequest {
    let body = json.map { try! JSONSerialization.data(withJSONObject: $0) } ?? Data()
    return BridgeHTTPRequest(method: method, path: path, headers: headers, body: body)
}

private func decode(_ response: BridgeHTTPResponse) -> BridgeJSON {
    (try? JSONSerialization.jsonObject(with: response.body)) as? BridgeJSON ?? [:]
}

final class AuthTests: XCTestCase {

    func testGeneratedSecretIs256BitsURLSafeAndUnique() {
        let a = BridgeSecret.generate(), b = BridgeSecret.generate()
        XCTAssertEqual(a.count, 43)   // 32 bytes, base64url, no padding
        XCTAssertNotEqual(a, b)
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        XCTAssertTrue(a.unicodeScalars.allSatisfy(allowed.contains))
    }

    func testConstantTimeEquals() {
        XCTAssertTrue(BridgeSecret.constantTimeEquals("abc", "abc"))
        XCTAssertFalse(BridgeSecret.constantTimeEquals("abc", "abd"))
        XCTAssertFalse(BridgeSecret.constantTimeEquals("ab", "abc"))
        XCTAssertFalse(BridgeSecret.constantTimeEquals("abcd", "abc"))
        XCTAssertFalse(BridgeSecret.constantTimeEquals("", "abc"))
    }

    func testPathSecret() {
        let auth = BridgePathSecretAuthenticator(secrets: FixedSecret(currentSecret: secret))
        XCTAssertTrue(auth.authorize(request("/\(secret)/mcp")))
        for path in ["/mcp", "/", "", "/\(secret)", "/\(secret)/", "/\(secret)/mcp/", "/\(secret)/other",
                     "/x/\(secret)/mcp", "/\(secret)x/mcp", "/\(secret.dropLast())/mcp", "//mcp",
                     "/\(secret.uppercased())/mcp"] {
            XCTAssertFalse(auth.authorize(request(path)), path)
        }
    }

    func testNoSecretOrShortSecretRejectsEverything() {
        XCTAssertFalse(BridgePathSecretAuthenticator(secrets: FixedSecret(currentSecret: nil)).authorize(request("//mcp")))
        XCTAssertFalse(BridgePathSecretAuthenticator(secrets: FixedSecret(currentSecret: "")).authorize(request("//mcp")))
        XCTAssertFalse(BridgePathSecretAuthenticator(secrets: FixedSecret(currentSecret: "short")).authorize(request("/short/mcp")))
    }

    func testRotationInvalidatesOldSecretImmediately() {
        let store = MutableSecret(secret)
        let auth = BridgePathSecretAuthenticator(secrets: store)
        XCTAssertTrue(auth.authorize(request("/\(secret)/mcp")))
        let next = BridgeSecret.generate()
        store.currentSecret = next
        XCTAssertFalse(auth.authorize(request("/\(secret)/mcp")))
        XCTAssertTrue(auth.authorize(request("/\(next)/mcp")))
    }

    func testPathAndBearer() {
        let token = "t0ken-t0ken-t0ken-t0ken-t0ken-t0ken-t0ken"
        let auth = BridgePathAndBearerAuthenticator(
            path: BridgePathSecretAuthenticator(secrets: FixedSecret(currentSecret: secret)),
            bearer: FixedSecret(currentSecret: token))
        XCTAssertTrue(auth.authorize(request("/\(secret)/mcp", headers: ["authorization": "Bearer \(token)"])))
        XCTAssertFalse(auth.authorize(request("/\(secret)/mcp")))
        XCTAssertFalse(auth.authorize(request("/\(secret)/mcp", headers: ["authorization": token])))
        XCTAssertFalse(auth.authorize(request("/wrong/mcp", headers: ["authorization": "Bearer \(token)"])))
    }
}

final class MCPServerTests: XCTestCase {
    private var h: Harness!
    private var server: BridgeMCPServer!

    override func setUp() {
        h = Harness()
        server = BridgeMCPServer(
            auth: BridgePathSecretAuthenticator(secrets: FixedSecret(currentSecret: secret)),
            tools: h.tools)
    }

    private func rpc(_ method: String, _ params: BridgeJSON = [:], id: Any? = 1) -> BridgeHTTPResponse {
        var message: BridgeJSON = ["jsonrpc": "2.0", "method": method, "params": params]
        if let id = id { message["id"] = id }
        return server.handle(request("/\(secret)/mcp", json: message))
    }

    func testWrongPathGetsPlain404WithNoHint() {
        for (method, path) in [("POST", "/mcp"), ("GET", "/"), ("POST", "/wrong/mcp"), ("GET", "/.well-known/oauth-protected-resource")] {
            let r = server.handle(request(path, method: method, json: ["jsonrpc": "2.0", "id": 1, "method": "tools/list"]))
            XCTAssertEqual(r.status, 404)
            XCTAssertEqual(r.headers["Content-Type"], "text/plain; charset=utf-8")
            let body = String(decoding: r.body, as: UTF8.self).lowercased()
            XCTAssertFalse(body.contains("mcp"))
            XCTAssertFalse(body.contains("json"))
            XCTAssertNil(r.headers["WWW-Authenticate"])
        }
        XCTAssertEqual(h.raw.calls.count, 0)
    }

    func testInitializeNegotiatesVersion() {
        let r = decode(rpc("initialize", ["protocolVersion": "2025-03-26", "capabilities": [:], "clientInfo": ["name": "t", "version": "1"]]))
        let result = r["result"] as! BridgeJSON
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-03-26")
        XCTAssertNotNil((result["capabilities"] as? BridgeJSON)?["tools"])
        XCTAssertEqual((result["serverInfo"] as? BridgeJSON)?["name"] as? String, "ictrl-claude-bridge")

        let unknown = decode(rpc("initialize", ["protocolVersion": "1999-01-01"]))
        XCTAssertEqual((unknown["result"] as? BridgeJSON)?["protocolVersion"] as? String, "2025-06-18")
    }

    func testNotificationsGet202() {
        let r = rpc("notifications/initialized", id: nil)
        XCTAssertEqual(r.status, 202)
        XCTAssertTrue(r.body.isEmpty)
    }

    func testToolsListDescribesEveryTool() {
        let tools = (decode(rpc("tools/list"))["result"] as! BridgeJSON)["tools"] as! [BridgeJSON]
        XCTAssertEqual(Set(tools.map { $0["name"] as! String }), BridgeTools.toolNames)
        for tool in tools {
            let schema = tool["inputSchema"] as! BridgeJSON
            XCTAssertEqual(schema["type"] as? String, "object")
            XCTAssertNotNil(tool["description"])
        }
    }

    func testToolsCallRunsThroughGuard() {
        h.raw.foreground = whatsApp
        h.raw.results["tap"] = .success(["message": "ok"])
        let ok = decode(rpc("tools/call", ["name": "tap", "arguments": ["x": 10, "y": 20]], id: "abc"))
        XCTAssertEqual(ok["id"] as? String, "abc")
        XCTAssertEqual((ok["result"] as! BridgeJSON)["isError"] as? Bool, false)

        h.raw.foreground = safari
        let locked = decode(rpc("tools/call", ["name": "screenshot"]))
        let result = locked["result"] as! BridgeJSON
        XCTAssertEqual(result["isError"] as? Bool, true)
        let text = ((result["content"] as! [BridgeJSON])[0]["text"] as! String)
        XCTAssertEqual(text, BridgeGuard.lockedOutMessage)
    }

    func testProtocolErrors() {
        XCTAssertEqual((decode(rpc("tools/call", ["name": "nope"]))["error"] as! BridgeJSON)["code"] as? Int, -32602)
        XCTAssertEqual((decode(rpc("resources/list"))["error"] as! BridgeJSON)["code"] as? Int, -32601)
        XCTAssertEqual((decode(rpc("ping"))["result"] as? BridgeJSON)?.count, 0)

        let garbage = server.handle(BridgeHTTPRequest(method: "POST", path: "/\(secret)/mcp", headers: [:], body: Data("{nope".utf8)))
        XCTAssertEqual(garbage.status, 400)
        let get = server.handle(request("/\(secret)/mcp", method: "GET"))
        XCTAssertEqual(get.status, 405)
    }
}

final class HTTPWireTests: XCTestCase {

    func testParseCompleteRequest() {
        let raw = "POST /abc/mcp?x=1 HTTP/1.1\r\nHost: h\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}"
        guard case .request(let r) = BridgeHTTPServer.parse(Data(raw.utf8)) else { return XCTFail() }
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.path, "/abc/mcp")
        XCTAssertEqual(r.headers["content-type"], "application/json")
        XCTAssertEqual(r.body, Data("{}".utf8))
    }

    func testParseIncompleteAndInvalid() {
        func kind(_ s: String) -> String {
            switch BridgeHTTPServer.parse(Data(s.utf8)) {
            case .request: return "request"
            case .incomplete: return "incomplete"
            case .invalid: return "invalid"
            }
        }
        XCTAssertEqual(kind("POST /a HTTP/1.1\r\nContent-Le"), "incomplete")
        XCTAssertEqual(kind("POST /a HTTP/1.1\r\nContent-Length: 5\r\n\r\n{}"), "incomplete")
        XCTAssertEqual(kind("garbage\r\n\r\n"), "invalid")
        XCTAssertEqual(kind("POST /a HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n"), "invalid")
        XCTAssertEqual(kind("POST /a HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"), "invalid")
        XCTAssertEqual(kind(String(repeating: "x", count: 20_000)), "invalid")
        XCTAssertEqual(kind("GET / HTTP/1.1\r\n\r\n"), "request")
    }

    func testSerialize() {
        let text = String(decoding: BridgeHTTPServer.serialize(.notFound), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 404 Not Found\r\n"))
        XCTAssertTrue(text.contains("Connection: close\r\n"))
        XCTAssertTrue(text.contains("Content-Length: 19\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\n404 page not found\n"))
    }

    /// End to end over a real loopback socket.
    func testLoopbackServerRoundTrip() throws {
        let h = Harness()
        h.raw.foreground = whatsApp
        let mcp = BridgeMCPServer(
            auth: BridgePathSecretAuthenticator(secrets: FixedSecret(currentSecret: secret)),
            tools: h.tools)
        let server = BridgeHTTPServer(port: 0) { mcp.handle($0) }
        try server.start()
        defer { server.stop() }
        XCTAssertGreaterThan(server.port, 0)

        func post(_ path: String, _ body: BridgeJSON) throws -> (Int, Data) {
            var req = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)\(path)")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let done = expectation(description: path)
            var out: (Int, Data) = (0, Data())
            URLSession(configuration: .ephemeral).dataTask(with: req) { data, response, _ in
                out = ((response as? HTTPURLResponse)?.statusCode ?? 0, data ?? Data())
                done.fulfill()
            }.resume()
            wait(for: [done], timeout: 10)
            return out
        }

        let call: BridgeJSON = ["jsonrpc": "2.0", "id": 7, "method": "tools/call",
                                "params": ["name": "list_allowed_apps", "arguments": [:]]]
        let (status, data) = try post("/\(secret)/mcp", call)
        XCTAssertEqual(status, 200)
        let json = try JSONSerialization.jsonObject(with: data) as! BridgeJSON
        XCTAssertEqual(json["id"] as? Int, 7)
        XCTAssertNotNil(json["result"])

        let (wrong, wrongBody) = try post("/not-the-secret/mcp", call)
        XCTAssertEqual(wrong, 404)
        XCTAssertEqual(String(decoding: wrongBody, as: UTF8.self), "404 page not found\n")
    }
}
