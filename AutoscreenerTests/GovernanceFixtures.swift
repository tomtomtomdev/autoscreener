import Foundation

/// Trimmed, faithful copies of the Phase 0 governance captures
/// (`tools/governance-captures/TPIA`, fetched via `scripts/capture-governance.sh`).
/// Structure / keys / value types mirror the live payloads exactly; individual people's
/// names are anonymised (corporate holder names are public disclosure and kept for realism).
enum GovernanceFixtures {
    /// `data.movement[]` — a selling director (insider, signed negative change) and a
    /// non-insider foreign fund (no role badge).
    static let majorHolder = Data(majorHolderJSON.utf8)
    static let majorHolderJSON = #"""
    {"message":"Successfully majorholder data","data":{"is_more":false,"movement":[
      {"id":"15283","name":"DIRECTOR A","symbol":"TPIA","date":"03 Jun 26",
       "badges":["SHAREHOLDER_BADGE_DIREKTUR"],"action_type":"ACTION_TYPE_SELL",
       "nationality":"NATIONALITY_TYPE_LOCAL",
       "current":{"value":"100","percentage":"2.00","formatted_value":""},
       "changes":{"value":"-50","percentage":"-1.50","formatted_value":""}},
      {"id":"77","name":"GLOBAL FUND LTD","symbol":"TPIA","date":"03 Jun 26",
       "badges":[],"action_type":"ACTION_TYPE_BUY","nationality":"NATIONALITY_TYPE_FOREIGN",
       "current":{"value":"100","percentage":"8.00","formatted_value":""},
       "changes":{"value":"+10","percentage":"+0.30","formatted_value":""}}
    ]}}
    """#

    /// `data.periods[0].compositions[]` — named ≥5% holders plus a sub-5% bucket.
    static let composition = Data(compositionJSON.utf8)
    static let compositionJSON = #"""
    {"message":"Successfully fetched composition","data":{"periods":[
      {"report_date":"2026-05-29","total_shares":{"raw":"1","formatted":"1"},"compositions":[
        {"label":"SCG CHEMICALS PUBLIC COMPANY","shares":{"raw":"1","formatted":"x"},"percentage":{"raw":30.57,"formatted":"30.57%"}},
        {"label":"BARITO PACIFIC","percentage":{"raw":20.96,"formatted":"20.96%"}},
        {"label":"Individual","percentage":{"raw":5.6,"formatted":"5.60%"}},
        {"label":"Other","percentage":{"raw":2.0,"formatted":"2.00%"}}
      ]}],"first_available_date":"2026-03-31","last_available_date":"2026-05-29"}}
    """#

    /// `data[]` — one of each action_type seen, dates nested under `action_info.<type>`.
    static let corpAction = Data(corpActionJSON.utf8)
    static let corpActionJSON = #"""
    {"message":"Successfully retrieved corporate action","data":[
      {"action_type":"rightissue","action_info":{"rightissue":{"rightissue_cumdate":"2021-08-30","rightissue_exdate":"2021-08-31","rightissue_recdate":"2021-09-01"}}},
      {"action_type":"dividend","action_info":{"dividend":{"dividend_cumdate":"2026-05-25","dividend_exdate":"2026-05-26"}}},
      {"action_type":"stocksplit","action_info":{"stocksplit":{"stocksplit_exdate":"2022-08-23"}}},
      {"action_type":"rups","action_info":{"rups":{}}}
    ]}
    """#

    /// `data.subsidiaries[]` — percentage is a display string.
    static let subsidiary = Data(subsidiaryJSON.utf8)
    static let subsidiaryJSON = #"""
    {"message":"Successfully retrieved subsidiary data","data":{"subsidiaries":[
      {"company_name":"Aster Chemicals and Energy Pte. Ltd.","business_type":"Petrochem","location":"Singapura","percentage":"100.00"},
      {"company_name":"Another Subsidiary Tbk.","percentage":"75.50"}
    ],"currency":"CURRENCY_UNSPECIFIED","unit":"UNIT_THOUSAND"}}
    """#

    /// `data.insider_name` + `data.ownership[]` — the queried symbol (TPIA) plus one genuine
    /// cross-holding in another listed entity.
    static let ownership = Data(ownershipJSON.utf8)
    static let ownershipJSON = #"""
    {"message":"Successfully retrieved ownership","data":{
      "insider_name":"DIRECTOR A","nationality":"NATIONALITY_TYPE_LOCAL","ownership":[
        {"symbol":"TPIA","company_name":"Chandra Asri Pacific Tbk.","is_more":false,
         "recent":[{"current":{"percentage":"0.01"}}]},
        {"symbol":"BRPT","company_name":"Barito Pacific Tbk.","is_more":false,
         "recent":[{"current":{"percentage":"3.50"}}]}
      ]}}
    """#
}
