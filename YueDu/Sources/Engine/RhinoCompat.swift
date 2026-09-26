import Foundation

/// 把安卓版「阅读」（Rhino 引擎）能跑、但 iOS JavaScriptCore 会报语法错误的写法改掉。
/// 语法错误会让整段脚本（包括登录界面 loginUi、login 函数）一行都不执行，界面就是空的。
///
/// 目前处理的写法（只改代码，不碰字符串、注释、正则里的内容）：
/// 1. 顶层 `let result` / `const result` → `var result`
///    Rhino 里 result 是可改的全局变量；JSC 里再用 let 声明会和我们预先放进去的 result 冲突
/// 2. 函数体里用 let/const 重新声明同名参数 → var
///    `function f(a){ let a = 1 }` Rhino 可以，JSC 直接 SyntaxError
/// 3. 箭头函数的数组解构参数没加括号 `[a, b] => …` → `([a, b]) => …`
/// 4. 顶层（不在 {} 里）的 let/const → var
///    同一个 JS 环境里会先后执行 jsLib、loginUrl、loginUi、按钮脚本，同一段规则也会对每条结果重复执行；
///    顶层 let/const 第二次执行就报「重复声明」。Rhino 每次都是新作用域所以没问题
enum RhinoCompat {
    private struct Token { let text: String; let range: NSRange }

    static func normalize(_ source: String) -> String {
        // 快速跳过：没有 let/const/=> 的脚本不用处理
        if !source.contains("let") && !source.contains("const") && !source.contains("=>") { return source }
        let tokens = lex(source)
        if tokens.isEmpty { return source }
        var edits: [(NSRange, String)] = []

        // 1 + 4：顶层（不在任何 {} 里）的 let/const
        var depth = 0
        var declared = Set<String>()
        for (i, t) in tokens.enumerated() {
            if t.text == "{" { depth += 1; continue }
            if t.text == "}" { depth = max(0, depth - 1); continue }
            guard t.text == "let" || t.text == "const", i + 1 < tokens.count else { continue }
            let name = tokens[i + 1].text
            guard isIdentifier(name) else { continue }
            if name == "result" || depth == 0 { edits.append((t.range, "var")); declared.insert(name) }
        }

        // 2：函数参数被函数体顶层的 let/const 重复声明
        var i = 0
        while i < tokens.count {
            defer { i += 1 }
            guard tokens[i].text == "function",
                  let op = next("(", after: i, tokens), let cp = match("(", ")", op, tokens),
                  let ob = next("{", after: cp, tokens), ob == cp + 1, let cb = match("{", "}", ob, tokens) else { continue }
            let params = Set(tokens[(op + 1)..<cp].map(\.text).filter(isIdentifier))
            if params.isEmpty { continue }
            var d = 0
            for k in (ob + 1)..<cb {
                let t = tokens[k]
                if t.text == "{" { d += 1 } else if t.text == "}" { d = max(0, d - 1) }
                if d == 0, t.text == "let" || t.text == "const", k + 1 < cb, params.contains(tokens[k + 1].text) {
                    edits.append((t.range, "var"))
                }
            }
        }

        // 3：[a, b] => 加括号
        for (o, t) in tokens.enumerated() where t.text == "[" && o > 0 && (tokens[o - 1].text == "(" || tokens[o - 1].text == ",") {
            guard let c = match("[", "]", o, tokens), c + 1 < tokens.count, tokens[c + 1].text == "=>",
                  !tokens[(o + 1)..<c].contains(where: { $0.text == "[" }) else { continue }
            edits.append((NSRange(location: t.range.location, length: 0), "("))
            edits.append((NSRange(location: NSMaxRange(tokens[c].range), length: 0), ")"))
        }

        if edits.isEmpty { return source }
        // 去重后从后往前替换，位置不会乱
        var seen = Set<String>()
        let sorted = edits.filter { seen.insert("\($0.0.location):\($0.0.length):\($0.1)").inserted }
            .sorted { $0.0.location != $1.0.location ? $0.0.location > $1.0.location : $0.0.length < $1.0.length }
        let m = NSMutableString(string: source)
        for (r, s) in sorted { m.replaceCharacters(in: r, with: s) }
        return m as String
    }

    private static func next(_ s: String, after i: Int, _ t: [Token]) -> Int? {
        guard i + 1 < t.count else { return nil }
        return ((i + 1)..<t.count).first { t[$0].text == s }
    }

    private static func match(_ open: String, _ close: String, _ at: Int, _ t: [Token]) -> Int? {
        var d = 0
        for k in at..<t.count {
            if t[k].text == open { d += 1 }
            else if t[k].text == close { d -= 1; if d == 0 { return k } }
        }
        return nil
    }

    private static func isIdentifier(_ s: String) -> Bool {
        guard let f = s.unicodeScalars.first else { return false }
        if CharacterSet.decimalDigits.contains(f) { return false }
        return s.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "$" }
    }

    /// 简易词法：只输出代码里的单词和符号；跳过字符串、模板字符串、注释、正则
    private static func lex(_ source: String) -> [Token] {
        let s = source as NSString
        let n = s.length
        var out: [Token] = []
        var i = 0
        var regexOK = true
        func c(_ k: Int) -> unichar { k < n ? s.character(at: k) : 0 }
        func word(_ u: unichar) -> Bool {
            u == 36 || u == 95 || (48...57).contains(u) || (65...90).contains(u) || (97...122).contains(u) || u > 127
        }
        func add(_ a: Int, _ b: Int) {
            let r = NSRange(location: a, length: b - a)
            let t = s.substring(with: r)
            out.append(Token(text: t, range: r))
            regexOK = ["(", "[", "{", ",", ";", ":", "=", "=>", "!", "&", "|", "?", "+", "-", "*", "%",
                       "<", ">", "~", "^", "return", "case", "typeof", "in", "of", "new", "delete", "void"].contains(t)
        }
        while i < n {
            let ch = c(i), nx = c(i + 1)
            if ch == 32 || ch == 9 || ch == 10 || ch == 13 || ch == 0xA0 || ch == 0xFEFF { i += 1; continue }
            if ch == 47 && nx == 47 { while i < n && c(i) != 10 { i += 1 }; continue }            // //
            if ch == 47 && nx == 42 {                                                               // /* */
                i += 2; while i < n && !(c(i) == 42 && c(i + 1) == 47) { i += 1 }; i = min(n, i + 2); continue
            }
            if ch == 34 || ch == 39 || ch == 96 {                                                   // " ' `
                let q = ch; i += 1
                while i < n { if c(i) == 92 { i += 2; continue }; if c(i) == q { i += 1; break }; i += 1 }
                regexOK = false; continue
            }
            if ch == 47 && regexOK {                                                                // /正则/
                i += 1; var cls = false
                while i < n {
                    let u = c(i)
                    if u == 92 { i += 2; continue }
                    if u == 10 { break }
                    if u == 91 { cls = true } else if u == 93 { cls = false }
                    else if u == 47 && !cls { i += 1; while i < n && word(c(i)) { i += 1 }; break }
                    i += 1
                }
                regexOK = false; continue
            }
            if word(ch) { let a = i; while i < n && word(c(i)) { i += 1 }; add(a, i); continue }
            let a = i
            i += (ch == 61 && nx == 62) ? 2 : 1   // =>
            add(a, i)
        }
        return out
    }
}
