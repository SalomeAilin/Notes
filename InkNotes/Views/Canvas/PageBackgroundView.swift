import SwiftUI

struct PageBackgroundView: View {
  let background: PageBackground

  var body: some View {
    Canvas { context, size in
      switch background {
      case .blank:
        break
      case .ruled:
        drawRuledPaper(in: &context, size: size)
      case .grid:
        drawGridPaper(in: &context, size: size)
      }
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  private func drawRuledPaper(in context: inout GraphicsContext, size: CGSize) {
    let spacing: CGFloat = 32
    var path = Path()
    var y: CGFloat = spacing
    while y < size.height {
      path.move(to: CGPoint(x: 0, y: y))
      path.addLine(to: CGPoint(x: size.width, y: y))
      y += spacing
    }
    context.stroke(path, with: .color(.blue.opacity(0.16)), lineWidth: 0.7)

    var margin = Path()
    margin.move(to: CGPoint(x: 48, y: 0))
    margin.addLine(to: CGPoint(x: 48, y: size.height))
    context.stroke(margin, with: .color(.red.opacity(0.18)), lineWidth: 0.8)
  }

  private func drawGridPaper(in context: inout GraphicsContext, size: CGSize) {
    let spacing: CGFloat = 28
    var path = Path()
    var x: CGFloat = spacing
    while x < size.width {
      path.move(to: CGPoint(x: x, y: 0))
      path.addLine(to: CGPoint(x: x, y: size.height))
      x += spacing
    }
    var y: CGFloat = spacing
    while y < size.height {
      path.move(to: CGPoint(x: 0, y: y))
      path.addLine(to: CGPoint(x: size.width, y: y))
      y += spacing
    }
    context.stroke(path, with: .color(.blue.opacity(0.13)), lineWidth: 0.6)
  }
}
