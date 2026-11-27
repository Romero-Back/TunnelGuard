import SwiftUI

/// A short visual acknowledgement of a completed network check.
struct VerificationPulse: View {
    let checkedAt: Date?
    let tint: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let frameCount = 36
    private static let duration = 1.12

    var body: some View {
        if let checkedAt, !reduceMotion, Date().timeIntervalSince(checkedAt) < Self.duration {
            TimelineView(.explicit((0...Self.frameCount).map {
                checkedAt.addingTimeInterval(Self.duration * Double($0) / Double(Self.frameCount))
            })) { frame in
                let progress = max(0, min(1, frame.date.timeIntervalSince(checkedAt) / Self.duration))
                Canvas { context, size in
                    let center = CGPoint(x: size.width / 2, y: size.height / 2)
                    let radius = min(size.width, size.height) / 2

                    for delay in [0.0, 0.16] {
                        let phase = (progress - delay) / (1 - delay)
                        guard phase >= 0 else { continue }
                        let distance = radius * (0.42 + 0.54 * phase)
                        let ring = CGRect(x: center.x - distance, y: center.y - distance,
                                          width: 2 * distance, height: 2 * distance)
                        let opacity = (1 - phase) * (delay == 0 ? 0.8 : 0.5)
                        context.stroke(Path(ellipseIn: ring), with: .color(tint.opacity(opacity)), lineWidth: 1.4)
                    }

                    let distance = radius * (0.48 + 0.45 * progress)
                    for index in 0..<8 {
                        let angle = Double(index) * .pi / 4 + .pi / 8 + progress * 0.15
                        let x = center.x + distance * cos(angle)
                        let y = center.y + distance * sin(angle)
                        let dotSize = radius * (0.075 - 0.045 * progress)
                        let dot = CGRect(x: x - dotSize / 2, y: y - dotSize / 2,
                                         width: dotSize, height: dotSize)
                        context.fill(Path(ellipseIn: dot), with: .color(tint.opacity(0.85 * (1 - progress))))
                    }
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
