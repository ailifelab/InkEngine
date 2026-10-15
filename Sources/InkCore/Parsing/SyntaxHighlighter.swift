import Foundation

public enum SyntaxKind: String, Sendable { case keyword, string, comment, number, heading, markup, punctuation }
public struct SyntaxToken: Sendable { public var range: NSRange; public var kind: SyntaxKind }

/// 只给可见源码窗口着色，不保留全文件状态，也不改写原文字符。
public enum SyntaxHighlighter {
    public static func tokens(in text: String, format: TextFormat, baseOffset: Int = 0) -> [SyntaxToken] {
        let range = NSRange(location: 0, length: text.utf16.count)
        return (compiledRules[format] ?? []).flatMap { regex, kind in
            regex.matches(in: text, range: range).map { SyntaxToken(range: NSRange(location: baseOffset + $0.range.location, length: $0.range.length), kind: kind) }
        }
    }

    // 规则只随文件类型变化。静态不可变表达式可并发匹配，避免每次输入、滚动都重新编译；
    // 只缓存有限种语法规则，不缓存文稿内容或每个窗口的匹配结果。
    private static let compiledRules: [TextFormat: [(NSRegularExpression, SyntaxKind)]] = Dictionary(uniqueKeysWithValues: TextFormat.allCases.map { ($0, rules(for: $0)) })
    private static func rules(for format: TextFormat) -> [(NSRegularExpression, SyntaxKind)] {
        guard format != .txt else { return [] }
        var rules: [(String, SyntaxKind)] = []
        switch format {
        case .markdown:
            rules = [("(?m)^#{1,6}[^\\n]*", .heading), ("!?\\[[^\\]\\n]*\\]\\([^\\)\\n]*\\)|[*_`]{1,3}[^\\n]*?[*_`]{1,3}", .markup)]
        case .sql:
            rules = [("(?i)\\b(SELECT|FROM|WHERE|INSERT|INTO|UPDATE|DELETE|CREATE|TABLE|JOIN|LEFT|RIGHT|INNER|ON|AS|AND|OR|NOT|NULL|VALUES|GROUP|ORDER|BY|LIMIT|DROP|ALTER|PRIMARY|KEY|DISTINCT|SET|HAVING|ASC|DESC)\\b", .keyword), ("--[^\\n]*|/\\*[\\s\\S]*?\\*/", .comment)]
        case .java, .javascript:
            rules = [("\\b(class|public|private|protected|static|final|void|int|double|boolean|new|return|if|else|for|while|try|catch|throw|throws|import|package|extends|implements|const|let|var|function|async|await|export|default|switch|case|break|this|true|false|null|undefined)\\b", .keyword), ("//[^\\n]*|/\\*[\\s\\S]*?\\*/", .comment)]
        case .yaml:
            rules = [("(?m)^\\s*[^#\\n:]+(?=:)", .keyword), ("(?m)#.*$", .comment), ("\\b(true|false|null|yes|no)\\b", .keyword)]
        case .json:
            rules = [("\\b(true|false|null)\\b", .keyword), ("[{}\\[\\]:,]", .punctuation)]
        case .xml, .html:
            rules = [("</?[A-Za-z][^>]*>", .markup), ("<!--[\\s\\S]*?-->", .comment)]
        case .csv, .tsv:
            rules = [(format == .csv ? "," : "\\t", .punctuation)]
        case .txt: break
        }
        rules.append(("\\b[0-9]+(?:\\.[0-9]+)?\\b", .number))
        rules.append(("\"(?:\\\\.|[^\"\\\\])*\"|'(?:\\\\.|[^'\\\\])*'|`[^`]*`", .string))
        // 注释最后着色，注释内的引号不会被误当作字符串覆盖。
        let comments = rules.filter { $0.1 == .comment }; rules.removeAll { $0.1 == .comment }; rules += comments
        return rules.compactMap { pattern, kind in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return (regex, kind)
        }
    }
}
