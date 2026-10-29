import SwiftUI

private struct SunburstSegment: Identifiable {
    let id: String
    let node: DiskNode
    let start: Double
    let end: Double
    let depth: Int
    let branch: Int
    let sibling: Int
}

struct SunburstView: View {
    let root: DiskNode
    let selection: DiskNode?
    let onSelect: (DiskNode) -> Void
    let onOpen: (DiskNode) -> Void

    @State private var hovered: DiskNode?

    private var segments: [SunburstSegment] {
        var result: [SunburstSegment] = []
        let total = max(root.size, 1)
        var cursor = -Double.pi / 2
        for (branch, child) in root.children.enumerated() where child.size > 0 {
            let span = Double.pi * 2 * Double(child.size) / Double(total)
            append(
                node: child, start: cursor, span: span,
                depth: 0, branch: branch, sibling: branch, result: &result
            )
            cursor += span
        }
        return result
    }

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let center = CGPoint(x: proxy.size.width * 0.48, y: proxy.size.height * 0.50)
            let outerRadius = side * 0.475
            let innerRadius = side * 0.10
            let ringWidth = (outerRadius - innerRadius) / 5

            ZStack {
                Canvas { context, _ in
                    for segment in segments {
                        let path = ringPath(
                            center: center,
                            inner: innerRadius + CGFloat(segment.depth) * ringWidth,
                            outer: innerRadius + CGFloat(segment.depth + 1) * ringWidth - 1.2,
                            start: segment.start,
                            end: segment.end
                        )
                        let highlighted = segment.node.id == selection?.id || segment.node.id == hovered?.id
                        context.fill(path, with: .color(color(for: segment).opacity(highlighted ? 1 : 0.94)))
                        context.stroke(path, with: .color(.black.opacity(0.34)), lineWidth: highlighted ? 1.5 : 0.7)
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        hovered = hitTest(location, center: center, inner: innerRadius, ring: ringWidth)
                    case .ended:
                        hovered = nil
                    }
                }
                .gesture(SpatialTapGesture().onEnded { event in
                    guard let node = hitTest(event.location, center: center, inner: innerRadius, ring: ringWidth) else { return }
                    onSelect(node)
                    if node.isDirectory { onOpen(node) }
                })

                let centerNode = hovered ?? selection
                VStack(spacing: 2) {
                    Text(ByteText.string(centerNode?.size ?? root.size))
                        .font(.system(size: side * 0.037, weight: .light, design: .rounded))
                        .multilineTextAlignment(.center)
                    if let centerNode {
                        Text(centerNode.name)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(maxWidth: innerRadius * 1.55)
                    }
                }
                .position(center)
                .allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Carte circulaire de l’espace disque")
        .accessibilityValue("\(ByteText.string(root.size)), \(root.itemCount) éléments")
    }

    private func append(
        node: DiskNode,
        start: Double,
        span: Double,
        depth: Int,
        branch: Int,
        sibling: Int,
        result: inout [SunburstSegment]
    ) {
        guard depth < 5, span > 0.00045 else { return }
        result.append(SunburstSegment(
            id: "\(node.id)#\(depth)", node: node,
            start: start, end: start + span, depth: depth,
            branch: branch, sibling: sibling
        ))
        var cursor = start
        for (index, child) in node.children.enumerated() where child.size > 0 {
            let childSpan = span * Double(child.size) / Double(max(node.size, 1))
            append(
                node: child, start: cursor, span: childSpan,
                depth: depth + 1, branch: branch, sibling: index, result: &result
            )
            cursor += childSpan
        }
    }

    private func color(for segment: SunburstSegment) -> Color {
        let count = max(root.children.count, 1)
        let branchHue = (0.20 + Double(segment.branch) / Double(count) * 0.86).truncatingRemainder(dividingBy: 1)

        // The first ring identifies the major branch. Deeper rings fan through
        // the spectrum deterministically, so a very large folder does not turn
        // the whole chart into one flat colour.
        let variation = stableFraction(segment.node.id)
        let spread = min(0.68, 0.18 + Double(segment.depth) * 0.15)
        var hue = (branchHue - variation * spread).truncatingRemainder(dividingBy: 1)
        if hue < 0 { hue += 1 }

        let saturation = max(0.55, 0.88 - Double(segment.depth) * 0.035)
        let siblingShift = Double(segment.sibling % 5) * 0.018
        let brightness = min(1, 0.88 + Double(segment.depth) * 0.024 + siblingShift)
        return Color(hue: hue, saturation: saturation, brightness: brightness)
    }

    private func stableFraction(_ value: String) -> Double {
        var hash = UInt64(14_695_981_039_346_656_037)
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return Double(hash % 10_000) / 9_999
    }

    private func hitTest(_ point: CGPoint, center: CGPoint, inner: CGFloat, ring: CGFloat) -> DiskNode? {
        let dx = point.x - center.x
        let dy = point.y - center.y
        let radius = hypot(dx, dy)
        guard radius >= inner, radius < inner + ring * 5 else { return nil }
        let depth = Int((radius - inner) / ring)
        var angle = atan2(dy, dx)
        if angle < -.pi / 2 { angle += .pi * 2 }
        return segments.last(where: { $0.depth == depth && angle >= $0.start && angle <= $0.end })?.node
    }

    private func ringPath(center: CGPoint, inner: CGFloat, outer: CGFloat, start: Double, end: Double) -> Path {
        var path = Path()
        path.addArc(center: center, radius: outer, startAngle: .radians(start), endAngle: .radians(end), clockwise: false)
        path.addArc(center: center, radius: inner, startAngle: .radians(end), endAngle: .radians(start), clockwise: true)
        path.closeSubpath()
        return path
    }
}
