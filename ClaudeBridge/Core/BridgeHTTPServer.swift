import Foundation
import Network

/// Minimal HTTP/1.1 listener bound to 127.0.0.1 only. One request per
/// connection, `Connection: close`. It never listens on any other interface;
/// the public side (Funnel) connects to it over loopback.
final class BridgeHTTPServer {
    static let maxHeaderBytes = 16 * 1024
    static let maxBodyBytes = 1024 * 1024
    static let receiveTimeout: TimeInterval = 20

    private let requestedPort: UInt16
    private let handler: (BridgeHTTPRequest) -> BridgeHTTPResponse
    private let queue = DispatchQueue(label: "claude-bridge.http")
    /// Tool calls block for seconds; they run here, off the network queue.
    private let workQueue = DispatchQueue(label: "claude-bridge.http.work", attributes: .concurrent)
    private var listener: NWListener?
    /// Receives lifecycle messages. Never passed a path, header or body.
    var onLog: ((String) -> Void)?

    /// - Parameter port: 0 lets the system pick a free port (used by tests).
    init(port: UInt16, handler: @escaping (BridgeHTTPRequest) -> BridgeHTTPResponse) {
        requestedPort = port
        self.handler = handler
    }

    /// The bound port once `start` has returned.
    private(set) var port: UInt16 = 0

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Binding to a loopback endpoint is what keeps this off the network.
        params.requiredLocalEndpoint = .hostPort(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: requestedPort) ?? .any)
        let listener = try NWListener(using: params)
        let ready = DispatchSemaphore(value: 0)
        var failure: NWError?
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .failed(let error): failure = error; ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        if ready.wait(timeout: .now() + 5) == .timedOut {
            listener.cancel()
            throw NWError.posix(.ETIMEDOUT)
        }
        if let failure = failure {
            listener.cancel()
            throw failure
        }
        self.listener = listener
        port = listener.port?.rawValue ?? requestedPort
        onLog?("Claude Bridge MCP listening on 127.0.0.1:\(port)")
    }

    func stop() {
        listener?.cancel()
        listener = nil
        onLog?("Claude Bridge MCP stopped")
    }

    private func accept(_ connection: NWConnection) {
        // Belt and braces: the bind is loopback-only, and so must the peer be.
        if case .hostPort(let host, _) = connection.endpoint, !Self.isLoopback(host) {
            connection.cancel()
            return
        }
        connection.start(queue: queue)
        let deadline = DispatchWorkItem { connection.cancel() }
        queue.asyncAfter(deadline: .now() + Self.receiveTimeout, execute: deadline)
        receive(connection, buffer: Data(), deadline: deadline)
    }

    private static func isLoopback(_ host: NWEndpoint.Host) -> Bool {
        switch host {
        case .ipv4(let address): return address == .loopback
        case .ipv6(let address): return address == .loopback
        case .name(let name, _): return name == "localhost"
        @unknown default: return false
        }
    }

    private func receive(_ connection: NWConnection, buffer: Data, deadline: DispatchWorkItem) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            var buffer = buffer
            if let data = data { buffer.append(data) }

            switch Self.parse(buffer) {
            case .request(let request):
                deadline.cancel()
                self.workQueue.async {
                    let response = self.handler(request)
                    self.send(response, on: connection)
                }
            case .invalid:
                deadline.cancel()
                self.send(.notFound, on: connection)
            case .incomplete:
                if error != nil || isComplete {
                    deadline.cancel()
                    connection.cancel()
                } else {
                    self.receive(connection, buffer: buffer, deadline: deadline)
                }
            }
        }
    }

    private func send(_ response: BridgeHTTPResponse, on connection: NWConnection) {
        connection.send(content: Self.serialize(response), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: Wire format (pure, unit-tested)

    enum ParseResult {
        case request(BridgeHTTPRequest)
        case incomplete
        /// Malformed or over a size limit. Answered with the generic 404.
        case invalid
    }

    static func parse(_ buffer: Data) -> ParseResult {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = buffer.range(of: separator) else {
            return buffer.count > maxHeaderBytes ? .invalid : .incomplete
        }
        guard headerEnd.lowerBound <= maxHeaderBytes,
              let head = String(data: buffer[buffer.startIndex..<headerEnd.lowerBound], encoding: .utf8) else {
            return .invalid
        }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { return .invalid }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .invalid }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        // Bodies must declare their length; chunked uploads are not accepted.
        if headers["transfer-encoding"] != nil { return .invalid }
        var length = 0
        if let declared = headers["content-length"] {
            guard let n = Int(declared), n >= 0, n <= maxBodyBytes else { return .invalid }
            length = n
        }
        let bodyStart = headerEnd.upperBound
        guard buffer.endIndex - bodyStart >= length else { return .incomplete }

        let target = String(requestLine[1])
        let path = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? target
        return .request(BridgeHTTPRequest(
            method: String(requestLine[0]),
            path: path,
            headers: headers,
            body: Data(buffer[bodyStart..<(bodyStart + length)])))
    }

    static func serialize(_ response: BridgeHTTPResponse) -> Data {
        let reason: String
        switch response.status {
        case 200: reason = "OK"
        case 202: reason = "Accepted"
        case 400: reason = "Bad Request"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        default: reason = "Status"
        }
        var head = "HTTP/1.1 \(response.status) \(reason)\r\n"
        var headers = response.headers
        headers["Content-Length"] = String(response.body.count)
        headers["Connection"] = "close"
        headers["Cache-Control"] = "no-store"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(response.body)
        return data
    }
}
