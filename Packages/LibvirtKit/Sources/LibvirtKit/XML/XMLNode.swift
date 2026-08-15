//
// Copyright © 2026 UTM Pro contributors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

import Foundation

/// A parsed XML element.
///
/// libvirt speaks XML for domains, pools and volumes. `XMLDocument` is
/// unavailable on iOS, so this is a small tree built on `XMLParser`, which is
/// present on every platform we ship to.
public final class XMLNode: @unchecked Sendable {
    public let name: String
    public private(set) var attributes: [String: String]
    public private(set) var children: [XMLNode]
    public private(set) var text: String

    public weak var parent: XMLNode?

    init(name: String, attributes: [String: String] = [:]) {
        self.name = name
        self.attributes = attributes
        self.children = []
        self.text = ""
    }

    fileprivate func append(child: XMLNode) {
        child.parent = self
        children.append(child)
    }

    fileprivate func append(text fragment: String) {
        text += fragment
    }

    /// The first direct child with this name.
    public subscript(_ childName: String) -> XMLNode? {
        children.first { $0.name == childName }
    }

    /// Every direct child with this name.
    public func all(_ childName: String) -> [XMLNode] {
        children.filter { $0.name == childName }
    }

    /// The first descendant with this name, breadth-first.
    public func firstDescendant(_ descendantName: String) -> XMLNode? {
        var queue = children
        while !queue.isEmpty {
            let node = queue.removeFirst()
            if node.name == descendantName {
                return node
            }
            queue.append(contentsOf: node.children)
        }
        return nil
    }

    /// Every descendant with this name.
    public func descendants(_ descendantName: String) -> [XMLNode] {
        var found: [XMLNode] = []
        var queue = children
        while !queue.isEmpty {
            let node = queue.removeFirst()
            if node.name == descendantName {
                found.append(node)
            }
            queue.append(contentsOf: node.children)
        }
        return found
    }

    public func attribute(_ key: String) -> String? {
        attributes[key]
    }

    /// The element's text with surrounding whitespace removed.
    public var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var intValue: Int? {
        Int(trimmedText)
    }

    public var uint64Value: UInt64? {
        UInt64(trimmedText)
    }

    /// Parses a document and returns its root element.
    public static func parse(_ xml: String) throws -> XMLNode {
        let parser = XMLParser(data: Data(xml.utf8))
        let builder = TreeBuilder()
        parser.delegate = builder
        guard parser.parse(), let root = builder.root else {
            throw LibvirtError.malformedXML(parser.parserError.map { String(describing: $0) }
                                            ?? "unparseable document")
        }
        return root
    }
}

private final class TreeBuilder: NSObject, XMLParserDelegate {
    var root: XMLNode?
    private var stack: [XMLNode] = []

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        let node = XMLNode(name: elementName, attributes: attributeDict)
        if let current = stack.last {
            current.append(child: node)
        } else {
            root = node
        }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.append(text: string)
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {
        stack.removeLast()
    }
}

// MARK: - Writing

/// Builds XML for libvirt to consume, escaping every interpolated value.
///
/// Same reasoning as `ShellCommand`: names and paths reach libvirt as markup,
/// so an unescaped `&` or `<` in a VM name would produce a document libvirt
/// rejects — or, worse, one it accepts with the wrong shape.
public struct XMLBuilder: Sendable {
    private var lines: [String] = []
    private var indentation = 0
    private var openElements: [String] = []

    public init() {}

    public mutating func open(_ name: String, _ attributes: [String: String] = [:]) {
        lines.append("\(indent)<\(name)\(Self.render(attributes))>")
        openElements.append(name)
        indentation += 1
    }

    public mutating func close() {
        guard let name = openElements.popLast() else { return }
        indentation -= 1
        lines.append("\(indent)</\(name)>")
    }

    /// An element with no children, e.g. `<acpi/>`.
    public mutating func empty(_ name: String, _ attributes: [String: String] = [:]) {
        lines.append("\(indent)<\(name)\(Self.render(attributes))/>")
    }

    /// An element containing text, e.g. `<name>Debian</name>`.
    public mutating func element(_ name: String, text: String, _ attributes: [String: String] = [:]) {
        lines.append("\(indent)<\(name)\(Self.render(attributes))>\(Self.escape(text))</\(name)>")
    }

    public var document: String {
        lines.joined(separator: "\n")
    }

    private var indent: String {
        String(repeating: "  ", count: indentation)
    }

    private static func render(_ attributes: [String: String]) -> String {
        guard !attributes.isEmpty else { return "" }
        // Sorted so generated documents are stable and diffable.
        return attributes.sorted { $0.key < $1.key }
            .map { " \($0.key)=\"\(escape($0.value))\"" }
            .joined()
    }

    public static func escape(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.count)
        for character in value {
            switch character {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            case "'": escaped += "&apos;"
            default: escaped.append(character)
            }
        }
        return escaped
    }
}
