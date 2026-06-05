import Foundation

/// The LQ45 constituent list used for the breadth signal (`idx-investing-research.md` §3,
/// % of LQ45 above their 200-day average).
///
/// IDX reviews LQ45 membership twice a year (effective February and August), so this
/// is a **maintained config**, not derived data — the regime docs
/// (`idx-regime-data-research.md` §5, §7) call for exactly this: a small committed
/// constituents list refreshed at each rebalance, because membership is in neither the
/// ratio feed nor the indices-highlight payload.
///
/// > ⚠️ Seed list as of the 2026 review known at authoring time. Verify and update at
/// > the next Feb/Aug rebalance. Breadth degrades gracefully if a symbol has rotated
/// > out — it simply fails to load and is excluded from the measured denominator
/// > (`BreadthReading.measured`), so a stale entry skews the read only slightly.
nonisolated enum LQ45Constituents {
    static let symbols: [String] = [
        // Banks & financials
        "BBCA", "BBRI", "BMRI", "BBNI", "BRIS", "BBTN", "ARTO",
        // Telco & towers
        "TLKM", "ISAT", "EXCL", "TOWR", "TBIG", "MTEL",
        // Consumer staples & cyclicals
        "UNVR", "ICBP", "INDF", "MYOR", "AMRT", "GGRM", "HMSP", "CPIN", "JPFA",
        // Energy & coal
        "ADRO", "PTBA", "ITMG", "MEDC", "PGAS", "AKRA", "PGEO",
        // Metals & basic materials
        "ANTM", "INCO", "MDKA", "TPIA", "BRPT", "INKP", "SMGR", "INTP",
        // Autos, heavy equipment, healthcare
        "ASII", "UNTR", "KLBF",
        // Property & infrastructure
        "CTRA", "BSDE", "JSMR",
        // Tech / new economy
        "GOTO", "ACES",
    ]
}
