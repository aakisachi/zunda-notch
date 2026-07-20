import AppKit

// サイレント時間帯（この間は音声も効果音も鳴らさない。表示は動く）
enum SilentHours {
    static var isActiveNow: Bool {
        let d = UserDefaults.standard
        guard d.bool(forKey: "silentHoursEnabled") else { return false }
        let start = d.integer(forKey: "silentStartMinutes")
        let end = d.integer(forKey: "silentEndMinutes")
        guard start != end else { return false }
        let comp = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let now = (comp.hour ?? 0) * 60 + (comp.minute ?? 0)
        // 22:00〜8:00 のような日またぎにも対応
        return start < end ? (now >= start && now < end) : (now >= start || now < end)
    }
}

// VOICEVOX エンジン（ローカル REST API）でずんだもんを喋らせる
enum VoiceVox {
    static let zundamonSpeaker = 3 // ずんだもん ノーマル
    private static let base = URL(string: "http://127.0.0.1:50021")!
    private static let enginePaths = [
        "/Applications/VOICEVOX.app/Contents/Resources/vv-engine/run",
    ]

    private static var engineProcess: Process?
    private static var currentSound: NSSound?
    private static var lastSpeakAt = Date.distantPast

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "zundaVoiceEnabled")
    }

    // 音声ONなら喋る／OFFならサウンドエフェクト（それもOFFなら無音）
    static func notify(_ text: String, sound: String) {
        if isEnabled {
            speakIfEnabled(text)
            return
        }
        if UserDefaults.standard.bool(forKey: "soundEffectsEnabled"), !SilentHours.isActiveNow {
            NSSound(named: sound)?.play()
        }
    }

    // 設定ONのときだけ喋る（連発防止・サイレント時間帯つき）
    static func speakIfEnabled(_ text: String) {
        guard isEnabled else { return }
        guard !SilentHours.isActiveNow else { return }
        guard Date().timeIntervalSince(lastSpeakAt) > 1.2 else { return }
        lastSpeakAt = Date()
        Task.detached(priority: .utility) {
            await speak(text)
        }
    }

    static func speak(_ text: String) async {
        guard await ensureEngine() else {
            NSLog("VoiceVox: engine unavailable, skip: \(text)")
            return
        }
        do {
            // 1. audio_query（読み上げ設計図の生成）
            var q = URLComponents(url: base.appendingPathComponent("audio_query"), resolvingAgainstBaseURL: false)!
            q.queryItems = [
                URLQueryItem(name: "text", value: text),
                URLQueryItem(name: "speaker", value: String(zundamonSpeaker)),
            ]
            var queryReq = URLRequest(url: q.url!)
            queryReq.httpMethod = "POST"
            queryReq.timeoutInterval = 10
            var (queryData, _) = try await URLSession.shared.data(for: queryReq)

            // 少しだけ早口に
            if var obj = try? JSONSerialization.jsonObject(with: queryData) as? [String: Any] {
                obj["speedScale"] = 1.15
                if let patched = try? JSONSerialization.data(withJSONObject: obj) {
                    queryData = patched
                }
            }

            // 2. synthesis（WAV 音声合成）
            var s = URLComponents(url: base.appendingPathComponent("synthesis"), resolvingAgainstBaseURL: false)!
            s.queryItems = [URLQueryItem(name: "speaker", value: String(zundamonSpeaker))]
            var synthReq = URLRequest(url: s.url!)
            synthReq.httpMethod = "POST"
            synthReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
            synthReq.httpBody = queryData
            synthReq.timeoutInterval = 20
            let (wav, _) = try await URLSession.shared.data(for: synthReq)

            await MainActor.run {
                currentSound?.stop()
                let sound = NSSound(data: wav)
                currentSound = sound
                sound?.play()
            }
        } catch {
            NSLog("VoiceVox: speak failed: \(error)")
        }
    }

    private static func engineAlive() async -> Bool {
        var req = URLRequest(url: base.appendingPathComponent("version"))
        req.timeoutInterval = 1.5
        return (try? await URLSession.shared.data(for: req)) != nil
    }

    // エンジン未起動ならヘッドレス起動（VOICEVOXのGUIは開かない）
    static func ensureEngine() async -> Bool {
        if await engineAlive() { return true }
        if engineProcess == nil {
            guard let path = enginePaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                return false
            }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = ["--host", "127.0.0.1", "--port", "50021"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do {
                try p.run()
                engineProcess = p
                NSLog("VoiceVox: engine launched headless")
            } catch {
                NSLog("VoiceVox: engine launch failed: \(error)")
                return false
            }
        }
        // 起動待ち（最大約14秒）
        for _ in 0..<20 {
            if await engineAlive() { return true }
            try? await Task.sleep(nanoseconds: 700_000_000)
        }
        return false
    }
}
