import Foundation
import Network

// Claude Code の hooks から届くイベント（zn-bridge.sh 経由で POST される）
struct HookEvent: Decodable {
    let hookEventName: String
    let sessionID: String
    let cwd: String?
    let notificationType: String?
    let message: String?
    let lastAssistantMessage: String?
    let userPrompt: String?
    let toolName: String?
    let source: String?
    let reason: String?
    var tty: String?
    var termProgram: String?

    enum CodingKeys: String, CodingKey {
        case hookEventName = "hook_event_name"
        case sessionID = "session_id"
        case cwd
        case notificationType = "notification_type"
        case message
        case lastAssistantMessage = "last_assistant_message"
        case userPrompt = "user_prompt"
        case toolName = "tool_name"
        case source, reason
    }
}

// PermissionRequest hook からの承認依頼
struct PermissionPayload {
    let sessionID: String
    let toolName: String
    let detail: String
    let cwd: String?
}

struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    static func parse(_ data: Data) -> HTTPRequest? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let idx = line.firstIndex(of: ":") else { continue }
            let key = line[..<idx].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: idx)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = data.distance(from: data.startIndex, to: headerEnd.upperBound)
        guard data.count - bodyStart >= contentLength else { return nil }
        let body = data.subdata(in: bodyStart..<(bodyStart + contentLength))
        return HTTPRequest(method: String(parts[0]), path: String(parts[1]), headers: headers, body: body)
    }
}

final class EventServer: @unchecked Sendable {
    static let port: UInt16 = 48765

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "zn.event-server")
    private let onEvent: @Sendable (HookEvent) -> Void

    // 承認依頼: (内容, 応答クロージャ) を受け取る。応答クロージャに nil を渡すと空応答＝通常確認へフォールバック
    var onPermission: (@Sendable (PermissionPayload, @escaping @Sendable (String?) -> Void) -> Void)?
    // Codex notify の生JSON
    var onCodex: (@Sendable ([String: Any]) -> Void)?
    var debugSnapshot: (@Sendable () -> String)?

    init(onEvent: @escaping @Sendable (HookEvent) -> Void) {
        self.onEvent = onEvent
    }

    func start() {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            params.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: .ipv4(.loopback),
                port: NWEndpoint.Port(rawValue: Self.port)!
            )
            let l = try NWListener(using: params)
            l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            l.start(queue: queue)
            listener = l
            NSLog("ZundaNotch: event server listening on 127.0.0.1:\(Self.port)")
        } catch {
            NSLog("ZundaNotch: event server failed to start: \(error)")
        }
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 128 * 1024) { [weak self] data, _, complete, error in
            guard let self else { conn.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }
            if let request = HTTPRequest.parse(buf) {
                self.route(request, conn)
            } else if complete || error != nil || buf.count > 1024 * 1024 {
                conn.cancel()
            } else {
                self.receive(conn, buffer: buf)
            }
        }
    }

    private func route(_ request: HTTPRequest, _ conn: NWConnection) {
        // ローカルCSRF対策: 正規の呼び出し元（zn-bridge.sh の curl）は
        // Origin / Sec-Fetch-* ヘッダーを送らない。ブラウザは必ず送るので、
        // それらが付いたリクエスト＝悪意あるWebページ由来として拒否する。
        // （127.0.0.1 バインドでリモートは既に届かないが、同一マシンの
        //   ブラウザからの偽イベント/偽承認プロンプト注入を塞ぐ）
        if request.headers["origin"] != nil || request.headers["sec-fetch-site"] != nil {
            respond(conn, status: "403 Forbidden", body: "{\"error\":\"forbidden\"}")
            return
        }

        switch (request.method, request.path) {
        case ("POST", "/event"):
            if var event = try? JSONDecoder().decode(HookEvent.self, from: request.body) {
                event.tty = request.headers["x-zn-tty"]
                event.termProgram = request.headers["x-zn-term"]
                onEvent(event)
                respond(conn, status: "200 OK", body: "{}")
            } else {
                respond(conn, status: "400 Bad Request", body: "{\"error\":\"bad json\"}")
            }

        case ("POST", "/permission"):
            // ノッチ承認OFF・解析不能・ハンドラ未設定なら即空応答＝通常の確認フローへ
            guard UserDefaults.standard.bool(forKey: "notchApprovalEnabled"),
                  let onPermission,
                  let obj = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let sid = obj["session_id"] as? String else {
                respond(conn, status: "200 OK", body: "")
                return
            }
            let tool = obj["tool_name"] as? String ?? "?"
            var detail = ""
            if let input = obj["tool_input"] as? [String: Any] {
                detail = (input["command"] as? String)
                    ?? (input["file_path"] as? String)
                    ?? (input["url"] as? String)
                    ?? (input["prompt"] as? String)
                    ?? input.keys.sorted().joined(separator: ", ")
            }
            let payload = PermissionPayload(
                sessionID: sid,
                toolName: tool,
                detail: String(detail.prefix(120)),
                cwd: obj["cwd"] as? String
            )
            let responder: @Sendable (String?) -> Void = { [weak self] body in
                guard let self else { conn.cancel(); return }
                self.queue.async {
                    self.respond(conn, status: "200 OK", body: body ?? "")
                }
            }
            onPermission(payload, responder)

        case ("POST", "/codex"):
            if var obj = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] {
                obj["_tty"] = request.headers["x-zn-tty"]
                obj["_term"] = request.headers["x-zn-term"]
                onCodex?(obj)
            }
            respond(conn, status: "200 OK", body: "{}")

        case ("GET", "/health"):
            respond(conn, status: "200 OK", body: "{\"ok\":true}")

        case ("GET", "/sessions"):
            var snapshot = "{}"
            if let provider = debugSnapshot {
                DispatchQueue.main.sync { snapshot = provider() }
            }
            respond(conn, status: "200 OK", body: snapshot)

        default:
            respond(conn, status: "404 Not Found", body: "{\"error\":\"not found\"}")
        }
    }

    private func respond(_ conn: NWConnection, status: String, body: String) {
        let data = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
        var payload = Data(head.utf8)
        payload.append(data)
        conn.send(content: payload, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }
}
