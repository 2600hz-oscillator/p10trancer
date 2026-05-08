import SwiftUI

/// In-app docs viewer. Reads `Resources/Manual.md` from the bundle and
/// renders it with custom SwiftUI styling — headings, monospace code,
/// tables. No third-party Markdown library; uses Apple's built-in
/// `AttributedString(markdown:)` for inline formatting and our own
/// block parser for headings / fences / tables.
struct DocsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        renderBlock(block)
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(24)
            }
        }
        .background(Color(red: 0.02, green: 0.02, blue: 0.04))
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack {
            Text("DOCS")
                .font(.system(size: 14, weight: .heavy, design: .monospaced))
                .tracking(2.0)
                .foregroundStyle(.white)
            Spacer()
            Button("CLOSE") { dismiss() }
                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.black)
    }

    // MARK: - Markdown loading

    private var rawMarkdown: String {
        guard let url = Bundle.main.url(forResource: "Manual", withExtension: "md"),
              let s = try? String(contentsOf: url, encoding: .utf8) else {
            return "Manual not found in bundle."
        }
        return s
    }

    private var blocks: [Block] { Self.parse(rawMarkdown) }

    @ViewBuilder
    private func renderBlock(_ block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(.init(text))
                .font(.system(size: headingSize(level), weight: .heavy, design: .monospaced))
                .tracking(level <= 2 ? 1.5 : 0.8)
                .foregroundStyle(level == 1 ? Color.cyan : .white)
                .padding(.top, level <= 2 ? 16 : 8)
                .padding(.bottom, 4)
        case .paragraph(let text):
            Text(attributedParagraph(text))
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.92))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        case .codeBlock(let lines):
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.cyan)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.05))
            .overlay(Rectangle().strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
        case .listItem(let text, let ordered, let n):
            HStack(alignment: .top, spacing: 8) {
                Text(ordered ? "\(n)." : "•")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 22, alignment: .leading)
                Text(attributedParagraph(text))
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .rule:
            Rectangle().fill(Color.white.opacity(0.18)).frame(height: 1).padding(.vertical, 6)
        case .table(let rows):
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIdx, row in
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(attributedParagraph(cell))
                                .font(.system(size: 13, design: rowIdx == 0 ? .monospaced : .default))
                                .fontWeight(rowIdx == 0 ? .heavy : .regular)
                                .foregroundStyle(rowIdx == 0 ? .cyan : .white.opacity(0.9))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .background(rowIdx == 0 ? Color.white.opacity(0.06) : Color.clear)
                    .overlay(
                        Rectangle()
                            .fill(Color.white.opacity(0.10))
                            .frame(height: 1),
                        alignment: .bottom
                    )
                }
            }
            .overlay(Rectangle().strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
        }
    }

    private func attributedParagraph(_ s: String) -> AttributedString {
        if let attr = try? AttributedString(markdown: s, options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnly)) {
            return attr
        }
        return AttributedString(s)
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 26
        case 2: return 20
        case 3: return 16
        default: return 14
        }
    }

    // MARK: - Block parser

    enum Block {
        case heading(level: Int, text: String)
        case paragraph(String)
        case codeBlock(lines: [String])
        case listItem(text: String, ordered: Bool, number: Int)
        case rule
        case table(rows: [[String]])
    }

    static func parse(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        let lines = markdown.components(separatedBy: "\n")
        var i = 0
        var paragraphBuf: [String] = []
        var orderedCount = 0

        func flushParagraph() {
            guard !paragraphBuf.isEmpty else { return }
            let joined = paragraphBuf.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !joined.isEmpty {
                blocks.append(.paragraph(joined))
            }
            paragraphBuf.removeAll()
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Code fence
            if trimmed.hasPrefix("```") {
                flushParagraph()
                var codeLines: [String] = []
                i += 1
                while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    codeLines.append(lines[i])
                    i += 1
                }
                blocks.append(.codeBlock(lines: codeLines))
                i += 1
                continue
            }

            // Table — line starts with `|` and next line is a separator (`|---|...`)
            if trimmed.hasPrefix("|") && i + 1 < lines.count {
                let next = lines[i + 1].trimmingCharacters(in: .whitespaces)
                if next.hasPrefix("|") && next.contains("---") {
                    flushParagraph()
                    var tableRows: [[String]] = []
                    tableRows.append(parseTableRow(trimmed))
                    i += 2 // skip separator
                    while i < lines.count {
                        let row = lines[i].trimmingCharacters(in: .whitespaces)
                        guard row.hasPrefix("|") else { break }
                        tableRows.append(parseTableRow(row))
                        i += 1
                    }
                    blocks.append(.table(rows: tableRows))
                    continue
                }
            }

            // Heading
            if let level = headingLevel(of: trimmed) {
                flushParagraph()
                let text = String(trimmed.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(level: level, text: text))
                i += 1
                continue
            }

            // Horizontal rule
            if trimmed == "---" || trimmed == "***" {
                flushParagraph()
                blocks.append(.rule)
                i += 1
                continue
            }

            // Unordered list
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                flushParagraph()
                let text = String(trimmed.dropFirst(2))
                blocks.append(.listItem(text: text, ordered: false, number: 0))
                orderedCount = 0
                i += 1
                continue
            }

            // Ordered list (numeric. )
            if let dot = trimmed.firstIndex(of: "."),
               let _ = Int(trimmed[..<dot]),
               trimmed.distance(from: trimmed.startIndex, to: dot) <= 2,
               trimmed.index(after: dot) < trimmed.endIndex,
               trimmed[trimmed.index(after: dot)] == " " {
                flushParagraph()
                orderedCount += 1
                let text = String(trimmed[trimmed.index(dot, offsetBy: 2)...])
                blocks.append(.listItem(text: text, ordered: true, number: orderedCount))
                i += 1
                continue
            } else {
                orderedCount = 0
            }

            // Blank line breaks paragraphs
            if trimmed.isEmpty {
                flushParagraph()
                i += 1
                continue
            }

            // Blockquote (> ...) — treat as paragraph with leading marker
            if trimmed.hasPrefix("> ") {
                flushParagraph()
                blocks.append(.paragraph("*\(String(trimmed.dropFirst(2)))*"))
                i += 1
                continue
            }

            paragraphBuf.append(trimmed)
            i += 1
        }
        flushParagraph()
        return blocks
    }

    private static func headingLevel(of line: String) -> Int? {
        guard line.hasPrefix("#") else { return nil }
        var level = 0
        for c in line {
            if c == "#" { level += 1 } else { break }
        }
        guard level >= 1 && level <= 6 else { return nil }
        guard line.count > level && line[line.index(line.startIndex, offsetBy: level)] == " " else { return nil }
        return level
    }

    private static func parseTableRow(_ line: String) -> [String] {
        var cells: [String] = []
        var trimmed = line
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        for cell in trimmed.components(separatedBy: "|") {
            cells.append(cell.trimmingCharacters(in: .whitespaces))
        }
        return cells
    }
}
