import Foundation

/// Wire format for the gateway's optional lighter model.
///
/// The gateway (`gateway/app.py`) maps the `makima-fast` request id onto the
/// `MAKIMA_FAST_MODEL` environment variable. That variable is empty by default,
/// so with no lighter model pulled the gateway answers HTTP 400 — the toggle in
/// Settings is therefore off by default.
enum FastModel {
    /// The id the iOS client sends. Must match `FAST_MODEL_ID` in gateway/app.py.
    static let requestId = "makima-fast"
}

enum SuperModel {
    static let requestId = "makima-super"
}

/// Response modes offered by the input-bar picker.
enum FastModelChoice: Hashable {
    /// The main model (`MAKIMA_MODEL`). Default.
    case standard
    /// The text-only model (`MAKIMA_FAST_MODEL`), Qwen2.5 7B Q4_K_M.
    case lightweight
    case superMode
}
