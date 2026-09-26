import Foundation
import Kanna

/// XPath 规则解析（基于 Kanna / libxml2）—— 对应 Legado AnalyzeByXPath
final class AnalyzeByXPath {
    private var doc: HTMLDocument?

    init(_ content: Any) {
        var html = AnalyzeByJSoup.stringOf(content)
        if html.hasSuffix("</td>") { html = "<tr>\(html)</tr>" }
        if html.hasSuffix("</tr>") || html.hasSuffix("</tbody>") { html = "<table>\(html)</table>" }
        if html.trimmingCharacters(in: .whitespaces).isEmpty { html = "<html></html>" }
        doc = try? HTML(html: html, encoding: .utf8)
    }

    private func nodeString(_ n: XMLElement) -> String {
        if let h = n.toHTML, h.hasPrefix("<") { return h }
        return n.text ?? ""
    }

    private func result(_ xpath: String) -> [String] {
        guard let doc = doc else { return [] }
        switch doc.xpath(xpath) {
        case .NodeSet(let set): return set.map { nodeString($0) }
        case .String(let s): return [s]
        case .Number(let n): return [n == n.rounded() ? String(Int64(n)) : "\(n)"]
        case .Bool(let b): return [b ? "true" : "false"]
        default: return []
        }
    }

    /// 元素列表（以 HTML 片段的形式返回，后续规则会重新解析）
    func getElements(_ xPath: String) -> [String] {
        if xPath.isEmpty { return [] }
        let an = RuleSplitter(xPath)
        let rules = an.splitRule("&&", "||", "%%")
        if rules.count == 1 { return result(rules[0]) }
        var results: [[String]] = []
        for r in rules {
            let t = getElements(r)
            if !t.isEmpty { results.append(t); if an.elementsType == "||" { break } }
        }
        return AnalyzeByXPath.merge(results, an.elementsType)
    }

    func getStringList(_ xPath: String) -> [String] {
        let an = RuleSplitter(xPath)
        let rules = an.splitRule("&&", "||", "%%")
        if rules.count == 1 { return result(xPath) }
        var results: [[String]] = []
        for r in rules {
            let t = getStringList(r)
            if !t.isEmpty { results.append(t); if an.elementsType == "||" { break } }
        }
        return AnalyzeByXPath.merge(results, an.elementsType)
    }

    func getString(_ rule: String) -> String? {
        let an = RuleSplitter(rule)
        let rules = an.splitRule("&&", "||")
        if rules.count == 1 {
            let r = result(rule)
            return r.isEmpty ? nil : r.joined(separator: "\n")
        }
        var list: [String] = []
        for rl in rules {
            if let t = getString(rl), !t.isEmpty { list.append(t); if an.elementsType == "||" { break } }
        }
        return list.joined(separator: "\n")
    }

    static func merge<T>(_ results: [[T]], _ type: String) -> [T] {
        var out: [T] = []
        if type == "%%", let first = results.first {
            for i in 0..<first.count { for t in results where i < t.count { out.append(t[i]) } }
        } else {
            for t in results { out.append(contentsOf: t) }
        }
        return out
    }
}

/// 正则规则（以 : 开头的列表规则）—— 对应 Legado AnalyzeByRegex
enum AnalyzeByRegex {
    static func getElements(_ res: String, _ regs: [String], _ index: Int = 0) -> [[String]] {
        guard index < regs.count, let rx = try? NSRegularExpression(pattern: regs[index], options: []) else { return [] }
        let ns = res as NSString
        let ms = rx.matches(in: res, range: NSRange(location: 0, length: ns.length))
        if ms.isEmpty { return [] }
        if index + 1 == regs.count {
            return ms.map { m in
                (0..<m.numberOfRanges).map { g in
                    let r = m.range(at: g)
                    return r.location == NSNotFound ? "" : ns.substring(with: r)
                }
            }
        }
        let joined = ms.map { ns.substring(with: $0.range) }.joined()
        return getElements(joined, regs, index + 1)
    }

    static func getElement(_ res: String, _ regs: [String], _ index: Int = 0) -> [String]? {
        guard index < regs.count, let rx = try? NSRegularExpression(pattern: regs[index], options: []) else { return nil }
        let ns = res as NSString
        let ms = rx.matches(in: res, range: NSRange(location: 0, length: ns.length))
        guard let first = ms.first else { return nil }
        if index + 1 == regs.count {
            return (0..<first.numberOfRanges).map { g in
                let r = first.range(at: g)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
        }
        let joined = ms.map { ns.substring(with: $0.range) }.joined()
        return getElement(joined, regs, index + 1)
    }
}
