// Standalone regression harness; run these commands from the repository root in zsh.
// Select the full Xcode toolchain even when xcode-select points at CommandLineTools:
// export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
// xcrun swift build
// ink_reader_bin="$(xcrun swift build --show-bin-path)"
// ink_reader_link=("$ink_reader_bin/libInkCore.a")
// if [[ ! -f "$ink_reader_link[1]" ]]; then ink_reader_link=("$ink_reader_bin/InkCore.build/"*.o(N)); fi
// (( ${#ink_reader_link} > 0 )) || { print -u2 "InkCore link inputs missing"; return 1; }
// mkdir -p build.noindex/DuoAudit/Pagination
// xcrun swiftc -parse-as-library -O -target "$(uname -m)-apple-macosx26.0" \
//   -I "$ink_reader_bin" -I "$ink_reader_bin/Modules" "${ink_reader_link[@]}" \
//   App/Design/ReadingTheme.swift App/Views/Reading/PagedReader.swift Scripts/test-reader-pagination.swift \
//   -o build.noindex/DuoAudit/Pagination/regression
// build.noindex/DuoAudit/Pagination/regression
import Foundation
import InkCore

@main struct ReaderPaginationRegression {
    static func main() async {
        let sizes = [CGSize(width: 330, height: 550), CGSize(width: 700, height: 720), CGSize(width: 480, height: 430)]
        let paragraph = "雨声从窗外移来，灯火仍照着案上的旧书。我们翻到下一页，书中的故事还在继续。👨‍👩‍👧‍👦 e\u{301}\n"
        let prose = String(repeating: paragraph, count: 4000)
        let fixtures: [(String, TextFormat)] = [
            (prose, .txt),
            ("# 雨夜\n\n" + prose + "\n| 人物 | 记忆 |\n| --- | --- |\n| 三叔 | " + String(repeating: "旧事未完，", count: 200) + " |\n", .markdown)
        ]
        var checks = 0
        for (source, format) in fixtures {
            let parsed = TextParser.parse(source, format: format)
            var anchor = 0
            for step in 0..<60 {
                let size = sizes[step % sizes.count]
                let layout = ReadingLayout(parsed: parsed, fontSize: 21, size: size, theme: .white, startOffset: anchor)
                precondition(!layout.pages.isEmpty && layout.nextOffset > anchor, "Page turn must advance after repeated size changes")
                precondition(layout.startOffset <= anchor && layout.containsSource(anchor), "Resize must retain the source anchor")
                precondition(layout.text.length == layout.sourceOffsets.count, "UTF-16 source map must match shaped text")
                precondition(layout.lines().allSatisfy { $0.sourceOffset >= layout.startOffset }, "Visible lines must refer to the retained source page")
                let restored = ReadingLayout(parsed: parsed, fontSize: 21, size: size, theme: .white, startOffset: anchor)
                precondition(restored.pages == layout.pages && restored.nextOffset == layout.nextOffset, "Restoring a pane must reproduce its page")
                anchor = layout.nextOffset
                checks += 5
            }
        }
        let parsed = TextParser.parse(prose, format: .txt)
        var durations: [Double] = []
        for index in 0..<30 {
            let start = Date()
            _ = ReadingLayout(parsed: parsed, fontSize: 21, size: sizes[index % sizes.count], theme: .white, startOffset: 12000)
            durations.append(Date().timeIntervalSince(start))
        }
        durations.sort()
        let cancelledStart = Date()
        for _ in 0..<30 {
            let task = Task.detached {
                withUnsafeCurrentTask { $0?.cancel() }
                return ReadingLayout(parsed: parsed, fontSize: 21, size: sizes[0], theme: .white, startOffset: 12000)
            }
            let discarded = await task.value
            precondition(discarded.pages.isEmpty && discarded.text.length == 0, "Superseded layout must stop before formatting paragraphs")
            checks += 1
        }
        print("PASS \(checks) checks: plain/Markdown Unicode anchors, repeated resize/page turns, restored pane pages, cancelled pagination")
        print("layout median_ms=\(durations[15] * 1000) p95_ms=\(durations[28] * 1000), superseded_30_ms=\(Date().timeIntervalSince(cancelledStart) * 1000)")
    }
}
