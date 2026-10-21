import Foundation
import Network

/// What one PapayaPower instance shares with the others on the local network.
public struct PeerReadings: Codable, Sendable {
    public var host: String
    public var platform: String          // "macOS 15.8.1", "Linux …"
    public var version: String
    public var timestamp: Date
    public var batteries: [BatterySnapshot]
    public var ups: [UPSSnapshot]

    public init(host: String, platform: String, version: String, timestamp: Date = Date(),
                batteries: [BatterySnapshot], ups: [UPSSnapshot]) {
        self.host = host
        self.platform = platform
        self.version = version
        self.timestamp = timestamp
        self.batteries = batteries
        self.ups = ups
    }

    public static func decode(_ data: Data) throws -> PeerReadings {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return try d.decode(PeerReadings.self, from: data)
    }

    public func encode() throws -> Data {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return try e.encode(self)
    }
}

public enum PeerProtocol {
    public static let serviceType = "_papayapower._tcp"
    public static let path = "/v1/readings"

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// Only local-network clients may read: RFC 1918, link-local, loopback, CGNAT/tailnet, ULA.
    public static func isLocal(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let a):
            let b = [UInt8](a.rawValue)
            return b[0] == 10 || b[0] == 127 || (b[0] == 172 && (16...31).contains(b[1]))
                || (b[0] == 192 && b[1] == 168) || (b[0] == 169 && b[1] == 254)
                || (b[0] == 100 && (64...127).contains(b[1]))
        case .ipv6(let a):
            let b = [UInt8](a.rawValue)
            if a.isLoopback || a.isLinkLocal { return true }
            if (b[0] & 0xFE) == 0xFC { return true }                    // fc00::/7
            if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xFF && b[11] == 0xFF {   // v4-mapped
                return isLocal(.hostPort(host: .ipv4(IPv4Address(Data(b[12..<16]))!), port: 1))
            }
            return false
        default:
            return false
        }
    }
}

/// Serves this machine's readings over HTTP (read-only, local network only) and announces
/// the service with Bonjour.
public final class PeerServer: @unchecked Sendable {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "papayapower.peer-server")
    private let provider: @Sendable () -> PeerReadings?
    private let key: @Sendable () -> String

    /// `key`: when non-empty, requests must carry the same value in `X-Papaya-Key`.
    public init(key: @escaping @Sendable () -> String = { "" }, provider: @escaping @Sendable () -> PeerReadings?) {
        self.key = key
        self.provider = provider
    }

    public func start(name: String) {
        guard listener == nil else { return }
        do {
            let l = try NWListener(using: .tcp)
            l.service = NWListener.Service(name: name, type: PeerProtocol.serviceType)
            l.newConnectionHandler = { [weak self] c in self?.handle(c) }
            l.start(queue: queue)
            listener = l
        } catch {
            NSLog("PapayaPower: peer server: \(error)")
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ c: NWConnection) {
        guard PeerProtocol.isLocal(c.endpoint) else { c.cancel(); return }
        c.start(queue: queue)
        c.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self else { return }
            let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let line = request.split(separator: "\r\n").first ?? ""
            var status = "404 Not Found"
            var body = Data("not found\n".utf8)
            var type = "text/plain"
            let expected = self.key()
            let sent = request.split(separator: "\r\n")
                .first { $0.lowercased().hasPrefix("x-papaya-key:") }
                .map { $0.dropFirst("x-papaya-key:".count).trimmingCharacters(in: .whitespaces) } ?? ""
            if !expected.isEmpty && !PeerProtocol.constantTimeEqual(sent, expected) {
                status = "403 Forbidden"
                body = Data("network key required\n".utf8)
            } else if line.hasPrefix("GET \(PeerProtocol.path)"), let r = self.provider(), let json = try? r.encode() {
                status = "200 OK"
                body = json
                type = "application/json"
            }
            let head = "HTTP/1.0 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            c.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
        }
    }
}

/// Finds other PapayaPower instances with Bonjour and fetches their readings.
public final class PeerBrowser: @unchecked Sendable {
    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "papayapower.peer-browser")
    private let lock = NSLock()
    private var endpoints: [String: NWEndpoint] = [:]   // service name → endpoint
    private let ownName: String

    public init(ownName: String) {
        self.ownName = ownName
    }

    public func start() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjour(type: PeerProtocol.serviceType, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            var map: [String: NWEndpoint] = [:]
            for r in results {
                if case let .service(name, _, _, _) = r.endpoint, name != self.ownName {
                    map[name] = r.endpoint
                }
            }
            self.lock.lock()
            self.endpoints = map
            self.lock.unlock()
        }
        b.start(queue: queue)
        browser = b
    }

    public func stop() {
        browser?.cancel()
        browser = nil
    }

    private func snapshotEndpoints() -> [String: NWEndpoint] {
        lock.lock(); defer { lock.unlock() }
        return endpoints
    }

    public var names: [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(endpoints.keys)
    }

    /// Fetches every known peer. Unreachable peers are reported with their error.
    public func fetchAll(key: String = "", timeout: TimeInterval = 8) async -> [String: Result<PeerReadings, Error>] {
        let eps = snapshotEndpoints()
        var out: [String: Result<PeerReadings, Error>] = [:]
        await withTaskGroup(of: (String, Result<PeerReadings, Error>).self) { group in
            for (name, ep) in eps {
                group.addTask { (name, await Self.fetch(ep, key: key, timeout: timeout)) }
            }
            for await (name, r) in group { out[name] = r }
        }
        return out
    }

    struct PeerError: LocalizedError {
        var errorDescription: String?
    }

    static func fetch(_ ep: NWEndpoint, key: String, timeout: TimeInterval) async -> Result<PeerReadings, Error> {
        await withCheckedContinuation { cont in
            // Prefer IPv4: a Bonjour name often resolves first to a link-local IPv6 address
            // that some Wi-Fi interfaces never answer on.
            let params = NWParameters.tcp
            if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
                ip.version = .v4
            }
            let c = NWConnection(to: ep, using: params)
            let q = DispatchQueue(label: "papayapower.peer-fetch")
            let box = ResumeOnce(cont)
            var buffer = Data()
            q.asyncAfter(deadline: .now() + timeout) {
                c.cancel()
                box.resume(.failure(PeerError(errorDescription: "timed out")))
            }
            func receive() {
                c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, done, error in
                    if let data { buffer.append(data) }
                    if done || error != nil {
                        c.cancel()
                        guard let sep = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                            box.resume(.failure(error ?? PeerError(errorDescription: "empty reply")))
                            return
                        }
                        let head = String(decoding: buffer[..<sep.lowerBound], as: UTF8.self)
                        guard head.hasPrefix("HTTP/1.0 200") || head.hasPrefix("HTTP/1.1 200") else {
                            box.resume(.failure(PeerError(errorDescription: head.split(separator: "\r\n").first.map(String.init))))
                            return
                        }
                        do {
                            box.resume(.success(try PeerReadings.decode(buffer[sep.upperBound...])))
                        } catch {
                            box.resume(.failure(error))
                        }
                    } else {
                        receive()
                    }
                }
            }
            c.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let req = "GET \(PeerProtocol.path) HTTP/1.0\r\nHost: papayapower\r\n"
                        + (key.isEmpty ? "" : "X-Papaya-Key: \(key)\r\n") + "\r\n"
                    c.send(content: Data(req.utf8), completion: .contentProcessed { _ in receive() })
                case .failed(let e):
                    box.resume(.failure(e))
                    c.cancel()
                case .waiting(let e):
                    // Typically "Local network prohibited" (macOS privacy) or no route.
                    box.resume(.failure(PeerError(errorDescription: "waiting: \(e.localizedDescription)")))
                    c.cancel()
                default:
                    break
                }
            }
            c.start(queue: q)
        }
    }
}

/// Resumes a continuation exactly once, whichever callback wins.
final class ResumeOnce<T>: @unchecked Sendable {
    private var cont: CheckedContinuation<T, Never>?
    private let lock = NSLock()
    init(_ c: CheckedContinuation<T, Never>) { cont = c }
    func resume(_ v: T) {
        lock.lock()
        let c = cont
        cont = nil
        lock.unlock()
        c?.resume(returning: v)
    }
}
