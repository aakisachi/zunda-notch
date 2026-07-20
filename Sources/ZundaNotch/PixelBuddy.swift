import SwiftUI

// ノッチに住む枝豆バディ（さや＋豆3粒・2コマでぷるぷる動く）
struct PixelBuddy: View {
    var tint: Color = .green
    var size: CGFloat = 16

    // X = さや（tint色） / o = 豆（明るい色）
    private static let frames: [[String]] = [
        [
            "....XXXX....",
            "..XXXXXXXX..",
            ".XooXooXooX.",
            ".XooXooXooX.",
            "..XXXXXXXX..",
            "....XXXX....",
        ],
        [
            "...XXXX.....",
            ".XXXXXXXX...",
            "XooXooXooX..",
            "XooXooXooX..",
            ".XXXXXXXX...",
            "...XXXX.....",
        ],
    ]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.7)) { context in
            let frame = Int(context.date.timeIntervalSince1970 / 0.7) % 2
            Canvas { ctx, canvasSize in
                let rows = Self.frames[frame]
                let cols = rows[0].count
                let cell = canvasSize.width / CGFloat(cols)
                for (y, row) in rows.enumerated() {
                    for (x, ch) in row.enumerated() where ch != "." {
                        let rect = CGRect(
                            x: CGFloat(x) * cell,
                            y: CGFloat(y) * cell,
                            width: cell * 0.98,
                            height: cell * 0.98
                        )
                        let color: Color = (ch == "o")
                            ? Color(red: 0.78, green: 0.95, blue: 0.6)
                            : tint
                        ctx.fill(Path(rect), with: .color(color))
                    }
                }
            }
            .frame(width: size, height: size / 2)
        }
    }
}
