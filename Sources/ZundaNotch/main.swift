import AppKit

UserDefaults.standard.register(defaults: [
    "zundaVoiceEnabled": true,
    "notchApprovalEnabled": true,
    "soundEffectsEnabled": true,
    "autoExpandOnEvent": true,
    "silentHoursEnabled": false,
    "silentStartMinutes": 22 * 60, // 22:00
    "silentEndMinutes": 8 * 60,    // 8:00
    "claudeBudget5hM": 15,    // Claude 5時間枠の目安（百万tok）
    "claudeBudget7dM": 500,  // Claude 7日枠の目安（百万tok）
])

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
