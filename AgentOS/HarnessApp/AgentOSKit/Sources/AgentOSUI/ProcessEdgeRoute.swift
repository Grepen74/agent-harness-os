import CoreGraphics

/// An orthogonal connector between two stage cards that never runs behind a third card.
/// Side-by-side cards connect through the gutter between them. Otherwise the rail sits just
/// right of the narrower card, and a wider card (a full-width Recovery stage) is left or
/// entered through its top or bottom edge, so the line never crosses another lane.
/// A non-zero `offset` runs a parallel route beside the default one, so a parent–child link
/// stays visible next to a transition between the same cards.
struct ProcessEdgeRoute: Equatable {
    var points: [CGPoint]
    /// Direction of the last segment; the arrowhead points this way at `points.last`.
    var heading: CGVector

    static let railOffset: CGFloat = 10
    static let parallelOffset: CGFloat = 6

    /// `offset` moves the rail sideways and, unless `verticalOffset` is given, the attachment points down.
    init(from source: CGRect, to target: CGRect, offset: CGFloat = 0, verticalOffset: CGFloat? = nil) {
        let lift = verticalOffset ?? offset
        if target.maxX <= source.minX || source.maxX <= target.minX {
            let leftward = target.maxX <= source.minX
            let start = CGPoint(x: leftward ? source.minX : source.maxX, y: source.midY + lift)
            let end = CGPoint(x: leftward ? target.maxX : target.minX, y: target.midY + lift)
            let gutter = (start.x + end.x) / 2 + offset
            points = [start, CGPoint(x: gutter, y: start.y), CGPoint(x: gutter, y: end.y), end]
            heading = CGVector(dx: leftward ? -1 : 1, dy: 0)
            return
        }
        let narrowEdge = min(source.maxX, target.maxX)
        let rail = narrowEdge + Self.railOffset + offset
        let upward = target.midY < source.midY
        let start = source.maxX > narrowEdge + 1
            ? CGPoint(x: rail, y: upward ? source.minY : source.maxY)
            : CGPoint(x: source.maxX, y: source.midY + lift)
        if target.maxX > narrowEdge + 1 {
            let end = CGPoint(x: rail, y: upward ? target.maxY : target.minY)
            points = [start, CGPoint(x: rail, y: start.y), end]
            heading = CGVector(dx: 0, dy: upward ? -1 : 1)
        } else {
            let end = CGPoint(x: target.maxX, y: target.midY + lift)
            points = [start, CGPoint(x: rail, y: start.y), CGPoint(x: rail, y: end.y), end]
            heading = CGVector(dx: -1, dy: 0)
        }
    }

    var arrowhead: [CGPoint] {
        guard let tip = points.last else { return [] }
        let back = CGPoint(x: tip.x - heading.dx * 5, y: tip.y - heading.dy * 5)
        return [CGPoint(x: back.x - heading.dy * 3, y: back.y + heading.dx * 3), tip,
                CGPoint(x: back.x + heading.dy * 3, y: back.y - heading.dx * 3)]
    }
}
