import AppKit
import ServiceManagement
import SwiftUI

// 歯車から開く設定ウィンドウ（本家の設定画面のコンパクト版）
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    func open() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let view = SettingsView()
        let hosting = NSHostingController(rootView: view)
        let w = NSWindow(contentViewController: hosting)
        w.title = "ずんだノッチ 設定"
        w.styleMask = [.titled, .closable]
        w.setContentSize(NSSize(width: 440, height: 640))
        w.center()
        w.isReleasedWhenClosed = false
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

struct SettingsView: View {
    @AppStorage("zundaVoiceEnabled") private var zundaVoice = true
    @AppStorage("notchApprovalEnabled") private var notchApproval = true
    @AppStorage("soundEffectsEnabled") private var soundEffects = true
    @AppStorage("autoExpandOnEvent") private var autoExpand = true
    @AppStorage("silentHoursEnabled") private var silentHours = false
    @AppStorage("claudeBudget5hM") private var claudeBudget5hM = 15
    @AppStorage("claudeBudget7dM") private var claudeBudget7dM = 500
    @AppStorage("showUsageStrip") private var showUsageStrip = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemError = ""
    @State private var tokenInput = ""
    @State private var tokenConfigured = ClaudeToken.isConfigured
    @ObservedObject private var usage = UsageMonitor.shared

    var body: some View {
        Form {
            Section("通知") {
                Toggle("ずんだもん音声", isOn: $zundaVoice)
                Text("完了「できたのだ！」承認待ち「許可がほしいのだ！」と喋るのだ")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("サウンドエフェクト", isOn: $soundEffects)
                Text("音声OFFのときに短い効果音で知らせるのだ")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("通知でパネルを自動展開", isOn: $autoExpand)
                Text("OFFにするとパネルは閉じたまま、ノッチが控えめに光るのだ。承認は引き続き自動で展開するのだ")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("使用量ゲージ") {
                Toggle("ノッチに使用量ゲージを表示", isOn: $showUsageStrip)
                Text("OFFにするとノッチの Claude/Codex 使用率バーを隠すのだ（この設定画面の数値は残る）")
                    .font(.caption).foregroundStyle(.secondary)
                if let s = usage.stats {
                    if let p5 = s.claudeOfficial5hPct {
                        LabeledContent("Claude 5時間枠（公式）") {
                            Text("\(p5)%・残 \(UsageFormat.remain(s.claudeOfficial5hReset))")
                        }
                    } else {
                        LabeledContent("Claude 5時間枠") {
                            Text("\(TokenFormat.short(s.claude5hTokens)) tok 使用")
                        }
                    }
                    if let p7 = s.claudeOfficial7dPct {
                        LabeledContent("Claude 7日枠（公式）") {
                            Text("\(p7)%・残 \(UsageFormat.remain(s.claudeOfficial7dReset))")
                        }
                    } else {
                        LabeledContent("Claude 7日枠") {
                            Text("\(TokenFormat.short(s.claude7dTokens)) tok 使用")
                        }
                    }
                    if let pct = s.codex7dPct {
                        LabeledContent("Codex 7日枠（公式）") {
                            Text("\(pct)%・残 \(UsageFormat.remain(s.codex7dReset))")
                        }
                    }
                    if let pct = s.codex5hPct {
                        LabeledContent("Codex 5時間枠（公式）") {
                            Text("\(pct)%・残 \(UsageFormat.remain(s.codex5hReset))")
                        }
                    }
                    Text("最終更新: \(s.fetchedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("集計中…").font(.caption).foregroundStyle(.secondary)
                }
                Button("いますぐ更新") { usage.refresh() }
            }

            Section("Claude 公式%を有効にする（任意）") {
                if tokenConfigured {
                    HStack {
                        Label("公式トークン設定済み", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        Spacer()
                        Button("削除") {
                            ClaudeToken.delete()
                            tokenConfigured = false
                            usage.refresh()
                        }
                    }
                    Text("Claudeゲージは公式%で表示中なのだ")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    SecureField("sk-ant-oat01-… を貼り付け", text: $tokenInput)
                    Button("Keychainに保存") {
                        if ClaudeToken.save(tokenInput) {
                            tokenInput = ""
                            tokenConfigured = true
                            usage.refresh()
                        }
                    }
                    .disabled(tokenInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    Text("ターミナルで claude setup-token を実行→ブラウザで承認→表示されたトークンをここへ。MacのKeychainに保存され、Anthropic公式APIへの問い合わせのみに使うのだ（他への送信・表示は一切なし）")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Claude ゲージの目安上限（公式トークン未設定時）") {
                Stepper(value: $claudeBudget5hM, in: 1...100) {
                    LabeledContent("5時間枠の目安", value: "\(claudeBudget5hM)M tok")
                }
                Stepper(value: $claudeBudget7dM, in: 10...2000, step: 10) {
                    LabeledContent("7日枠の目安", value: "\(claudeBudget7dM)M tok")
                }
                Text("Claudeの公式上限%はこの環境では取得できないため、実測トークン÷この目安でゲージを描くのだ。Codexは公式%そのまま")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("サイレント時間帯") {
                Toggle("指定時間帯はサウンドをミュート", isOn: $silentHours)
                if silentHours {
                    DatePicker("開始", selection: timeBinding("silentStartMinutes"),
                               displayedComponents: .hourAndMinute)
                    DatePicker("終了", selection: timeBinding("silentEndMinutes"),
                               displayedComponents: .hourAndMinute)
                    Text("この間はずんだもん音声も効果音も鳴らないのだ（ノッチの表示は動く）")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("承認") {
                Toggle("ノッチから承認（許可/拒否ボタン）", isOn: $notchApproval)
                Text("OFFにすると今まで通りターミナル側で確認するのだ。\(Int(ApprovalCenter.autoReleaseSeconds))秒無応答でも自動でターミナルに戻るのだ")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("起動") {
                Toggle("ログイン時に自動起動", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                            loginItemError = ""
                        } catch {
                            loginItemError = "設定できなかったのだ: \(error.localizedDescription)"
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                if !loginItemError.isEmpty {
                    Text(loginItemError).font(.caption).foregroundStyle(.red)
                }
            }

            Section("情報") {
                LabeledContent("バージョン", value: "0.5.2")
                LabeledContent("対応エージェント", value: "Claude Code / Codex")
                Text("音声: VOICEVOX:ずんだもん")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Claude Code hooks・Codex notify 経由でローカル完結。クラウド送信なし")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Button(role: .destructive) {
                    NSApp.terminate(nil)
                } label: {
                    Label("ずんだノッチを終了", systemImage: "power")
                        .frame(maxWidth: .infinity)
                }
                Text("ノッチから完全に退場するのだ。次はLaunchpadか「open -a ずんだノッチ」で復帰")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 640)
    }

    // 「HH:mm」⇔ 深夜0時からの分数（UserDefaults保存用）
    private func timeBinding(_ key: String) -> Binding<Date> {
        Binding {
            let minutes = UserDefaults.standard.integer(forKey: key)
            return Calendar.current.date(
                bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()
            ) ?? Date()
        } set: { date in
            let c = Calendar.current.dateComponents([.hour, .minute], from: date)
            UserDefaults.standard.set((c.hour ?? 0) * 60 + (c.minute ?? 0), forKey: key)
        }
    }
}
