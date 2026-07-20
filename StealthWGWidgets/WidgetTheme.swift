import SwiftUI

enum WidgetTheme {
    static func accent(_ name: String) -> Color {
        switch name {
        case "teal": return Color(red: 0.22, green: 0.88, blue: 0.78)
        case "amber": return Color(red: 0.96, green: 0.70, blue: 0.29)
        default: return Color(red: 1.0, green: 0.42, blue: 0.44) // coral
        }
    }
}

/// The Wraith ghost, tinted by the current state.
struct GhostMark: View {
    var color: Color
    var filled: Bool = true
    var body: some View {
        ZStack {
            if filled {
                GhostShape().fill(color)
            } else {
                GhostShape().stroke(color, lineWidth: 6)
            }
            EyesShape().fill(Color.black.opacity(filled ? 1 : 0))
        }
        .aspectRatio(120.0 / 130.0, contentMode: .fit)
    }
}

struct GhostShape: Shape {
    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x / 120 * w, y: r.minY + y / 130 * h) }
        var path = Path()
        path.move(to: p(60, 10))
        path.addCurve(to: p(18, 56), control1: p(34, 10), control2: p(18, 30))
        path.addLine(to: p(18, 104))
        path.addQuadCurve(to: p(39, 104), control: p(28.5, 116))
        path.addQuadCurve(to: p(60, 104), control: p(49.5, 116))
        path.addQuadCurve(to: p(81, 104), control: p(70.5, 116))
        path.addQuadCurve(to: p(102, 104), control: p(91.5, 116))
        path.addLine(to: p(102, 56))
        path.addCurve(to: p(60, 10), control1: p(102, 30), control2: p(86, 10))
        path.closeSubpath()
        return path
    }
}

struct EyesShape: Shape {
    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height
        func e(_ cx: CGFloat, _ cy: CGFloat) -> CGRect {
            CGRect(x: r.minX + (cx - 7) / 120 * w, y: r.minY + (cy - 7) / 130 * h, width: 14 / 120 * w, height: 14 / 130 * h)
        }
        var path = Path()
        path.addEllipse(in: e(47, 54))
        path.addEllipse(in: e(73, 54))
        return path
    }
}
