import ApplicationServices
import Foundation

final class ElementCache {
    static let shared = ElementCache()
    private init() {}

    private var byIndex: [Int: AXUIElement] = [:]
    private var turnId: Int = 0

    var currentTurn: Int { turnId }

    func replace(root: AXNode) {
        turnId += 1
        byIndex.removeAll()
        ingest(root)
    }

    private func ingest(_ node: AXNode) {
        byIndex[node.index] = node.element
        for child in node.children { ingest(child) }
    }

    func lookup(index: Int) -> AXUIElement? {
        return byIndex[index]
    }

    func knownIndices() -> [Int] {
        return byIndex.keys.sorted()
    }
}
