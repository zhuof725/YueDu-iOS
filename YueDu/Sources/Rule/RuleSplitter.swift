import Foundation

/// 规则切分器 —— 移植自 Legado 的 RuleAnalyzer。
/// 作用：按 && || %% 或 @ 切分规则，但会跳过 [] () 以及引号里的分隔符。
final class RuleSplitter {
    private let q: [Character]
    private var pos = 0
    private var start = 0
    private var startX = 0
    private var rule: [String] = []
    private var step = 0
    private let code: Bool
    var elementsType = ""

    init(_ data: String, code: Bool = false) {
        self.q = Array(data)
        self.code = code
    }

    private func sub(_ a: Int, _ b: Int) -> String {
        guard a < b, a >= 0, b <= q.count else { return "" }
        return String(q[a..<b])
    }
    private func sub(_ a: Int) -> String { sub(a, q.count) }

    /// 修剪前置 @ 和空白
    func trim() {
        guard pos < q.count else { return }
        if q[pos] == "@" || q[pos] < "!" {
            pos += 1
            while pos < q.count && (q[pos] == "@" || q[pos] < "!") { pos += 1 }
            start = pos
            startX = pos
        }
    }

    func reSetPos() { pos = 0; startX = 0 }

    private func consumeTo(_ seq: String) -> Bool {
        start = pos
        if let off = indexOf(seq, from: pos) { pos = off; return true }
        return false
    }

    private func indexOf(_ seq: String, from: Int) -> Int? {
        let s = Array(seq)
        guard !s.isEmpty, q.count >= s.count else { return nil }
        var i = from
        while i <= q.count - s.count {
            if regionMatches(i, s) { return i }
            i += 1
        }
        return nil
    }

    private func regionMatches(_ at: Int, _ s: [Character]) -> Bool {
        guard at + s.count <= q.count else { return false }
        for k in 0..<s.count where q[at + k] != s[k] { return false }
        return true
    }

    private func consumeToAny(_ seqs: [String]) -> Bool {
        var p = pos
        let arrs = seqs.map { Array($0) }
        while p < q.count {
            for (i, s) in arrs.enumerated() where regionMatches(p, s) {
                step = s.count
                pos = p
                elementsType = seqs[i]
                return true
            }
            p += 1
        }
        return false
    }

    private func findToAny(_ chars: [Character]) -> Int {
        var p = pos
        while p < q.count {
            if chars.contains(q[p]) { return p }
            p += 1
        }
        return -1
    }

    /// 代码平衡组：会区分引号、转义
    private func chompCodeBalanced(_ open: Character, _ close: Character) -> Bool {
        var p = pos
        var depth = 0, otherDepth = 0
        var inS = false, inD = false
        repeat {
            if p >= q.count { break }
            let c = q[p]; p += 1
            if c != "\\" {
                if c == "'" && !inD { inS.toggle() }
                else if c == "\"" && !inS { inD.toggle() }
                if inS || inD { continue }
                if c == "[" { depth += 1 }
                else if c == "]" { depth -= 1 }
                else if depth == 0 {
                    if c == open { otherDepth += 1 }
                    else if c == close { otherDepth -= 1 }
                }
            } else { p += 1 }
        } while depth > 0 || otherDepth > 0
        if depth > 0 || otherDepth > 0 { return false }
        pos = p
        return true
    }

    private func chompRuleBalanced(_ open: Character, _ close: Character) -> Bool {
        var p = pos
        var depth = 0
        var inS = false, inD = false
        repeat {
            if p >= q.count { break }
            let c = q[p]; p += 1
            if c == "'" && !inD { inS.toggle() }
            else if c == "\"" && !inS { inD.toggle() }
            if inS || inD { continue }
            if c == "\\" { p += 1; continue }
            if c == open { depth += 1 }
            else if c == close { depth -= 1 }
        } while depth > 0
        if depth > 0 { return false }
        pos = p
        return true
    }

    private func chompBalanced(_ open: Character, _ close: Character) -> Bool {
        code ? chompCodeBalanced(open, close) : chompRuleBalanced(open, close)
    }

    /// 按分隔符切分（首段匹配）
    func splitRule(_ split: String...) -> [String] {
        return splitRuleFirst(split)
    }

    private func splitRuleFirst(_ split: [String]) -> [String] {
        if split.count == 1 {
            elementsType = split[0]
            if !consumeTo(elementsType) {
                rule.append(sub(startX))
                return rule
            } else {
                step = elementsType.count
                return splitRuleNext()
            }
        } else if !consumeToAny(split) {
            rule.append(sub(startX))
            return rule
        }
        let end = pos
        pos = start
        repeat {
            let st = findToAny(["[", "("])
            if st == -1 {
                rule = [sub(startX, end)]
                elementsType = sub(end, end + step)
                pos = end + step
                while consumeTo(elementsType) {
                    rule.append(sub(start, pos))
                    pos += step
                }
                rule.append(sub(pos))
                return rule
            }
            if st > end {
                rule = [sub(startX, end)]
                elementsType = sub(end, end + step)
                pos = end + step
                while consumeTo(elementsType) && pos < st {
                    rule.append(sub(start, pos))
                    pos += step
                }
                if pos > st {
                    startX = start
                    return splitRuleNext()
                } else {
                    rule.append(sub(pos))
                    return rule
                }
            }
            pos = st
            let next: Character = q[pos] == "[" ? "]" : ")"
            if !chompBalanced(q[pos], next) {
                // 不平衡：当作普通字符，整体返回
                rule.append(sub(startX))
                return rule
            }
        } while end > pos
        start = pos
        return splitRuleFirst(split)
    }

    private func splitRuleNext() -> [String] {
        let end = pos
        pos = start
        repeat {
            let st = findToAny(["[", "("])
            if st == -1 {
                rule.append(sub(startX, end))
                pos = end + step
                while consumeTo(elementsType) {
                    rule.append(sub(start, pos))
                    pos += step
                }
                rule.append(sub(pos))
                return rule
            }
            if st > end {
                rule.append(sub(startX, end))
                pos = end + step
                while consumeTo(elementsType) && pos < st {
                    rule.append(sub(start, pos))
                    pos += step
                }
                if pos > st {
                    startX = start
                    return splitRuleNext()
                } else {
                    rule.append(sub(pos))
                    return rule
                }
            }
            pos = st
            let next: Character = q[pos] == "[" ? "]" : ")"
            if !chompBalanced(q[pos], next) {
                rule.append(sub(startX))
                return rule
            }
        } while end > pos
        start = pos
        if !consumeTo(elementsType) {
            rule.append(sub(startX))
            return rule
        }
        return splitRuleNext()
    }

    /// 替换内嵌规则 {$.xxx} —— 平衡组方式
    func innerRule(_ inner: String, startStep: Int = 1, endStep: Int = 1, _ fr: (String) -> String?) -> String {
        var st = ""
        while consumeTo(inner) {
            let posPre = pos
            if chompCodeBalanced("{", "}") {
                if let frv = fr(sub(posPre + startStep, pos - endStep)), !frv.isEmpty {
                    st += sub(startX, posPre) + frv
                    startX = pos
                    continue
                }
            }
            pos += inner.count
        }
        if startX == 0 { return "" }
        return st + sub(startX)
    }

    /// 替换内嵌规则 {{ }} —— 起止字符串方式
    func innerRule(_ startStr: String, _ endStr: String, _ fr: (String) -> String?) -> String {
        var st = ""
        while consumeTo(startStr) {
            pos += startStr.count
            let posPre = pos
            if consumeTo(endStr) {
                let frv = fr(sub(posPre, pos)) ?? ""
                st += sub(startX, posPre - startStr.count) + frv
                pos += endStr.count
                startX = pos
            }
        }
        if startX == 0 { return String(q) }
        return st + sub(startX)
    }
}
