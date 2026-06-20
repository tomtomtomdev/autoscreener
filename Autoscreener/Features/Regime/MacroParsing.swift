import Foundation

/// Pure, network-free parsing for the macro inputs the app now sources on-device — the
/// BI policy rate (bi.go.id HTML, FRED CSV fallback) and the FRED global anchors
/// (US fed funds / 10y / broad dollar). This is the Swift port of the
/// `tools/idx-regime-scraper` pure logic (`bi_rate.py` + `macro.py`): the same date
/// shapes, the same Bahasa decimal-comma / month handling, the same chronological
/// sort, direction and trend rules — kept isolated from I/O so it's fully unit-testable
/// against saved fixtures, exactly like its Python counterpart.
nonisolated enum MacroParsing {
    /// A parsed observation: the original date string (carried through sorting, which
    /// parses it for ordering) plus the numeric value. `toBIRate`/`toMacroSeries`
    /// normalise the date to ISO.
    typealias Observation = (raw: String, value: Double)

    // MARK: - Dates

    private static let monthByName: [String: Int] = [
        // English
        "january": 1, "february": 2, "march": 3, "april": 4, "may": 5, "june": 6,
        "july": 7, "august": 8, "september": 9, "october": 10, "november": 11, "december": 12,
        // Indonesian (bi.go.id renders dates in Bahasa)
        "januari": 1, "februari": 2, "maret": 3, "mei": 5, "juni": 6, "juli": 7,
        "agustus": 8, "oktober": 10, "desember": 12,
        // short forms
        "jan": 1, "feb": 2, "mar": 3, "apr": 4, "jun": 6, "jul": 7, "aug": 8, "agu": 8,
        "sep": 9, "oct": 10, "okt": 10, "nov": 11, "dec": 12, "des": 12,
    ]

    /// UTC Gregorian calendar — dates here are calendar days, never wall-clock instants,
    /// so a fixed zone keeps `parseDate` ↔ `isoString` round-tripping deterministically.
    private static let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    /// Parse the handful of date shapes BI / FRED emit: ISO `2026-01-15`,
    /// `DD Month YYYY` (English or Bahasa), and `DD/MM/YYYY`. `nil` if no match.
    static func parseDate(_ text: String) -> Date? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let m = firstMatch(#"(\d{4})-(\d{1,2})-(\d{1,2})"#, in: s) {
            return makeDate(year: m[1], month: m[2], day: m[3])
        }
        if let m = firstMatch(#"(\d{1,2})\s+([A-Za-z]+)\.?\s+(\d{4})"#, in: s),
           let month = monthByName[m[2].lowercased()] {
            return makeDate(yearInt: Int(m[3]), monthInt: month, dayInt: Int(m[1]))
        }
        if let m = firstMatch(#"(\d{1,2})[/-](\d{1,2})[/-](\d{4})"#, in: s) {
            return makeDate(year: m[3], month: m[2], day: m[1])
        }
        return nil
    }

    /// ISO `yyyy-MM-dd` for a date produced by `parseDate`.
    static func isoString(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private static func makeDate(year: String, month: String, day: String) -> Date? {
        makeDate(yearInt: Int(year), monthInt: Int(month), dayInt: Int(day))
    }

    private static func makeDate(yearInt: Int?, monthInt: Int?, dayInt: Int?) -> Date? {
        guard let y = yearInt, let mo = monthInt, let d = dayInt else { return nil }
        var comps = DateComponents()
        comps.year = y; comps.month = mo; comps.day = d
        // Reject impossible dates (e.g. month 13) the way Python's `date()` raises.
        guard comps.isValidDate(in: calendar) else { return nil }
        return calendar.date(from: comps)
    }

    // MARK: - Values

    /// Parse a percentage cell: `4.75`, `4,75`, `4.75%`, `5,75 %`. Handles the Bahasa
    /// decimal comma. `nil` if it doesn't look like a *policy* rate (bounded 0…50 so a
    /// stray numeric cell — a row number, a dollar index — can't be read as the rate).
    static func parseRate(_ text: String) -> Double? {
        guard let value = normalisedNumber(text) else { return nil }
        return (0.0 < value && value < 50.0) ? value : nil
    }

    /// A FRED numeric cell, magnitude-agnostic: `"."` (FRED's missing marker), blanks,
    /// `"-"` and `N/A` → `nil`. No plausibility bound, so a 10y yield of `4.30` and a
    /// dollar index of `121.5` both parse (contrast `parseRate`).
    static func parseFREDValue(_ text: String) -> Double? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if ["", ".", "-", "N/A", "n/a"].contains(s) { return nil }
        return Double(s.replacingOccurrences(of: ",", with: ""))
    }

    /// Shared numeric normalisation for `parseRate`: strip `%`, fold the Bahasa decimal
    /// comma, drop thousands separators, and validate the shape before converting.
    private static func normalisedNumber(_ text: String) -> Double? {
        var s = text.replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        // Decimal comma (no dot present) → dot; otherwise commas are thousands separators.
        if s.contains(",") && !s.contains(".") {
            s = s.replacingOccurrences(of: ",", with: ".")
        } else {
            s = s.replacingOccurrences(of: ",", with: "")
        }
        guard firstMatch(#"^-?\d+(\.\d+)?$"#, in: s) != nil else { return nil }
        return Double(s)
    }

    // MARK: - Series shaping

    /// Chronological ascending, dropping rows whose date can't be parsed — so the result
    /// is correct whether the source table was oldest- or newest-first.
    static func sortObservations(_ observations: [Observation]) -> [Observation] {
        observations
            .compactMap { obs -> (Date, Observation)? in
                guard let d = parseDate(obs.raw) else { return nil }
                return (d, obs)
            }
            .sorted { $0.0 < $1.0 }
            .map { $0.1 }
    }

    /// Last policy move from a chronological series: equal latest two = held.
    static func direction(_ observations: [Observation]) -> BIRateDirection {
        guard observations.count >= 2 else { return .hold }
        let prev = observations[observations.count - 2].value
        let last = observations[observations.count - 1].value
        if last > prev { return .hike }
        if last < prev { return .cut }
        return .hold
    }

    /// Direction of a chronological series over a `lookback` window: compares the latest
    /// observation to the one `lookback` steps back (clamped to the oldest available), so
    /// a daily series reads as a ~1-trading-month trend rather than flapping on one-day
    /// noise. `.flat` when too short or unchanged.
    static func trend(_ observations: [Observation], lookback: Int = 20) -> MacroTrend {
        guard observations.count >= 2 else { return .flat }
        let steps = min(lookback, observations.count - 1)
        let last = observations[observations.count - 1].value
        let ref = observations[observations.count - 1 - steps].value
        if last > ref { return .up }
        if last < ref { return .down }
        return .flat
    }

    // MARK: - CSV

    /// FRED `fredgraph.csv?id=…` with the bounded policy-rate value parser — the BI-rate
    /// fallback path (`IRSTCB01IDM156N`). `date,value` rows, `"."` = missing.
    static func parseFREDCSV(_ text: String) -> [Observation] {
        parseCSV(text, value: parseRate)
    }

    /// FRED `fredgraph.csv?id=…` with the magnitude-agnostic value parser — the macro
    /// series path (`DFF`/`DGS10`/`DTWEXBGS`).
    static func parseFREDSeries(_ text: String) -> [Observation] {
        parseCSV(text, value: parseFREDValue)
    }

    private static func parseCSV(_ text: String, value: (String) -> Double?) -> [Observation] {
        var out: [Observation] = []
        let lines = text.split(whereSeparator: \.isNewline)
        for line in lines.dropFirst() {  // skip header
            let cols = line.split(separator: ",", omittingEmptySubsequences: false)
            guard cols.count >= 2, let v = value(String(cols[1])) else { continue }
            out.append((raw: String(cols[0]).trimmingCharacters(in: .whitespaces), value: v))
        }
        return out
    }

    // MARK: - JSON (FRED API)

    /// FRED `series/observations?…&file_type=json` — the keyed API path. Decodes the
    /// `observations` array into the same `Observation` shape the CSV path yields, so the
    /// sort/trend logic and builders (`toMacroSeries`) are shared. Each `value` is a
    /// *string* (`"."` = missing, dropped by `parseFREDValue`). Returns `[]` on any decode
    /// failure — including FRED's `{ "error_code", "error_message" }` body for a bad/absent
    /// key — so a bad response degrades one series rather than throwing.
    static func parseFREDJSON(_ text: String) -> [Observation] {
        guard let data = text.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(FREDObservationsResponse.self, from: data)
        else { return [] }
        return decoded.observations.compactMap { row in
            guard let value = parseFREDValue(row.value) else { return nil }
            return (raw: row.date, value: value)
        }
    }

    /// The slice of the `series/observations` JSON payload we read — `date` + the string
    /// `value`. Other top-level fields (`count`, `realtime_*`, units, …) are ignored.
    private struct FREDObservationsResponse: Decodable {
        struct Row: Decodable { let date: String; let value: String }
        let observations: [Row]
    }

    // MARK: - worldgovernmentbonds.com country API (sovereign-risk leg)

    /// Parse the `wp-json/country/v1/main` payload into the Indonesia sovereign reading. The two
    /// levels come straight off the (string-typed) top-level fields — `bond10y` (10y govt yield)
    /// and `lastCds` (5y sovereign CDS); the 1-month CDS change is read from the CDS table HTML,
    /// where the columns are `Var % 1W`, `Var % 1M`, `Var % 1Y`, `Implied PD` — so the signed
    /// percent tokens after the row label are `[1W, 1M, 1Y, PD]` and the vote uses the 2nd (1M).
    /// `nil` when the body isn't the expected JSON or any of the three figures is missing — the
    /// factor then drops, like any absent leg (FRED's `error_*` JSON also parses to `nil` here).
    static func parseWorldGovBonds(_ json: String) -> IndonesiaSovereignReading? {
        guard let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(WGBPayload.self, from: data),
              let bond10y = normalisedNumber(payload.bond10y),
              let cds = normalisedNumber(payload.lastCds),
              let change1M = cdsMonthlyChange(payload.cdsTableHtml)
        else { return nil }
        return IndonesiaSovereignReading(
            bond10yPercent: bond10y, cds5y: cds, cdsChange1MPercent: change1M)
    }

    /// The slice of the country payload we read. The figures arrive as *strings* ("7.070"); the
    /// CDS change lives only inside the rendered table HTML, parsed out separately.
    private struct WGBPayload: Decodable {
        let bond10y: String
        let lastCds: String
        let cdsTableHtml: String
    }

    /// The 1-month CDS change (percent) from the CDS table markup. Strips the tags, then takes the
    /// ordered signed-percent tokens (`-7.26 %`, `-7.39 %`, `+4.87 %`, `1.44 %` = 1W/1M/1Y/PD) and
    /// returns the 2nd — the 1-month move the factor votes on. `nil` if fewer than two are present.
    /// Parses with `Double` directly (not `normalisedNumber`, whose anchor rejects a leading `+`) so
    /// a *widening* (positively-signed) move — the risk-off case — isn't silently dropped, which
    /// would shift the column positions and misread the vote.
    private static func cdsMonthlyChange(_ html: String) -> Double? {
        let percents = matches(#"([+-]?\d+(?:\.\d+)?)\s*%"#, in: stripTags(html))
            .compactMap { Double($0) }
        guard percents.count >= 2 else { return nil }
        return percents[1]
    }

    // MARK: - BI-rate HTML

    /// Scrape the BI-Rate history table (bi.go.id — server-rendered HTML, no Cloudflare).
    /// Heuristic and resilient to the exact markup (no DOM parser): scan every table row,
    /// keep the (date, rate) pair when one cell parses as a date and another as a rate.
    /// The BI-Rate column carries a `%`, so prefer a `%`-bearing cell — that stops the
    /// leading "No" index column (a bare integer that also parses as a plausible rate)
    /// being read as the rate. Falls back to any rate-like cell if the page drops `%`.
    static func parseBIRateHTML(_ html: String) -> [Observation] {
        var out: [Observation] = []
        for row in matches(#"<tr[^>]*>(.*?)</tr>"#, in: html, dotAll: true) {
            let cells = matches(#"<t[dh][^>]*>(.*?)</t[dh]>"#, in: row, dotAll: true)
                .map { stripTags($0) }
            guard let dateCell = cells.first(where: { parseDate($0) != nil }) else { continue }
            let rate = cells.first(where: { $0.contains("%") && parseRate($0) != nil }).flatMap(parseRate)
                ?? cells.lazy.compactMap(parseRate).first
            guard let rate else { continue }
            out.append((raw: dateCell, value: rate))
        }
        return out
    }

    private static func stripTags(_ s: String) -> String {
        let noTags = s.replacingOccurrences(
            of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        return noTags
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Builders

    /// Build the `BIRate` from a (possibly unsorted) observation list: sort, take the
    /// latest as the level, derive the direction; `asOf` normalised to ISO.
    static func toBIRate(_ observations: [Observation]) -> RegimeSnapshot.BIRate? {
        let series = sortObservations(observations)
        guard let latest = series.last else { return nil }
        let asOf = parseDate(latest.raw).map(isoString) ?? latest.raw
        return RegimeSnapshot.BIRate(value: latest.value, direction: direction(series), asOf: asOf)
    }

    /// Build the `MacroSeries` from a (possibly unsorted) observation list: sort, take
    /// the latest as the level, derive the trend; `asOf` normalised to ISO.
    static func toMacroSeries(_ observations: [Observation]) -> RegimeSnapshot.MacroSeries? {
        let series = sortObservations(observations)
        guard let latest = series.last else { return nil }
        let asOf = parseDate(latest.raw).map(isoString) ?? latest.raw
        return RegimeSnapshot.MacroSeries(value: latest.value, trend: trend(series), asOf: asOf)
    }

    // MARK: - Regex helpers

    /// Capture groups of the first match: `[full, $1, $2, …]`, or `nil` if no match.
    private static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, range: range) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            guard let r = Range(m.range(at: i), in: text) else { return "" }
            return String(text[r])
        }
    }

    /// First capture group of every match — used for the row/cell scan.
    private static func matches(_ pattern: String, in text: String, dotAll: Bool = false) -> [String] {
        var options: NSRegularExpression.Options = [.caseInsensitive]
        if dotAll { options.insert(.dotMatchesLineSeparators) }
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return re.matches(in: text, range: range).compactMap { m in
            guard m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) else { return nil }
            return String(text[r])
        }
    }
}
