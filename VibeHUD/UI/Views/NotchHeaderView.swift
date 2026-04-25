//
//  NotchHeaderView.swift
//  VibeHUD
//
//  Header bar for the dynamic island
//

import Combine
import SwiftUI

struct SessionSourceIcon: View {
    let source: SessionSource
    let size: CGFloat
    var animate: Bool = false

    init(source: SessionSource, size: CGFloat = 16, animate: Bool = false) {
        self.source = source
        self.size = size
        self.animate = animate
    }

    var body: some View {
        switch source {
        case .claude:
            ClaudeCrabIcon(size: size, animateLegs: animate)
        case .codex:
            CodexIcon(size: size)
        case .opencode:
            OpenCodeIcon(size: size)
        }
    }
}

struct ClaudeCrabIcon: View {
    let size: CGFloat
    let color: Color
    var animateLegs: Bool = false

    @State private var legPhase: Int = 0

    // Timer for leg animation
    private let legTimer = Timer.publish(every: 0.15, on: .main, in: .common).autoconnect()

    init(size: CGFloat = 16, color: Color = Color(red: 0.85, green: 0.47, blue: 0.34), animateLegs: Bool = false) {
        self.size = size
        self.color = color
        self.animateLegs = animateLegs
    }

    var body: some View {
        Canvas { context, canvasSize in
            let scale = size / 52.0  // Original viewBox height is 52
            let xOffset = (canvasSize.width - 66 * scale) / 2

            // Left antenna
            let leftAntenna = Path { p in
                p.addRect(CGRect(x: 0, y: 13, width: 6, height: 13))
            }.applying(CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: xOffset / scale, y: 0))
            context.fill(leftAntenna, with: .color(color))

            // Right antenna
            let rightAntenna = Path { p in
                p.addRect(CGRect(x: 60, y: 13, width: 6, height: 13))
            }.applying(CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: xOffset / scale, y: 0))
            context.fill(rightAntenna, with: .color(color))

            // Animated legs - alternating up/down pattern for walking effect
            // Legs stay attached to body (y=39), only height changes
            let baseLegPositions: [CGFloat] = [6, 18, 42, 54]
            let baseLegHeight: CGFloat = 13

            // Height offsets: positive = longer leg (down), negative = shorter leg (up)
            let legHeightOffsets: [[CGFloat]] = [
                [3, -3, 3, -3],   // Phase 0: alternating
                [0, 0, 0, 0],     // Phase 1: neutral
                [-3, 3, -3, 3],   // Phase 2: alternating (opposite)
                [0, 0, 0, 0],     // Phase 3: neutral
            ]

            let currentHeightOffsets = animateLegs ? legHeightOffsets[legPhase % 4] : [CGFloat](repeating: 0, count: 4)

            for (index, xPos) in baseLegPositions.enumerated() {
                let heightOffset = currentHeightOffsets[index]
                let legHeight = baseLegHeight + heightOffset
                let leg = Path { p in
                    p.addRect(CGRect(x: xPos, y: 39, width: 6, height: legHeight))
                }.applying(CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: xOffset / scale, y: 0))
                context.fill(leg, with: .color(color))
            }

            // Main body
            let body = Path { p in
                p.addRect(CGRect(x: 6, y: 0, width: 54, height: 39))
            }.applying(CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: xOffset / scale, y: 0))
            context.fill(body, with: .color(color))

            // Left eye
            let leftEye = Path { p in
                p.addRect(CGRect(x: 12, y: 13, width: 6, height: 6.5))
            }.applying(CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: xOffset / scale, y: 0))
            context.fill(leftEye, with: .color(.black))

            // Right eye
            let rightEye = Path { p in
                p.addRect(CGRect(x: 48, y: 13, width: 6, height: 6.5))
            }.applying(CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: xOffset / scale, y: 0))
            context.fill(rightEye, with: .color(.black))
        }
        .frame(width: size * (66.0 / 52.0), height: size)
        .onReceive(legTimer) { _ in
            if animateLegs {
                legPhase = (legPhase + 1) % 4
            }
        }
    }
}

struct CodexIcon: View {
    let size: CGFloat

    init(size: CGFloat = 16) {
        self.size = size
    }

    var body: some View {
        Canvas { context, canvasSize in
            let scale = min(canvasSize.width, canvasSize.height) / 24.0
            let drawingSize = CGSize(width: 24 * scale, height: 24 * scale)
            let origin = CGPoint(
                x: (canvasSize.width - drawingSize.width) / 2,
                y: (canvasSize.height - drawingSize.height) / 2
            )
            let transform = CGAffineTransform(translationX: origin.x, y: origin.y).scaledBy(x: scale, y: scale)

            let background = Path(roundedRect: CGRect(x: 0, y: 0, width: 24, height: 24), cornerRadius: 4.496)
                .applying(transform)
            context.fill(background, with: .color(.white))

            let codexShape = Path { p in
                p.move(to: CGPoint(x: 9.064, y: 3.344))
                p.addCurve(to: CGPoint(x: 11.349, y: 3.032), control1: CGPoint(x: 9.787, y: 3.047), control2: CGPoint(x: 10.573, y: 2.939))
                p.addCurve(to: CGPoint(x: 14.022, y: 4.307), control1: CGPoint(x: 12.349, y: 3.147), control2: CGPoint(x: 13.240, y: 3.572))
                p.addCurve(to: CGPoint(x: 14.059, y: 4.328), control1: CGPoint(x: 14.032, y: 4.317), control2: CGPoint(x: 14.046, y: 4.324))
                p.addCurve(to: CGPoint(x: 14.102, y: 4.328), control1: CGPoint(x: 14.073, y: 4.331), control2: CGPoint(x: 14.088, y: 4.331))
                p.addCurve(to: CGPoint(x: 15.649, y: 4.202), control1: CGPoint(x: 14.607, y: 4.198), control2: CGPoint(x: 15.130, y: 4.155))
                p.addCurve(to: CGPoint(x: 17.148, y: 4.603), control1: CGPoint(x: 16.168, y: 4.249), control2: CGPoint(x: 16.675, y: 4.384))
                p.addLine(to: CGPoint(x: 17.195, y: 4.625))
                p.addLine(to: CGPoint(x: 17.311, y: 4.682))
                p.addCurve(to: CGPoint(x: 18.625, y: 5.681), control1: CGPoint(x: 17.806, y: 4.933), control2: CGPoint(x: 18.251, y: 5.271))
                p.addCurve(to: CGPoint(x: 19.499, y: 7.081), control1: CGPoint(x: 18.998, y: 6.091), control2: CGPoint(x: 19.295, y: 6.565))
                p.addCurve(to: CGPoint(x: 19.814, y: 8.676), control1: CGPoint(x: 19.708, y: 7.591), control2: CGPoint(x: 19.812, y: 8.122))
                p.addCurve(to: CGPoint(x: 19.680, y: 9.899), control1: CGPoint(x: 19.829, y: 9.088), control2: CGPoint(x: 19.784, y: 9.500))
                p.addCurve(to: CGPoint(x: 19.680, y: 9.960), control1: CGPoint(x: 19.675, y: 9.919), control2: CGPoint(x: 19.675, y: 9.940))
                p.addCurve(to: CGPoint(x: 19.710, y: 10.014), control1: CGPoint(x: 19.685, y: 9.980), control2: CGPoint(x: 19.696, y: 9.999))
                p.addCurve(to: CGPoint(x: 20.893, y: 12.184), control1: CGPoint(x: 20.304, y: 10.621), control2: CGPoint(x: 20.698, y: 11.344))
                p.addCurve(to: CGPoint(x: 20.006, y: 16.038), control1: CGPoint(x: 21.182, y: 13.609), control2: CGPoint(x: 20.886, y: 14.894))
                p.addLine(to: CGPoint(x: 19.870, y: 16.204))
                p.addCurve(to: CGPoint(x: 18.871, y: 17.059), control1: CGPoint(x: 19.580, y: 16.536), control2: CGPoint(x: 19.244, y: 16.824))
                p.addCurve(to: CGPoint(x: 17.669, y: 17.592), control1: CGPoint(x: 18.498, y: 17.294), control2: CGPoint(x: 18.093, y: 17.473))
                p.addCurve(to: CGPoint(x: 17.619, y: 17.620), control1: CGPoint(x: 17.650, y: 17.597), control2: CGPoint(x: 17.634, y: 17.607))
                p.addCurve(to: CGPoint(x: 17.588, y: 17.668), control1: CGPoint(x: 17.605, y: 17.634), control2: CGPoint(x: 17.595, y: 17.650))
                p.addCurve(to: CGPoint(x: 16.848, y: 19.162), control1: CGPoint(x: 17.397, y: 18.219), control2: CGPoint(x: 17.205, y: 18.691))
                p.addCurve(to: CGPoint(x: 13.137, y: 21.000), control1: CGPoint(x: 15.948, y: 20.349), control2: CGPoint(x: 14.626, y: 21.008))
                p.addCurve(to: CGPoint(x: 9.980, y: 19.698), control1: CGPoint(x: 11.950, y: 20.994), control2: CGPoint(x: 10.898, y: 20.560))
                p.addCurve(to: CGPoint(x: 9.949, y: 19.678), control1: CGPoint(x: 9.971, y: 19.689), control2: CGPoint(x: 9.960, y: 19.683))
                p.addCurve(to: CGPoint(x: 9.912, y: 19.669), control1: CGPoint(x: 9.937, y: 19.673), control2: CGPoint(x: 9.925, y: 19.670))
                p.addCurve(to: CGPoint(x: 9.875, y: 19.674), control1: CGPoint(x: 9.900, y: 19.669), control2: CGPoint(x: 9.887, y: 19.670))
                p.addCurve(to: CGPoint(x: 8.671, y: 19.812), control1: CGPoint(x: 9.487, y: 19.799), control2: CGPoint(x: 9.095, y: 19.817))
                p.addCurve(to: CGPoint(x: 6.726, y: 19.346), control1: CGPoint(x: 7.996, y: 19.807), control2: CGPoint(x: 7.330, y: 19.647))
                p.addCurve(to: CGPoint(x: 5.116, y: 18.011), control1: CGPoint(x: 6.093, y: 19.032), control2: CGPoint(x: 5.542, y: 18.575))
                p.addCurve(to: CGPoint(x: 4.702, y: 17.394), control1: CGPoint(x: 4.964, y: 17.809), control2: CGPoint(x: 4.813, y: 17.619))
                p.addCurve(to: CGPoint(x: 4.332, y: 16.433), control1: CGPoint(x: 4.550, y: 17.085), control2: CGPoint(x: 4.427, y: 16.764))
                p.addCurve(to: CGPoint(x: 4.318, y: 14.135), control1: CGPoint(x: 4.132, y: 15.681), control2: CGPoint(x: 4.127, y: 14.890))
                p.addCurve(to: CGPoint(x: 4.324, y: 14.079), control1: CGPoint(x: 4.324, y: 14.117), control2: CGPoint(x: 4.326, y: 14.098))
                p.addCurve(to: CGPoint(x: 4.314, y: 14.053), control1: CGPoint(x: 4.322, y: 14.070), control2: CGPoint(x: 4.319, y: 14.061))
                p.addCurve(to: CGPoint(x: 4.297, y: 14.031), control1: CGPoint(x: 4.310, y: 14.045), control2: CGPoint(x: 4.304, y: 14.037))
                p.addCurve(to: CGPoint(x: 3.263, y: 12.380), control1: CGPoint(x: 3.835, y: 13.563), control2: CGPoint(x: 3.482, y: 13.000))
                p.addCurve(to: CGPoint(x: 3.012, y: 11.188), control1: CGPoint(x: 3.117, y: 11.998), control2: CGPoint(x: 3.033, y: 11.596))
                p.addCurve(to: CGPoint(x: 3.153, y: 9.588), control1: CGPoint(x: 2.976, y: 10.651), control2: CGPoint(x: 3.023, y: 10.111))
                p.addCurve(to: CGPoint(x: 5.086, y: 6.970), control1: CGPoint(x: 3.490, y: 8.476), control2: CGPoint(x: 4.135, y: 7.603))
                p.addCurve(to: CGPoint(x: 5.687, y: 6.640), control1: CGPoint(x: 5.298, y: 6.829), control2: CGPoint(x: 5.499, y: 6.719))
                p.addCurve(to: CGPoint(x: 6.333, y: 6.413), control1: CGPoint(x: 5.902, y: 6.551), control2: CGPoint(x: 6.117, y: 6.476))
                p.addCurve(to: CGPoint(x: 6.374, y: 6.388), control1: CGPoint(x: 6.348, y: 6.408), control2: CGPoint(x: 6.362, y: 6.400))
                p.addCurve(to: CGPoint(x: 6.398, y: 6.347), control1: CGPoint(x: 6.385, y: 6.377), control2: CGPoint(x: 6.393, y: 6.363))
                p.addCurve(to: CGPoint(x: 7.227, y: 4.732), control1: CGPoint(x: 6.562, y: 5.758), control2: CGPoint(x: 6.844, y: 5.209))
                p.addCurve(to: CGPoint(x: 9.064, y: 3.344), control1: CGPoint(x: 7.710, y: 4.119), control2: CGPoint(x: 8.343, y: 3.641))
                p.closeSubpath()

                p.move(to: CGPoint(x: 12.546, y: 13.909))
                p.addCurve(to: CGPoint(x: 12.243, y: 14.006), control1: CGPoint(x: 12.438, y: 13.915), control2: CGPoint(x: 12.334, y: 13.948))
                p.addCurve(to: CGPoint(x: 12.024, y: 14.237), control1: CGPoint(x: 12.152, y: 14.063), control2: CGPoint(x: 12.076, y: 14.143))
                p.addCurve(to: CGPoint(x: 11.945, y: 14.545), control1: CGPoint(x: 11.972, y: 14.331), control2: CGPoint(x: 11.945, y: 14.437))
                p.addCurve(to: CGPoint(x: 12.024, y: 14.853), control1: CGPoint(x: 11.945, y: 14.653), control2: CGPoint(x: 11.972, y: 14.759))
                p.addCurve(to: CGPoint(x: 12.243, y: 15.084), control1: CGPoint(x: 12.076, y: 14.947), control2: CGPoint(x: 12.152, y: 15.027))
                p.addCurve(to: CGPoint(x: 12.546, y: 15.181), control1: CGPoint(x: 12.334, y: 15.142), control2: CGPoint(x: 12.438, y: 15.175))
                p.addLine(to: CGPoint(x: 16.182, y: 15.181))
                p.addCurve(to: CGPoint(x: 16.471, y: 15.130), control1: CGPoint(x: 16.281, y: 15.187), control2: CGPoint(x: 16.380, y: 15.169))
                p.addCurve(to: CGPoint(x: 16.706, y: 14.954), control1: CGPoint(x: 16.562, y: 15.090), control2: CGPoint(x: 16.642, y: 15.030))
                p.addCurve(to: CGPoint(x: 16.838, y: 14.692), control1: CGPoint(x: 16.770, y: 14.878), control2: CGPoint(x: 16.815, y: 14.788))
                p.addCurve(to: CGPoint(x: 16.838, y: 14.398), control1: CGPoint(x: 16.860, y: 14.595), control2: CGPoint(x: 16.860, y: 14.495))
                p.addCurve(to: CGPoint(x: 16.706, y: 14.136), control1: CGPoint(x: 16.815, y: 14.302), control2: CGPoint(x: 16.770, y: 14.212))
                p.addCurve(to: CGPoint(x: 16.471, y: 13.960), control1: CGPoint(x: 16.642, y: 14.060), control2: CGPoint(x: 16.562, y: 14.000))
                p.addCurve(to: CGPoint(x: 16.182, y: 13.909), control1: CGPoint(x: 16.380, y: 13.921), control2: CGPoint(x: 16.281, y: 13.903))
                p.addLine(to: CGPoint(x: 12.546, y: 13.909))
                p.closeSubpath()

                p.move(to: CGPoint(x: 8.462, y: 9.230))
                p.addCurve(to: CGPoint(x: 8.229, y: 9.007), control1: CGPoint(x: 8.405, y: 9.137), control2: CGPoint(x: 8.324, y: 9.060))
                p.addCurve(to: CGPoint(x: 7.916, y: 8.926), control1: CGPoint(x: 8.133, y: 8.953), control2: CGPoint(x: 8.025, y: 8.926))
                p.addCurve(to: CGPoint(x: 7.603, y: 9.010), control1: CGPoint(x: 7.806, y: 8.927), control2: CGPoint(x: 7.699, y: 8.956))
                p.addCurve(to: CGPoint(x: 7.373, y: 9.236), control1: CGPoint(x: 7.508, y: 9.064), control2: CGPoint(x: 7.429, y: 9.142))
                p.addCurve(to: CGPoint(x: 7.282, y: 9.546), control1: CGPoint(x: 7.316, y: 9.330), control2: CGPoint(x: 7.285, y: 9.437))
                p.addCurve(to: CGPoint(x: 7.356, y: 9.861), control1: CGPoint(x: 7.279, y: 9.656), control2: CGPoint(x: 7.305, y: 9.764))
                p.addLine(to: CGPoint(x: 8.628, y: 12.085))
                p.addLine(to: CGPoint(x: 7.362, y: 14.221))
                p.addCurve(to: CGPoint(x: 7.275, y: 14.491), control1: CGPoint(x: 7.313, y: 14.303), control2: CGPoint(x: 7.284, y: 14.395))
                p.addCurve(to: CGPoint(x: 7.314, y: 14.771), control1: CGPoint(x: 7.267, y: 14.586), control2: CGPoint(x: 7.281, y: 14.682))
                p.addCurve(to: CGPoint(x: 7.471, y: 15.007), control1: CGPoint(x: 7.348, y: 14.861), control2: CGPoint(x: 7.402, y: 14.941))
                p.addCurve(to: CGPoint(x: 7.715, y: 15.151), control1: CGPoint(x: 7.541, y: 15.073), control2: CGPoint(x: 7.624, y: 15.122))
                p.addCurve(to: CGPoint(x: 7.997, y: 15.176), control1: CGPoint(x: 7.806, y: 15.181), control2: CGPoint(x: 7.902, y: 15.189))
                p.addCurve(to: CGPoint(x: 8.262, y: 15.075), control1: CGPoint(x: 8.092, y: 15.163), control2: CGPoint(x: 8.182, y: 15.128))
                p.addCurve(to: CGPoint(x: 8.457, y: 14.870), control1: CGPoint(x: 8.342, y: 15.022), control2: CGPoint(x: 8.408, y: 14.952))
                p.addLine(to: CGPoint(x: 9.911, y: 12.415))
                p.addCurve(to: CGPoint(x: 9.989, y: 12.207), control1: CGPoint(x: 9.949, y: 12.351), control2: CGPoint(x: 9.976, y: 12.280))
                p.addCurve(to: CGPoint(x: 9.991, y: 11.984), control1: CGPoint(x: 10.003, y: 12.133), control2: CGPoint(x: 10.003, y: 12.058))
                p.addCurve(to: CGPoint(x: 9.916, y: 11.775), control1: CGPoint(x: 9.978, y: 11.911), control2: CGPoint(x: 9.953, y: 11.840))
                p.addLine(to: CGPoint(x: 8.462, y: 9.230))
                p.closeSubpath()
            }
            .applying(transform)

            let gradient = Gradient(colors: [
                Color(red: 177 / 255, green: 167 / 255, blue: 1.0),
                Color(red: 122 / 255, green: 157 / 255, blue: 1.0),
                Color(red: 57 / 255, green: 65 / 255, blue: 1.0),
            ])
            context.fill(
                codexShape,
                with: .linearGradient(
                    gradient,
                    startPoint: origin,
                    endPoint: CGPoint(x: origin.x, y: origin.y + drawingSize.height)
                )
            )
        }
        .frame(width: size, height: size)
    }
}

struct OpenCodeIcon: View {
    let size: CGFloat
    let color: Color

    init(size: CGFloat = 16, color: Color = .white) {
        self.size = size
        self.color = color
    }

    var body: some View {
        Canvas { context, canvasSize in
            let scale = min(canvasSize.width, canvasSize.height) / 24.0
            let origin = CGPoint(
                x: (canvasSize.width - 24 * scale) / 2,
                y: (canvasSize.height - 24 * scale) / 2
            )
            let transform = CGAffineTransform(translationX: origin.x, y: origin.y).scaledBy(x: scale, y: scale)

            let path = Path { p in
                p.move(to: CGPoint(x: 16, y: 6))
                p.addLine(to: CGPoint(x: 8, y: 6))
                p.addLine(to: CGPoint(x: 8, y: 18))
                p.addLine(to: CGPoint(x: 16, y: 18))
                p.addLine(to: CGPoint(x: 16, y: 6))
                p.closeSubpath()

                p.move(to: CGPoint(x: 20, y: 22))
                p.addLine(to: CGPoint(x: 4, y: 22))
                p.addLine(to: CGPoint(x: 4, y: 2))
                p.addLine(to: CGPoint(x: 20, y: 2))
                p.addLine(to: CGPoint(x: 20, y: 22))
                p.closeSubpath()
            }
            .applying(transform)

            context.fill(path, with: .color(color), style: FillStyle(eoFill: true))
        }
        .frame(width: size, height: size)
    }
}

// Pixel art permission indicator icon
struct PermissionIndicatorIcon: View {
    let size: CGFloat
    let color: Color

    init(size: CGFloat = 14, color: Color = Color(red: 0.11, green: 0.12, blue: 0.13)) {
        self.size = size
        self.color = color
    }

    // Visible pixel positions from the SVG (at 30x30 scale)
    private let pixels: [(CGFloat, CGFloat)] = [
        (7, 7), (7, 11),           // Left column
        (11, 3),                    // Top left
        (15, 3), (15, 19), (15, 27), // Center column
        (19, 3), (19, 15),          // Right of center
        (23, 7), (23, 11)           // Right column
    ]

    var body: some View {
        Canvas { context, canvasSize in
            let scale = size / 30.0
            let pixelSize: CGFloat = 4 * scale

            for (x, y) in pixels {
                let rect = CGRect(
                    x: x * scale - pixelSize / 2,
                    y: y * scale - pixelSize / 2,
                    width: pixelSize,
                    height: pixelSize
                )
                context.fill(Path(rect), with: .color(color))
            }
        }
        .frame(width: size, height: size)
    }
}

// Pixel art "ready for input" indicator icon (checkmark/done shape)
struct ReadyForInputIndicatorIcon: View {
    let size: CGFloat
    let color: Color

    init(size: CGFloat = 14, color: Color = TerminalColors.green) {
        self.size = size
        self.color = color
    }

    // Checkmark shape pixel positions (at 30x30 scale)
    private let pixels: [(CGFloat, CGFloat)] = [
        (5, 15),                    // Start of checkmark
        (9, 19),                    // Down stroke
        (13, 23),                   // Bottom of checkmark
        (17, 19),                   // Up stroke begins
        (21, 15),                   // Up stroke
        (25, 11),                   // Up stroke
        (29, 7)                     // End of checkmark
    ]

    var body: some View {
        Canvas { context, canvasSize in
            let scale = size / 30.0
            let pixelSize: CGFloat = 4 * scale

            for (x, y) in pixels {
                let rect = CGRect(
                    x: x * scale - pixelSize / 2,
                    y: y * scale - pixelSize / 2,
                    width: pixelSize,
                    height: pixelSize
                )
                context.fill(Path(rect), with: .color(color))
            }
        }
        .frame(width: size, height: size)
    }
}
