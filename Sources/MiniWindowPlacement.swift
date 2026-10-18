import Foundation
import CoreGraphics

enum MiniWindowPlacement {
    static func visibleFrame(_ frame: CGRect, screens: [CGRect]) -> CGRect? {
        let screens = screens.filter { $0.minX.isFinite && $0.minY.isFinite && $0.width.isFinite && $0.height.isFinite && $0.width > 0 && $0.height > 0 }
        guard let first = screens.first else { return nil }
        guard frame.origin.x.isFinite, frame.origin.y.isFinite, frame.width.isFinite, frame.height.isFinite,
              frame.width > 0, frame.height > 0 else {
            return CGRect(x: first.maxX - min(420, first.width), y: first.maxY - min(240, first.height),
                          width: min(420, first.width), height: min(240, first.height))
        }
        let screen = screens.max { a, b in
            let aa = frame.intersection(a), bb = frame.intersection(b)
            return (aa.isNull ? 0 : aa.width * aa.height) < (bb.isNull ? 0 : bb.width * bb.height)
        } ?? first
        let target = frame.intersects(screen) ? screen : first
        let width = min(frame.width, target.width), height = min(frame.height, target.height)
        return CGRect(x: min(max(frame.minX, target.minX), target.maxX - width),
                      y: min(max(frame.minY, target.minY), target.maxY - height), width: width, height: height)
    }
}
