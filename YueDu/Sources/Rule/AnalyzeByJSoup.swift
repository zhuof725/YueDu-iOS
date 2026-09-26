import Foundation
import SwiftSoup

/// 默认规则（JSoup 语法）解析 —— 移植自 Legado AnalyzeByJSoup
final class AnalyzeByJSoup {
    private let element: Element

    init(_ doc: Any) {
        if let e = doc as? Element {
            element = e
        } else {
            let s = AnalyzeByJSoup.stringOf(doc)
            if s.lowercased().hasPrefix("<?xml"), let d = try? SwiftSoup.parse(s, "", Parser.xmlParser()) {
                element = d
            } else {
                element = (try? SwiftSoup.parse(s)) ?? Document("")
            }
        }
    }

    static func stringOf(_ o: Any) -> String {
        if let s = o as? String { return s }
        if let e = o as? Element { return (try? e.outerHtml()) ?? "" }
        if let a = o as? [Any] { return a.map { stringOf($0) }.joined(separator: "\n") }
        return "\(o)"
    }

    // MARK: 公共接口

    func getElements(_ rule: String) -> [Element] {
        return getElements(element, rule)
    }

    func getString(_ ruleStr: String) -> String? {
        if ruleStr.isEmpty { return nil }
        let list = getStringList(ruleStr)
        if list.isEmpty { return nil }
        if list.count == 1 { return list[0] }
        return list.joined(separator: "\n")
    }

    func getString0(_ ruleStr: String) -> String {
        getStringList(ruleStr).first ?? ""
    }

    func getStringList(_ ruleStr: String) -> [String] {
        var textS: [String] = []
        if ruleStr.isEmpty { return textS }
        var isCss = false
        var elementsRule = ruleStr
        if ruleStr.lowercased().hasPrefix("@css:") {
            isCss = true
            elementsRule = String(ruleStr.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        }
        if elementsRule.isEmpty {
            textS.append(element.data())
            return textS
        }
        let analyzer = RuleSplitter(elementsRule)
        let ruleStrS = analyzer.splitRule("&&", "||", "%%")
        var results: [[String]] = []
        for ruleStrX in ruleStrS {
            var temp: [String]? = nil
            if isCss {
                if let lastIndex = ruleStrX.lastIndex(of: "@") {
                    let sel = String(ruleStrX[..<lastIndex])
                    let last = String(ruleStrX[ruleStrX.index(after: lastIndex)...])
                    let els = (try? element.select(sel).array()) ?? []
                    temp = getResultLast(els, last)
                } else {
                    temp = getResultLast((try? element.select(ruleStrX).array()) ?? [], "text")
                }
            } else {
                temp = getResultList(ruleStrX)
            }
            if let t = temp, !t.isEmpty {
                results.append(t)
                if analyzer.elementsType == "||" { break }
            }
        }
        if !results.isEmpty {
            if analyzer.elementsType == "%%" {
                for i in 0..<results[0].count {
                    for t in results where i < t.count { textS.append(t[i]) }
                }
            } else {
                for t in results { textS.append(contentsOf: t) }
            }
        }
        return textS
    }

    // MARK: 内部实现

    private func getElements(_ temp: Element?, _ rule: String) -> [Element] {
        guard let temp = temp, !rule.isEmpty else { return [] }
        var isCss = false
        var elementsRule = rule
        if rule.lowercased().hasPrefix("@css:") {
            isCss = true
            elementsRule = String(rule.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        }
        let analyzer = RuleSplitter(elementsRule)
        let ruleStrS = analyzer.splitRule("&&", "||", "%%")
        var elementsList: [[Element]] = []
        if isCss {
            for r in ruleStrS {
                let tempS = (try? temp.select(r).array()) ?? []
                elementsList.append(tempS)
                if !tempS.isEmpty && analyzer.elementsType == "||" { break }
            }
        } else {
            for r in ruleStrS {
                let rs0 = RuleSplitter(r)
                rs0.trim()
                let rs = rs0.splitRule("@")
                var el: [Element]
                if rs.count > 1 {
                    el = [temp]
                    for rl in rs {
                        var es: [Element] = []
                        for et in el { es.append(contentsOf: getElements(et, rl)) }
                        el = es
                    }
                } else {
                    el = ElementsSingle().getElementsSingle(temp, r)
                }
                elementsList.append(el)
                if !el.isEmpty && analyzer.elementsType == "||" { break }
            }
        }
        var elements: [Element] = []
        if !elementsList.isEmpty {
            if analyzer.elementsType == "%%" {
                for i in 0..<elementsList[0].count {
                    for es in elementsList where i < es.count { elements.append(es[i]) }
                }
            } else {
                for es in elementsList { elements.append(contentsOf: es) }
            }
        }
        return elements
    }

    private func getResultList(_ ruleStr: String) -> [String]? {
        if ruleStr.isEmpty { return nil }
        var elements: [Element] = [element]
        let r = RuleSplitter(ruleStr)
        r.trim()
        let rules = r.splitRule("@")
        let last = rules.count - 1
        if last > 0 {
            for i in 0..<last {
                var es: [Element] = []
                for elt in elements {
                    es.append(contentsOf: ElementsSingle().getElementsSingle(elt, rules[i]))
                }
                elements = es
            }
        }
        return elements.isEmpty ? nil : getResultLast(elements, rules[last])
    }

    private func getResultLast(_ elements: [Element], _ lastRule: String) -> [String] {
        var textS: [String] = []
        switch lastRule {
        case "text":
            for e in elements {
                if let t = try? e.text(), !t.isEmpty { textS.append(t) }
            }
        case "textNodes":
            for e in elements {
                let tn = e.textNodes().map { $0.text().trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                if !tn.isEmpty { textS.append(tn.joined(separator: "\n")) }
            }
        case "ownText":
            for e in elements {
                let t = e.ownText()
                if !t.isEmpty { textS.append(t) }
            }
        case "html":
            var parts: [String] = []
            for e in elements {
                if let s = try? e.select("script, style") { _ = try? s.remove() }
                if let h = try? e.outerHtml() { parts.append(h) }
            }
            let html = parts.joined(separator: "\n")
            if !html.isEmpty { textS.append(html) }
        case "all":
            textS.append(elements.compactMap { try? $0.outerHtml() }.joined(separator: "\n"))
        default:
            for e in elements {
                let v = (try? e.attr(lastRule)) ?? ""
                if v.trimmingCharacters(in: .whitespaces).isEmpty || textS.contains(v) { continue }
                textS.append(v)
            }
        }
        return textS
    }
}

/// 单段规则 + 索引，比如 tag.div.-1:10:2、class.item!0、tag.div[-1, 3:-2]
private final class ElementsSingle {
    var split: Character = "."
    var beforeRule = ""
    var indexDefault: [Int] = []
    enum Idx { case one(Int); case range(Int?, Int?, Int) }
    var indexes: [Idx] = []

    func getElementsSingle(_ temp: Element, _ rule: String) -> [Element] {
        findIndexSet(rule)
        var elements: [Element]
        if beforeRule.isEmpty {
            elements = temp.children().array()
        } else {
            let rules = beforeRule.components(separatedBy: ".")
            let second = rules.count > 1 ? rules[1] : ""
            switch rules[0] {
            case "children": elements = temp.children().array()
            case "class": elements = (try? temp.getElementsByClass(second).array()) ?? []
            case "tag": elements = (try? temp.getElementsByTag(second).array()) ?? []
            case "id":
                elements = ((try? temp.select("[id=\(second)]").array()) ?? [])
            case "text": elements = (try? temp.getElementsContainingOwnText(second).array()) ?? []
            default: elements = (try? temp.select(beforeRule).array()) ?? []
            }
        }
        let len = elements.count
        var indexSet: [Int] = []
        func add(_ i: Int) { if !indexSet.contains(i) { indexSet.append(i) } }

        if indexes.isEmpty {
            for ix in stride(from: indexDefault.count - 1, through: 0, by: -1) {
                let it = indexDefault[ix]
                if it >= 0 && it < len { add(it) }
                else if it < 0 && len >= -it { add(it + len) }
            }
        } else {
            for ix in stride(from: indexes.count - 1, through: 0, by: -1) {
                switch indexes[ix] {
                case .range(let sx, let ex, let stepX):
                    var s = sx ?? 0; if s < 0 { s += len }
                    var e = ex ?? (len - 1); if e < 0 { e += len }
                    if (s < 0 && e < 0) || (s >= len && e >= len) { continue }
                    if s >= len { s = len - 1 } else if s < 0 { s = 0 }
                    if e >= len { e = len - 1 } else if e < 0 { e = 0 }
                    if s == e || stepX >= len { add(s); continue }
                    let step = stepX > 0 ? stepX : (-stepX < len ? stepX + len : 1)
                    if e > s { for i in stride(from: s, through: e, by: step) { add(i) } }
                    else { for i in stride(from: s, through: e, by: -step) { add(i) } }
                case .one(let it):
                    if it >= 0 && it < len { add(it) }
                    else if it < 0 && len >= -it { add(it + len) }
                }
            }
        }
        if split == "!" {
            let ex = Set(indexSet)
            return elements.enumerated().filter { !ex.contains($0.offset) }.map { $0.element }
        } else if split == "." {
            return indexSet.map { elements[$0] }
        }
        return elements
    }

    private func findIndexSet(_ rule: String) {
        let rus = Array(rule.trimmingCharacters(in: .whitespaces))
        guard !rus.isEmpty else { split = " "; beforeRule = ""; return }
        var len = rus.count
        var curMinus = false
        var curList: [Int?] = []
        var l = ""
        let head = rus.last == "]"
        if head {
            len -= 1
            while len > 0 {
                len -= 1
                var rl = rus[len]
                if rl == " " { continue }
                if rl.isASCII && rl.isNumber { l = String(rl) + l }
                else if rl == "-" { curMinus = true }
                else {
                    let curInt: Int? = l.isEmpty ? nil : (curMinus ? -(Int(l) ?? 0) : (Int(l) ?? 0))
                    if rl == ":" {
                        curList.append(curInt)
                    } else {
                        if curList.isEmpty {
                            if curInt == nil { break }
                            indexes.append(.one(curInt!))
                        } else {
                            indexes.append(.range(curInt, curList.last ?? nil, curList.count == 2 ? (curList.first! ?? 1) : 1))
                            curList.removeAll()
                        }
                        if rl == "!" {
                            split = "!"
                            repeat { len -= 1; rl = rus[len] } while len > 0 && rl == " "
                        }
                        if rl == "[" {
                            beforeRule = String(rus[0..<len])
                            return
                        }
                        if rl != "," { break }
                    }
                    l = ""
                    curMinus = false
                }
            }
        } else {
            while len > 0 {
                len -= 1
                let rl = rus[len]
                if rl == " " { continue }
                if rl.isASCII && rl.isNumber { l = String(rl) + l }
                else if rl == "-" { curMinus = true }
                else {
                    if rl == "!" || rl == "." || rl == ":" {
                        guard let n = Int(l) else { break }
                        indexDefault.append(curMinus ? -n : n)
                        if rl != ":" {
                            split = rl
                            beforeRule = String(rus[0..<len])
                            return
                        }
                    } else { break }
                    l = ""
                    curMinus = false
                }
            }
        }
        // 非索引结构
        indexes.removeAll()
        indexDefault.removeAll()
        split = " "
        beforeRule = String(rus)
    }
}
