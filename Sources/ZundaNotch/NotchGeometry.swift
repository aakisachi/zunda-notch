import AppKit

struct NotchGeometry {
    let screen: NSScreen
    let notchRect: NSRect // グローバル座標。ノッチ非搭載なら仮想ノッチ

    static func bestScreen() -> NotchGeometry {
        let screens = NSScreen.screens
        let target = screens.first(where: { $0.hasHardwareNotch }) ?? NSScreen.main ?? screens[0]
        return NotchGeometry(screen: target, notchRect: target.effectiveNotchRect)
    }
}

extension NSScreen {
    var hasHardwareNotch: Bool {
        guard let left = auxiliaryTopLeftArea, let right = auxiliaryTopRightArea else { return false }
        return right.minX - left.maxX > 0
    }

    // メニューバーの実高さ（青いバー）。これに揃えるのが正解
    var menuBarHeight: CGFloat {
        let h = frame.maxY - visibleFrame.maxY
        return h > 0 ? h : 24
    }

    var effectiveNotchRect: NSRect {
        if let left = auxiliaryTopLeftArea, let right = auxiliaryTopRightArea,
           right.minX - left.maxX > 0 {
            let height = max(safeAreaInsets.top, menuBarHeight)
            return NSRect(x: left.maxX,
                          y: frame.maxY - height,
                          width: right.minX - left.maxX,
                          height: height)
        }
        // 物理ノッチの切り欠きが無い表示モード：メニューバー高さにビチッと揃える
        let width: CGFloat = 190
        let height = menuBarHeight
        return NSRect(x: frame.midX - width / 2,
                      y: frame.maxY - height,
                      width: width,
                      height: height)
    }
}
