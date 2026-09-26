import Foundation

// 规则引擎自动化测试：用本地假网页模拟常见书源写法，逐条核对解析结果。
// 在 GitHub 云端（macOS）运行，任何一条失败都会让编译失败。

var passed = 0
var failed = 0

func check(_ name: String, _ actual: String, _ expected: String) {
    if actual == expected {
        passed += 1
        print("✅ \(name)")
    } else {
        failed += 1
        print("❌ \(name)\n   期望: \(expected.debugDescription)\n   实际: \(actual.debugDescription)")
    }
}

func checkList(_ name: String, _ actual: [String]?, _ expected: [String]) {
    check(name, (actual ?? []).joined(separator: " | "), expected.joined(separator: " | "))
}

let html = """
<html><head><title>测试站</title></head><body>
<div id="main">
  <ul class="list">
    <li class="item"><a href="/book/1.html" title="t1">斗破苍穹</a><span class="author">作者：天蚕土豆</span><img src="/c/1.jpg"></li>
    <li class="item"><a href="/book/2.html">凡人修仙传</a><span class="author">作者：忘语</span><img data-original="/c/2.jpg"></li>
    <li class="item vip"><a href="https://other.com/b/3">遮天</a><span class="author">辰东 著</span></li>
  </ul>
  <div class="intro">  简介第一行<br>简介&nbsp;第二行<p>第三段</p></div>
  <div id="content">&nbsp;&nbsp;&nbsp;&nbsp;第一段正文。<br><br>&nbsp;&nbsp;&nbsp;&nbsp;第二段正文。<script>ad()</script><br>第三段</div>
  <a id="next" href="/book/1_2.html">下一页</a>
</div>
</body></html>
"""

let source = BookSource(bookSourceUrl: "https://www.test.com", bookSourceName: "测试源")
let e = RuleEngine(source: source)
e.setContent(html, baseUrl: "https://www.test.com/search?q=x")
e.setRedirectUrl("https://www.test.com/search?q=x")

// ── 默认 JSoup 语法
check("列表 class.item", "\(e.getElements("class.item").count)", "3")
check("列表 @CSS", "\(e.getElements("@CSS:li.item").count)", "3")
check("列表 id.main@tag.li", "\(e.getElements("id.main@tag.li").count)", "3")
check("列表 索引 .0", "\(e.getElements("class.item.0").count)", "1")
check("列表 排除 !0", "\(e.getElements("class.item!0").count)", "2")
check("列表 负索引 .-1", "\(e.getElements("class.item.-1").count)", "1")
check("列表 [0,2]", "\(e.getElements("class.item[0,2]").count)", "2")
check("列表 [1:2]", "\(e.getElements("class.item[1:2]").count)", "2")
check("列表 [-1:0] 反向", "\(e.getElements("class.item[-1:0]").count)", "3")
check("列表 || 或", "\(e.getElements("class.none||class.item").count)", "3")
check("列表 && 合并", "\(e.getElements("class.item.0&&class.item.1").count)", "2")
check("列表 CSS 选择器", "\(e.getElements("ul.list > li").count)", "3")

let items = e.getElements("class.item")
func item(_ i: Int) -> RuleEngine {
    let x = RuleEngine(source: source)
    x.setContent(items[i], baseUrl: "https://www.test.com/search?q=x")
    x.setRedirectUrl("https://www.test.com/search?q=x")
    return x
}
check("书名 tag.a@text", item(0).getString("tag.a@text"), "斗破苍穹")
check("书名 tag.a.0@text", item(1).getString("tag.a.0@text"), "凡人修仙传")
check("书名 CSS", item(0).getString("@CSS:a@text"), "斗破苍穹")
check("属性 title", item(0).getString("tag.a@title"), "t1")
check("作者 替换 ##", item(0).getString("class.author@text##作者："), "天蚕土豆")
check("作者 格式化", Util.formatAuthor(item(2).getString("class.author@text")), "辰东")
check("链接 相对转绝对", item(0).getString("tag.a@href", isUrl: true), "https://www.test.com/book/1.html")
check("链接 绝对保持", item(2).getString("tag.a@href", isUrl: true), "https://other.com/b/3")
check("封面 || 或", item(1).getString("tag.img@src||tag.img@data-original"), "/c/2.jpg")
check("ownText", item(0).getString("tag.li@ownText"), "")
check("text 节点 li", item(0).getString("class.author@textNodes"), "作者：天蚕土豆")
check("@@ 前缀", item(0).getString("@@tag.a@text"), "斗破苍穹")
check("替换 ###只取第一个", item(0).getString("class.author@text##作者：(.*)##$1###"), "天蚕土豆")

// ── 文本拼接和 {{}} JS
check("{{}} JS 表达式", item(0).getString("{{1+2}}"), "3")
check("@js: 处理结果", item(0).getString("tag.a@text@js:result+'!'"), "斗破苍穹!")
check("<js></js>", item(0).getString("tag.a@text<js>result.length</js>"), "4")
check("{{@规则}} 拼接", item(0).getString("书名:{{@@tag.a@text}}"), "书名:斗破苍穹")
check("java.base64", e.getString("@js:java.base64Encode('abc')"), "YWJj")
check("java.md5", e.getString("@js:java.md5Encode('abc')"), "900150983cd24fb0d6963f7d28e17f72")
check("java.put/get", e.getString("@js:java.put('k','v1');java.get('k')"), "v1")
check("@put / @get", { _ = e.getString("@put:{bid:\"tag.title@text\"}tag.title@text"); return e.getString("@get:{bid}") }(), "测试站")
check("java.getString 在 JS 中", e.getString("@js:java.getString('tag.title@text')"), "测试站")
check("t2s 繁转简", e.getString("@js:java.t2s('簡體')"), "简体")
check("中文数字章节", e.getString("@js:java.toNumChapter('第一百二十三章 标题')"), "第123章 标题")

// ── 正文
let content = Util.formatContent(e.getString("id.content@html", unescape: false))
check("正文 去广告脚本+分段", content, "　　第一段正文。\n　　第二段正文。\n　　第三段")
check("简介 多段", Util.formatIntro(e.getString("class.intro@html")) ?? "", "　　简介第一行\n　　简介 第二行\n　　第三段")
check("下一页链接", e.getStringList("id.next@href", isUrl: true)?.first ?? "", "https://www.test.com/book/1_2.html")

// ── XPath
check("XPath 列表", "\(e.getElements("//li[@class='item']").count)", "2")
check("XPath 文本", e.getString("//li[1]/a/text()"), "斗破苍穹")
check("XPath 属性", e.getString("@XPath://li[2]/a/@href"), "/book/2.html")

// ── 正则列表（: 开头）
let re = RuleEngine(source: source)
re.setContent(html, baseUrl: "https://www.test.com/")
let rItems = re.getElements(":<a href=\"([^\"]+)\"[^>]*>([^<]+)</a>")
check("正则 列表数（id 在 href 前的不匹配）", "\(rItems.count)", "3")
if rItems.count > 0 {
    let x = RuleEngine(source: source)
    x.setContent(rItems[0], baseUrl: "https://www.test.com/")
    check("正则 $2", x.getString("$2"), "斗破苍穹")
    check("正则 $1 链接", x.getString("$1", isUrl: true), "https://www.test.com/book/1.html")
}

// ── JSON
let json = """
{"code":0,"data":{"list":[
 {"name":"诡秘之主","author":"爱潜水的乌贼","id":101,"tags":["玄幻","西幻"],"vip":true},
 {"name":"大奉打更人","author":"卖报小郎君","id":102,"tags":["仙侠"],"vip":false}
],"total":2}}
"""
let j = RuleEngine(source: source)
j.setContent(json, baseUrl: "https://api.test.com/s")
check("JSON 列表", "\(j.getElements("$.data.list[*]").count)", "2")
check("JSON 列表 无[*]", "\(j.getElements("$.data.list").count)", "2")
check("JSON 深度扫描", j.getString("$..total"), "2")
check("JSON 过滤器", j.getString("$.data.list[?(@.id == 102)].name"), "大奉打更人")
check("JSON 负索引", j.getString("$.data.list[-1].name"), "大奉打更人")
let jItems = j.getElements("$.data.list[*]")
if jItems.count == 2 {
    let x = RuleEngine(source: source)
    x.setContent(jItems[0], baseUrl: "https://api.test.com/s")
    check("JSON 字段", x.getString("$.name"), "诡秘之主")
    check("JSON 字段 无$", x.getString("name"), "诡秘之主")
    check("JSON 数组拼接", x.getStringList("$.tags")?.joined(separator: ",") ?? "", "玄幻,西幻")
    check("JSON 数字", x.getString("$.id"), "101")
    check("JSON 布尔", x.getString("$.vip"), "true")
    check("JSON {{}} 拼接链接", x.getString("/book/{{$.id}}.html", isUrl: true), "https://api.test.com/book/101.html")
    check("JSON {$.} 内嵌", x.getString("{$.name}-{$.author}"), "诡秘之主-爱潜水的乌贼")
    check("JSON && 合并", x.getString("$.name&&$.author"), "诡秘之主\n爱潜水的乌贼")
}

// ── 网址规则
let au1 = AnalyzeUrl("/search?q={{key}}&p={{page}}", key: "斗破", page: 2, source: source)
check("URL {{key}} {{page}}", au1.requestUrl, "https://www.test.com/search?q=%E6%96%97%E7%A0%B4&p=2")
let au2 = AnalyzeUrl("/s.php,{\"method\":\"POST\",\"body\":\"k={{key}}\",\"charset\":\"gbk\"}", key: "斗破", source: source)
check("URL POST 方法", au2.method, "POST")
check("URL POST 地址", au2.url, "https://www.test.com/s.php")
check("URL POST 包体", au2.body ?? "", "k=斗破")
let au3 = AnalyzeUrl("https://www.test.com/s?k={{key}},{'charset':'gbk'}", key: "斗破", source: source)
check("URL GBK 编码", au3.requestUrl, "https://www.test.com/s?k=%B6%B7%C6%C6")
let au4 = AnalyzeUrl("https://www.test.com/list<,_2,_3>.html", page: 1, source: source)
check("URL 分页 <> 第1页", au4.url, "https://www.test.com/list.html")
let au5 = AnalyzeUrl("https://www.test.com/list<,_2,_3>.html", page: 3, source: source)
check("URL 分页 <> 第3页", au5.url, "https://www.test.com/list_3.html")
let au6 = AnalyzeUrl("@js:'https://www.test.com/s?k='+encodeURIComponent(key)", key: "遮天", source: source)
check("URL @js 生成", au6.url, "https://www.test.com/s?k=%E9%81%AE%E5%A4%A9")
let au7 = AnalyzeUrl("https://www.test.com/s?k=searchKey&p=searchPage", key: "遮天", page: 1, source: source)
check("URL 旧版 searchKey", au7.requestUrl, "https://www.test.com/s?k=%E9%81%AE%E5%A4%A9&p=1")

// ── 书源导入（宽松格式）
let srcJSON = """
[{"bookSourceUrl":"https://a.com","bookSourceName":"A","enabled":1,"bookSourceType":"0",
  "ruleSearch":{"bookList":"class.item","name":"tag.a@text","checkKeyWord":123},
  "header":{"User-Agent":"X"}},
 {"bookSourceName":"缺地址"}]
"""
let imported = (try? BookSourceImporter.parse(Data(srcJSON.utf8))) ?? []
check("导入 数量（跳过无效）", "\(imported.count)", "1")
check("导入 数字型布尔", "\(imported.first?.isEnabled ?? false)", "true")
check("导入 规则数字转字符串", imported.first?.ruleSearch?.checkKeyWord ?? "", "123")
check("导入 header 对象", imported.first?.headerMap()["User-Agent"] ?? "", "X")

// ── 真实书源文件（从 GitHub 下载的 Legado 书源）
let samplesDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("samples")
let sampleFiles = ((try? FileManager.default.contentsOfDirectory(atPath: samplesDir.path)) ?? []).filter { $0.hasPrefix("real") }.sorted()
check("真实书源 样本文件数", "\(sampleFiles.count)", "5")
for f in sampleFiles {
    let d = (try? Data(contentsOf: samplesDir.appendingPathComponent(f))) ?? Data()
    let all = ((try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]]) ?? []
    // 地址为空的是模板/占位条目，应被跳过
    let expected = all.filter { !((($0["bookSourceUrl"] as? String) ?? "").trimmingCharacters(in: .whitespaces).isEmpty) }.count
    do {
        let r = try BookSourceImporter.parseReport(BookSourceImporter.text(from: d))
        check("真实书源 \(f) 导入有效条目", "\(r.sources.count)", "\(expected)")
    } catch {
        check("真实书源 \(f) 导入有效条目", expected == 0 ? "0" : "错误: \(error.localizedDescription)", "\(expected)")
    }
}

// ── 用户提供的「起点小说（qimo）」：只有按钮的登录界面、login 脚本无 @js: 前缀、header 用 <js> 取 Token
if let qd = try? Data(contentsOf: samplesDir.appendingPathComponent("qimo.json")),
   let q = try? BookSourceImporter.parseReport(BookSourceImporter.text(from: qd)).sources.first {
    let qr = SourceLogin.rows(q)
    check("起点 登录界面行数", "\(qr.count)", "7")
    check("起点 按钮名", qr.prefix(6).map(\.name).joined(separator: ","), "登录起点,重新上传,查看登录状态,前往复制最新 Tag,退出登录,清除数据")
    check("起点 Token 输入框", qr.last?.type ?? "", "password")
    check("起点 登录脚本识别", "\(SourceLogin.loginJs(q) != nil)", "true")
    let qcb = TestLoginCB()
    _ = try? SourceLogin.buttonAction(q, action: "checkLoginStatus()", info: [:], callback: qcb)
    check("起点 查看登录状态(未登录)", qcb.toasts.first ?? "", "未登录，请先「登录起点」")
    CookieBridge().setCookie("https://www.qidian.com", "ywkey=K1; ywguid=G1")
    let qcb2 = TestLoginCB()
    _ = try? SourceLogin.buttonAction(q, action: "checkLoginStatus()", info: [:], callback: qcb2)
    check("起点 cookie.getCookie(无协议域名)", qcb2.toasts.first ?? "", "已登录")
    _ = try? SourceLogin.buttonAction(q, action: "logout()", info: [:], callback: qcb2)
    check("起点 退出登录清 Cookie", CookieBridge().getCookie("qidian.com"), "")
    _ = SourceLogin.saveInfo(q, ["Token": "T0K"])
    check("起点 header 脚本带 Token", q.headerMap()["Authorization"] ?? "", "Bearer T0K")
} else {
    check("起点 书源读取", "失败", "成功")
}

// ── 导入容错
func importCount(_ s: String) -> String {
    do { return "\((try BookSourceImporter.parseReport(s)).sources.count)" } catch { return "错误" }
}
check("导入 带 BOM", importCount(BookSourceImporter.text(from: Data("\u{FEFF}[{\"bookSourceUrl\":\"https://a.com\",\"bookSourceName\":\"A\"}]".utf8))), "1")
check("导入 单个对象", importCount("{\"bookSourceUrl\":\"https://a.com\",\"bookSourceName\":\"A\"}"), "1")
check("导入 尾逗号", importCount("[{\"bookSourceUrl\":\"https://a.com\",\"bookSourceName\":\"A\",},]"), "1")
check("导入 规则是字符串 JSON", importCount("[{\"bookSourceUrl\":\"https://a.com\",\"bookSourceName\":\"A\",\"ruleSearch\":\"{\\\"name\\\":\\\"x\\\"}\"}]"), "1")
check("导入 规则是数组", importCount("[{\"bookSourceUrl\":\"https://a.com\",\"bookSourceName\":\"A\",\"ruleToc\":[]}]"), "1")
check("导入 null 字段", importCount("[{\"bookSourceUrl\":\"https://a.com\",\"bookSourceName\":\"A\",\"header\":null,\"weight\":null}]"), "1")
check("导入 数字小数", importCount("[{\"bookSourceUrl\":\"https://a.com\",\"bookSourceName\":\"A\",\"weight\":1.5,\"customOrder\":\"3\"}]"), "1")
check("导入 包在 data 里", importCount("{\"data\":[{\"bookSourceUrl\":\"https://a.com\",\"bookSourceName\":\"A\"}]}"), "1")
check("导入 缺名称用网址", (try? BookSourceImporter.parseReport("[{\"bookSourceUrl\":\"https://a.com\"}]"))?.sources.first?.bookSourceName ?? "", "https://a.com")
check("导入 不是 JSON 给出原因", { do { _ = try BookSourceImporter.parseReport("<html>"); return "无错误" } catch { return error.localizedDescription.hasPrefix("内容不是 JSON") ? "ok" : error.localizedDescription } }(), "ok")
check("导入 RSS 源提示", { do { _ = try BookSourceImporter.parseReport("[{\"sourceUrl\":\"https://a.com\",\"sourceName\":\"A\"}]"); return "无错误" } catch { return error.localizedDescription.contains("订阅源") ? "ok" : error.localizedDescription } }(), "ok")
check("链接 提取 legado://", BookSourceImporter.extractURL("legado://import/bookSource?src=https%3A%2F%2Fa.com%2Fs.json") ?? "", "https://a.com/s.json")
check("链接 提取 夹杂文字", BookSourceImporter.extractURL("书源地址：https://a.com/s.json 复制打开") ?? "", "https://a.com/s.json")

// ── 登录
let loginSource = BookSource(bookSourceUrl: "https://login.test.com", bookSourceName: "登录测试",
    loginUrl: "@js:function login(){ java.ajax(\"https://login.test.com/api/login?u=\"+encodeURIComponent(result.username)+\"&p=\"+encodeURIComponent(result.password)); source.putLoginHeader({token:'abc123'}); }",
    loginUi: "[{\"name\":\"username\",\"type\":\"text\"},{\"name\":\"password\",\"type\":\"password\"},{\"name\":\"login\",\"type\":\"button\",\"action\":\"login.apply(this)\"}]")
check("登录 表单行数", "\(SourceLogin.rows(loginSource).count)", "3")
check("登录 表单字段", SourceLogin.rows(loginSource).map(\.name).joined(separator: ","), "username,password,login")
try? SourceLogin.login(loginSource, info: ["username": "u1", "password": "p1"])
check("登录 保存账号信息", LoginStore.loginInfoMap(loginSource.bookSourceUrl)["username"] ?? "", "u1")
check("登录 保存登录头", LoginStore.headerMap(loginSource.bookSourceUrl)["token"] ?? "", "abc123")
check("登录 请求头自动带上", loginSource.headerMap()["token"] ?? "", "abc123")
check("登录 状态", "\(LoginStore.isLoggedIn(loginSource.bookSourceUrl))", "true")
let loginSrc2 = BookSource(bookSourceUrl: "https://l2.test.com", bookSourceName: "L2",
    loginUi: "{\"name\":\"v\",\"type\":\"toggle\",\"chars\":[\"开\",\"关\"]}")
check("登录 UI 宽松 JSON(单对象)", "\(SourceLogin.rows(loginSrc2).count)", "1")
// 真实书源常见写法：loginUrl 直接是 function login(){...}，没有 @js: 前缀；用 Java Map 的 .get()
let loginSrc3 = BookSource(bookSourceUrl: "https://l3.test.com", bookSourceName: "L3",
    loginUrl: "function login() {\n  var info = source.getLoginInfoMap();\n  source.putLoginHeader(JSON.stringify({Authorization: 'Bearer ' + info.get('账号') + result.get('密码')}));\n}",
    loginUi: "[{\"name\":\"账号\",\"type\":\"text\"},{\"name\":\"密码\",\"type\":\"password\"}]")
check("登录 无前缀 JS 识别", "\(SourceLogin.loginJs(loginSrc3) != nil)", "true")
check("登录 无前缀 JS 不当网址", "\(SourceLogin.loginPageUrl(loginSrc3) == nil)", "true")
check("登录 有 login 函数", "\(SourceLogin.hasLoginFunction(loginSrc3))", "true")
do { try SourceLogin.login(loginSrc3, info: ["账号": "me", "密码": "pw"]) } catch { print("  login3 error: \(error)") }
check("登录 Map.get 写法", LoginStore.headerMap(loginSrc3.bookSourceUrl)["Authorization"] ?? "", "Bearer mepw")
// 书源自带的登录界面：样式、单引号显示名、JS 生成界面、脚本回调 upLoginData/toast
final class TestLoginCB: LoginUICallback {
    var data: [String: Any]?; var toasts: [String] = []; var re = 0
    func upLoginData(_ d: [String: Any]?) { data = d }
    func reLoginView(_ deltaUp: Bool) { re += 1 }
    func toast(_ msg: String) { toasts.append(msg) }
    func openBrowser(_ url: String, title: String) {}
}
let uiSrc = BookSource(bookSourceUrl: "https://ui.test.com", bookSourceName: "UI",
    loginUrl: "function fill(){ java.upLoginData({'账号':'auto'}); java.toast('已填充'); java.reLoginView(); }\nfunction login(){}",
    loginUi: "[{\"name\":\"账号\",\"type\":\"text\",\"style\":{\"layout_flexBasisPercent\":0.5,\"layout_flexGrow\":1}},{\"name\":\"fill\",\"type\":\"button\",\"viewName\":\"'一键填充'\",\"action\":\"fill()\",\"style\":{\"layout_wrapBefore\":true}},{\"name\":\"线路\",\"type\":\"select\",\"chars\":[\"A\",\"B\"],\"default\":\"B\"}]")
let uiRows = SourceLogin.rows(uiSrc)
check("登录UI 行数", "\(uiRows.count)", "3")
check("登录UI 样式 basis", "\(uiRows.first?.style.flexBasisPercent ?? 0)", "0.5")
check("登录UI 样式 wrapBefore", "\(uiRows[1].style.wrapBefore)", "true")
check("登录UI 单引号显示名", uiRows[1].literalViewName ?? "", "一键填充")
check("登录UI select 默认", uiRows[2].defaultValue ?? "", "B")
let cb = TestLoginCB()
_ = try? SourceLogin.buttonAction(uiSrc, action: "fill()", info: [:], callback: cb)
check("登录UI upLoginData 回调", "\(cb.data?["账号"] ?? "")", "auto")
check("登录UI toast 回调", cb.toasts.first ?? "", "已填充")
check("登录UI reLoginView 回调", "\(cb.re)", "1")
let jsUiSrc = BookSource(bookSourceUrl: "https://ui2.test.com", bookSourceName: "UI2",
    loginUrl: "function login(){}",
    loginUi: "@js:\nvar a=[{name:'手机号',type:'text'}]; if(result.get('模式')=='验证码') a.push({name:'验证码',type:'text'}); JSON.stringify(a)")
check("登录UI JS 生成", "\(SourceLogin.rows(jsUiSrc, current: ["模式": "验证码"]).count)", "2")
let loginSrc4 = BookSource(bookSourceUrl: "https://www.l4.com", bookSourceName: "L4", loginUrl: "https://www.l4.com/login.php")
check("登录 网址型", SourceLogin.loginPageUrl(loginSrc4) ?? "", "https://www.l4.com/login.php")
check("登录 网址型 非 JS", "\(SourceLogin.loginJs(loginSrc4) == nil)", "true")
let loginSrc5 = BookSource(bookSourceUrl: "https://www.l5.com", bookSourceName: "L5", loginUrl: "/user/login.html")
check("登录 相对网址", SourceLogin.webLoginUrl(loginSrc5), "https://www.l5.com/user/login.html")
// 对照 Legado 源码的行为
let dfSrc = BookSource(bookSourceUrl: "https://df.test.com", bookSourceName: "DF",
    loginUrl: "function login(){ source.putLoginHeader(JSON.stringify({k: source.getLoginInfoMap().get('线路')})); }",
    loginUi: "[{\"name\":\"账号\",\"type\":\"text\",\"default\":\"guest\"},{\"name\":\"线路\",\"type\":\"select\",\"chars\":[\"A\",\"B\"],\"default\":\"B\"},{\"name\":\"go\",\"type\":\"button\",\"action\":\"login()\"}]")
check("Legado getLoginInfoMap 默认值", SourceLogin.loginInfoMap(dfSrc).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ","), "线路=B,账号=guest")
check("Legado getLoginInfoMap 自动保存", LoginStore.loginInfoMap(dfSrc.bookSourceUrl)["账号"] ?? "", "guest")
_ = try? SourceLogin.buttonAction(dfSrc, action: "login()", info: LoginStore.loginInfoMap(dfSrc.bookSourceUrl))
check("Legado 按钮 action 调 login()", LoginStore.headerMap(dfSrc.bookSourceUrl)["k"] ?? "", "B")
check("Legado removeLoginHeader", { _ = try? SourceLogin.buttonAction(dfSrc, action: "source.removeLoginHeader()", info: [:]); return LoginStore.loginHeader(dfSrc.bookSourceUrl) ?? "" }(), "")
try? SourceLogin.login(dfSrc, info: [:])
check("Legado 空表单确认=删除登录信息", LoginStore.loginInfo(dfSrc.bookSourceUrl) ?? "nil", "nil")
check("Legado isAbsUrl 网址", "\(SourceLogin.isAbsUrl("https://a.com/x"))", "true")
check("Legado isAbsUrl 脚本", "\(SourceLogin.isAbsUrl("loginQidian()"))", "false")
let lcSrc = BookSource(bookSourceUrl: "https://lc.test.com", bookSourceName: "LC", loginUrl: "function login(){}",
    loginUi: "[{\"name\":\"b\",\"type\":\"button\",\"action\":\"java.put('lc', String(isLongClick))\"}]")
_ = try? SourceLogin.buttonAction(lcSrc, action: "java.put('lc', String(isLongClick))", info: [:], isLongClick: true)
check("Legado 长按 isLongClick", VariableStore.shared.get("src:https://lc.test.com", "lc") ?? "", "true")
// loginUi 常见的「不标准 JSON」（Legado 用 Gson 宽松模式都能识别）
let rawNL = "[{\"name\":\"登录\",\"type\":\"button\",\"action\":\"var a = 1;\n java.toast('x')\"},\n{name:'账号', type:'text',},\n// 注释\n{\"name\":\"密码\",\"type\":\"password\"},]"
check("loginUi 字符串内换行/单引号/注释/尾逗号", "\((LenientJSON.parse(rawNL) as? [Any])?.count ?? -1)", "3")
let nlSrc = BookSource(bookSourceUrl: "https://nl.test.com", bookSourceName: "NL", loginUrl: "function login(){}", loginUi: rawNL)
check("loginUi 宽松 JSON 生成控件", SourceLogin.rows(nlSrc).map(\.name).joined(separator: ","), "登录,账号,密码")
// 书源文件里 loginUi 直接写成数组（不是字符串）
let arrImport = "[{\"bookSourceUrl\":\"https://arr.test.com\",\"bookSourceName\":\"ARR\",\"loginUrl\":\"function login(){}\",\"loginUi\":[{\"name\":\"u\",\"type\":\"text\"},{\"name\":\"b\",\"type\":\"button\",\"action\":\"login()\"}]}]"
if let a = try? BookSourceImporter.parseReport(arrImport).sources.first {
    check("loginUi 为数组时导入", "\(SourceLogin.rows(a).count)", "2")
} else { check("loginUi 为数组时导入", "失败", "2") }
check("宽松 JSON 不误吞普通文本", "\(LenientJSON.parse("hello") == nil)", "true")
// Rhino 写法兼容（JSC 会报语法错误，导致整段登录脚本/界面不执行）
check("Rhino 顶层 const → var", RhinoCompat.normalize("const a = 1; function f(){ const b = 2 }"), "var a = 1; function f(){ const b = 2 }")
check("Rhino 字符串内不改", RhinoCompat.normalize("var s = 'const x = 1';"), "var s = 'const x = 1';")
check("Rhino 参数重复声明", RhinoCompat.normalize("function f(a){ let a = 1; return a }"), "function f(a){ var a = 1; return a }")
check("Rhino 解构箭头参数", RhinoCompat.normalize("x.map([k, v] => k)"), "x.map(([k, v]) => k)")
let rhSrc = BookSource(bookSourceUrl: "https://rh.test.com", bookSourceName: "RH",
    loginUrl: "const API = 'x';\nfunction login(){}",
    loginUi: "@js:\nconst rows = [{name:'账号', type:'text'}, {name:'登录', type:'button', action:'login()'}];\nlet result = JSON.stringify(rows);\nresult",
    jsLib: "const API = 'lib';\nfunction helper(){ return 1 }")
check("Rhino jsLib+loginUrl 重复 const 仍能生成界面", SourceLogin.rows(rhSrc).map(\.name).joined(separator: ","), "账号,登录")
check("Rhino 远程 jsLib 非 JSON 原样", "\(JsLibLoader.scripts("function a(){}").count)", "1")
let brokenSrc = BookSource(bookSourceUrl: "https://bk.test.com", bookSourceName: "BK", loginUrl: "function login(){}",
    loginUi: "[{\"name\":\"账号\",\"type\":\"text\"} {\"name\":\"登录\",\"type\":\"button\",\"action\":\"login()\"}] 垃圾")
check("导入 loginUI 键名大小写", (try? BookSourceImporter.parseReport("[{\"bookSourceUrl\":\"https://k.com\",\"bookSourceName\":\"K\",\"loginUI\":\"[{\\\"name\\\":\\\"a\\\"}]\"}]"))?.sources.first?.hasLoginUi.description ?? "失败", "true")
check("导入 起点 loginUi 不丢", { if let d = try? Data(contentsOf: samplesDir.appendingPathComponent("qimo.json")), let r = try? BookSourceImporter.parseReport(BookSourceImporter.text(from: d)) { return "\(r.loginUiCount),\(r.lostLoginUi.count)" }; return "失败" }(), "1,0")
check("loginUi 整体坏掉时逐项救回", SourceLogin.rows(brokenSrc).map(\.name).joined(separator: ","), "账号,登录")

// ── 加解密
let aes = SymmetricCryptoBridge("AES/CBC/PKCS5Padding", Data("1234567890123456".utf8), Data("abcdefghijklmnop".utf8))
let enc = aes.encryptBase64("你好世界")
check("AES 加解密往返", aes.decryptStr(enc), "你好世界")

print("\n结果：通过 \(passed) 项，失败 \(failed) 项")
exit(failed == 0 ? 0 : 1)
