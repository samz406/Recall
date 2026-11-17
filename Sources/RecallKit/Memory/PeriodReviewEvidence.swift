import Foundation

/// References select text already present in this exact, redacted daily-review row. This avoids
/// asking a model to transcribe it again. Legacy quotations only recover typography/line wrapping;
/// words, negations, numbers and the cited row's identity are never guessed or replaced.
enum PeriodReviewEvidence {
    static func canonicalID(_ raw: String, rows: [String: PeriodReviewFromDaily.Row]) -> String? {
        var id = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if id.hasPrefix("["), id.hasSuffix("]") { id = String(id.dropFirst().dropLast()) }
        return rows[id] == nil ? nil : id
    }
    static func quote(_ raw: String, reference: String?, row: PeriodReviewFromDaily.Row) -> String? {
        let sources: [String]
        if let reference {
            let field = reference.trimmingCharacters(in: .whitespacesAndNewlines)
            if field == "title" { sources = [row.title] }
            else if field == "detail" { sources = [row.detail] }
            else if field.hasPrefix("q"), let index = Int(field.dropFirst()), index > 0, index <= row.quotes.count {
                sources = [row.quotes[index - 1]]
            } else { return nil }
            if raw.isEmpty {
                let chosen = sources[0].trimmingCharacters(in: .whitespacesAndNewlines)
                return chosen.count >= 4 ? String(chosen.prefix(180)) : nil
            }
        } else { sources = [row.title, row.detail] + row.quotes }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 4 else { return nil }
        for candidate in [text] + unwrapped(text) {
            for source in sources {
                if source.contains(candidate) { return String(candidate.prefix(180)) }
                if let original = normalizedMatch(candidate, in: source) { return String(original.prefix(180)) }
            }
        }
        return nil
    }
    private static func unwrapped(_ text: String) -> [String] {
        let wrappers: [(Character, Character)] = [("“", "”"), ("\"", "\""), ("「", "」"), ("`", "`")]
        guard wrappers.contains(where: { text.first == $0.0 && text.last == $0.1 }) else { return [] }
        let inner = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        return inner.count >= 4 ? [inner] : []
    }
    private struct Unit {
        var value: Character
        var start: String.Index
        var end: String.Index
    }
    private static func han(_ value: Character) -> Bool {
        value.unicodeScalars.contains { (0x3400...0x9fff).contains($0.value) || (0xf900...0xfaff).contains($0.value) }
    }
    private static func normalized(_ text: String) -> [Unit] {
        var result: [Unit] = [], whitespace: Range<String.Index>?
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index), character = text[index]
            if character.isWhitespace {
                whitespace = (whitespace?.lowerBound ?? index)..<next
                index = next; continue
            }
            // Keep Latin word boundaries ("not able" must not become "notable"). Chinese layout
            // spacing may disappear, but decimal punctuation and every non-space character remain.
            if let gap = whitespace, let previous = result.last, !han(previous.value), !han(character) {
                result.append(Unit(value: " ", start: gap.lowerBound, end: gap.upperBound))
            }
            whitespace = nil
            for value in String(character).precomposedStringWithCanonicalMapping.folding(options: .widthInsensitive, locale: Locale(identifier: "en_US_POSIX")) {
                result.append(Unit(value: value, start: index, end: next))
            }
            index = next
        }
        return result
    }
    private static func normalizedMatch(_ quote: String, in source: String) -> String? {
        let wanted = String(normalized(quote).map(\.value))
        guard wanted.count >= 4 else { return nil }
        let units = normalized(source), value = String(units.map(\.value))
        guard let range = value.range(of: wanted) else { return nil }
        let first = value.distance(from: value.startIndex, to: range.lowerBound)
        let last = value.distance(from: value.startIndex, to: range.upperBound) - 1
        return String(source[units[first].start..<units[last].end])
    }
}

extension PeriodReviewFromDaily {
    /// A conclusion that failed a local check, kept only to tell the model what to fix.
    struct Rejection: Sendable {
        var title: String
        var section: String
        var ids: [String]
        var issue: ModelValidationIssue
    }
    struct EvidenceAssessment: Sendable {
        var draft: Draft
        var unresolvedIDs: Set<String>
        var rejectedItems: Int
        var firstIssue: ModelValidationIssue? = nil
        var rejections: [Rejection] = []
    }
    /// Preserve complete valid conclusions, and queue *whole* rejected conclusions for scoped
    /// model repair. Partial content is never published and local code never invents a narrative.
    func assessEvidence(_ original: Draft, prepared: Prepared, itemLimit: Int, detailLimit: Int,
                        template: ReviewTemplate?, complete: Bool) throws -> EvidenceAssessment {
        guard original.overview.count <= 160, original.items.count <= itemLimit else { throw ModelReviewError.validation(.structure) }
        let rows = Dictionary(uniqueKeysWithValues: prepared.rows.map { ($0.id, $0) })
        var cleaned = original, invalid: Set<String> = [], kept: [Draft.Item] = [], rejected = 0, changedOwnership = false
        var firstIssue: ModelValidationIssue?, rejections: [Rejection] = []
        for item in original.items {
            do {
                let single = try validate(Draft(overview: "", items: [item]), prepared: prepared, itemLimit: itemLimit,
                    detailLimit: detailLimit, template: template, complete: complete, checkCoverage: false)
                kept += single.items
                changedOwnership = changedOwnership || single.items[0].section != item.section
            } catch let error as ModelReviewError {
                guard case .validation(let issue) = error else { throw error }
                if firstIssue == nil { firstIssue = issue }
                rejected += 1
                var candidates: Set<String> = []
                for proof in item.evidence {
                    if let id = PeriodReviewEvidence.canonicalID(proof.id, rows: rows) { candidates.insert(id) }
                    else if !proof.quote.isEmpty {
                        // Candidate rows only narrow the repair request; they never silently reassign a citation.
                        for row in prepared.rows where PeriodReviewEvidence.quote(proof.quote, reference: nil, row: row) != nil { candidates.insert(row.id) }
                    }
                }
                // An unscoped or empty citation requires rechecking all input rows in bounded batches.
                invalid.formUnion(candidates.isEmpty ? Set(rows.keys) : candidates)
                rejections.append(Rejection(title: String(item.title.prefix(70)), section: item.section,
                                            ids: candidates.sorted(), issue: issue))
            }
        }
        cleaned.items = kept
        cleaned.coverage = original.coverage?.map { receipt in
            var value = receipt
            if let id = PeriodReviewEvidence.canonicalID(value.id, rows: rows), let row = rows[id] {
                value.id = id
                if value.disposition == "outOfScope", let quote = PeriodReviewEvidence.quote(value.quote ?? "", reference: value.quoteRef, row: row) {
                    value.quote = quote; value.quoteRef = nil
                }
            }
            return value
        }
        if changedOwnership { cleaned.overview = recordOverview(cleaned, prepared: prepared) }
        return EvidenceAssessment(draft: cleaned, unresolvedIDs: invalid, rejectedItems: rejected, firstIssue: firstIssue, rejections: rejections)
    }
}
