import ApplicationServices
import Foundation

struct SlackAXLimits {
    var nodes = 500
    var depth = 24
    var children = 80
    var characters = 40_000
    var seconds: TimeInterval = 0.8
}

protocol SlackAXTransport {
    associatedtype Element
    func node(_ element: Element, id: Int, parent: Int?) -> SlackAXNode?
    func children(_ element: Element, limit: Int) -> (elements: [Element], truncated: Bool)
}

enum SlackAXWalker {
    static func read<T: SlackAXTransport>(root: T.Element, transport: T, limits: SlackAXLimits = .init(),
                                          now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                                          cancelled: () -> Bool = { Task.isCancelled }) -> SlackAXSnapshot {
        let deadline = now() + limits.seconds
        var pending: [(T.Element, Int?, Int)] = [(root, nil, 0)]
        var snapshot = SlackAXSnapshot(windowTitle: "Slack", nodes: [])
        var characters = 0
        var visited = 0
        while let (element, parent, depth) = pending.popLast() {
            guard !cancelled(), now() < deadline, visited < limits.nodes, characters < limits.characters else {
                snapshot.truncated = true
                break
            }
            visited += 1
            guard var node = transport.node(element, id: snapshot.nodes.count, parent: parent) else {
                snapshot.truncated = true
                continue
            }
            if node.isPrivateInput || node.role == "AXOutline" { continue }
            for key in [\SlackAXNode.title, \.label, \.value, \.identifier] {
                let remaining = max(0, limits.characters - characters)
                let original = node[keyPath: key]
                node[keyPath: key] = String(original.prefix(min(2_000, remaining)))
                characters += node[keyPath: key].count
                if node[keyPath: key].count < original.count { snapshot.truncated = true }
            }
            for key in [\SlackAXNode.url, \.selectedText] {
                guard let original = node[keyPath: key] else { continue }
                let remaining = max(0, limits.characters - characters)
                node[keyPath: key] = String(original.prefix(remaining))
                characters += node[keyPath: key]?.count ?? 0
                if (node[keyPath: key]?.count ?? 0) < original.count { snapshot.truncated = true }
            }
            if node.role == "AXWindow", !node.title.isEmpty { snapshot.windowTitle = node.title }
            snapshot.nodes.append(node)
            if node.role == "AXWindow", ["Drafts", "Drafts & sent", "Drafts and sent"].contains(node.title.components(separatedBy: " - ").first ?? "") {
                snapshot.truncated = true
                continue
            }
            guard depth < limits.depth, now() < deadline else { snapshot.truncated = true; continue }
            let children = transport.children(element, limit: min(limits.children, max(0, limits.nodes - snapshot.nodes.count)))
            snapshot.truncated = snapshot.truncated || children.truncated
            for child in children.elements.reversed() { pending.append((child, node.id, depth + 1)) }
        }
        snapshot.unavailable = snapshot.nodes.isEmpty
        return snapshot
    }
}

/// Owns AX objects on a background executor; never called synchronously by ContextMonitor.
actor SlackContextExtractor {
    static let bundleIdentifier = "com.tinyspeck.slackmacgap"
    private var cached: (pid: Int32, at: TimeInterval, hint: AppHint)?

    func extract(processID: Int32, force: Bool = false) -> AppHint? {
        guard !Task.isCancelled else { return nil }
        guard AXIsProcessTrusted() else {
            cached = nil
            return SlackContext(isPartial: true, needsAccessibility: true, diagnostic: "Accessibility access required").appHint()
        }
        let now = ProcessInfo.processInfo.systemUptime
        if !force, let cached, cached.pid == processID, now - cached.at < 1.5 { return cached.hint }
        let transport = NativeSlackAXTransport(processID: processID)
        guard let root = transport.focusedWindow else {
            cached = nil
            return SlackContext(isPartial: true, diagnostic: "Slack has no accessible focused window").appHint()
        }
        let snapshot = SlackAXWalker.read(root: root, transport: transport)
        guard !Task.isCancelled else { return nil }
        let hint = SlackContextParser.parse(snapshot).appHint(windowTitle: snapshot.windowTitle)
        cached = (processID, ProcessInfo.processInfo.systemUptime, hint)
        return hint
    }
}

private final class NativeSlackAXTransport: SlackAXTransport {
    let application: AXUIElement
    let focusedWindow: AXUIElement?
    let focusedElement: AXUIElement?
    private var lastRole = ""

    init(processID: Int32) {
        application = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(application, 0.08)
        focusedWindow = Self.elementAttribute(application, kAXFocusedWindowAttribute)
        focusedElement = Self.elementAttribute(application, kAXFocusedUIElementAttribute)
    }

    func node(_ element: AXUIElement, id: Int, parent: Int?) -> SlackAXNode? {
        AXUIElementSetMessagingTimeout(element, 0.08)
        let roles = attributes(element, [kAXRoleAttribute, kAXSubroleAttribute])
        guard let role = roles[kAXRoleAttribute] as? String else { return nil }
        let semanticRole = roles[kAXSubroleAttribute] as? String == "AXSearchField" ? "AXSearchField" : role
        lastRole = semanticRole
        var node = SlackAXNode(id: id, parent: parent, role: semanticRole)
        // Do not fetch editable values, labels, children or selections from composers/password fields.
        guard !node.isPrivateInput, role != "AXOutline" else { return node }
        let labels = attributes(element, [kAXTitleAttribute, kAXDescriptionAttribute, kAXIdentifierAttribute,
                                           kAXURLAttribute, kAXSelectedAttribute])
        node.title = String((labels[kAXTitleAttribute] as? String ?? "").prefix(2_000))
        node.label = String((labels[kAXDescriptionAttribute] as? String ?? "").prefix(2_000))
        node.identifier = String((labels[kAXIdentifierAttribute] as? String ?? "").prefix(256))
        guard !node.isPrivateInput else { return node }
        node.url = (labels[kAXURLAttribute] as? URL)?.absoluteString ?? labels[kAXURLAttribute] as? String
        if let value = node.url { node.url = String(value.prefix(4_096)) }
        node.selected = labels[kAXSelectedAttribute] as? Bool ?? false
        node.focused = focusedElement.map { CFEqual(element, $0) } ?? false
        if ["AXStaticText", "AXLink", "AXSearchField"].contains(semanticRole) {
            node.value = String((attribute(element, kAXValueAttribute) as? String ?? "").prefix(2_000))
        }
        if node.focused, semanticRole == "AXStaticText" {
            node.selectedText = (attribute(element, kAXSelectedTextAttribute) as? String).map { String($0.prefix(1_500)) }
        }
        return node
    }

    func children(_ element: AXUIElement, limit: Int) -> (elements: [AXUIElement], truncated: Bool) {
        var count: CFIndex = 0
        var key = kAXChildrenAttribute
        if ["AXList", "AXTable", "AXScrollArea"].contains(lastRole),
           AXUIElementGetAttributeValueCount(element, kAXVisibleChildrenAttribute as CFString, &count) == .success {
            key = kAXVisibleChildrenAttribute
        } else if AXUIElementGetAttributeValueCount(element, key as CFString, &count) != .success {
            return ([], false)
        }
        guard count > 0, limit > 0 else { return ([], count > 0) }
        var values: CFArray?
        let result = AXUIElementCopyAttributeValues(element, key as CFString, 0, min(count, limit), &values)
        guard result == .success, let children = values as? [AXUIElement] else { return ([], true) }
        return (children, count > limit)
    }

    private func attributes(_ element: AXUIElement, _ names: [String]) -> [String: Any] {
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, names as CFArray, [], &values) == .success,
              let array = values as? [Any] else { return [:] }
        return Dictionary(uniqueKeysWithValues: zip(names, array).map { ($0, $1) })
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}
