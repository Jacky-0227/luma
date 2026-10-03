import Foundation

/// Hikvision application status is independent of the HTTP status. A bare
/// statusCode 4 also means bad authorization or insufficient privilege, so it
/// must never be interpreted as proof that a firmware route is unsupported.
enum PTZResponseDocument {
    enum Classification: Equatable {
        case notStatus
        case success
    }

    @discardableResult
    static func validate(_ data: Data) throws -> Classification {
        let root = try PTZXMLNode.parse(data)
        guard ["ResponseStatus", "ResponseStaus"].contains(root.name) else { return .notStatus }
        guard let code = try field("statusCode", in: root), let number = Int(code) else {
            throw PTZError.invalidResponse
        }
        let subcode = try field("subStatusCode", in: root)?.lowercased()
        if number == 1, subcode == nil || subcode == "ok" { return .success }
        guard number == 4 else { throw PTZError.invalidResponse }
        switch subcode {
        case "notsupport", "methodnotallowed": throw PTZError.unsupported
        case "lowprivilege", "badauthorization": throw PTZError.permissionDenied
        default: throw PTZError.invalidResponse
        }
    }

    private static func field(_ name: String, in node: PTZXMLNode) throws -> String? {
        let matches = node.children.filter { $0.name == name }
        guard matches.count <= 1 else { throw PTZError.invalidResponse }
        guard let match = matches.first else { return nil }
        guard match.children.isEmpty else { throw PTZError.invalidResponse }
        let value = match.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw PTZError.invalidResponse }
        return value
    }
}

final class PTZXMLNode: NSObject, XMLParserDelegate {
    let name: String
    var text = ""
    var children: [PTZXMLNode] = []
    private var stack: [PTZXMLNode] = []
    private var count = 0

    init(name: String) { self.name = name }
    func child(_ name: String) -> PTZXMLNode? { children.first { $0.name == name } }

    static func parse(_ data: Data) throws -> PTZXMLNode {
        guard !data.isEmpty, data.count <= 131_072,
              !String(decoding: data, as: UTF8.self).uppercased().contains("<!DOCTYPE") else { throw PTZError.invalidResponse }
        let delegate = PTZXMLNode(name: "document")
        delegate.stack = [delegate]
        defer { delegate.stack = [] }
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), delegate.children.count == 1, delegate.stack.count == 1,
              let root = delegate.children.first else { throw PTZError.invalidResponse }
        return root
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        count += 1
        guard stack.count < 32, count <= 4096 else { parser.abortParsing(); return }
        let node = PTZXMLNode(name: elementName)
        stack.last?.children.append(node)
        stack.append(node)
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text.append(string) }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if stack.count > 1 { stack.removeLast() }
    }
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
        parser.abortParsing()
    }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) {
        parser.abortParsing()
    }
}
