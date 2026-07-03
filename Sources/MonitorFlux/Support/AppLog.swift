import Foundation
import os

/// Structured logging for the paths that change what's on screen, so a bug report captured
/// with a **sysdiagnose** — or the dev `build_and_run.sh --telemetry` / `--logs` stream — can
/// answer "why did my screen change at 3pm" without a debugger.
///
/// **Level policy** (chosen so drags can't flood a bug report):
/// - `.notice` — meaningful, low-frequency, *automatic* state a report needs: the clock
///   advancing warmth, a scheduled brightness/contrast write, a gamma conflict, the media-key
///   tap's lifecycle, a wake re-apply. `.notice` persists to the on-disk store (so it survives
///   into a sysdiagnose) and `--telemetry` (`log stream --info`) shows it live.
/// - `.error` — failures (a gamma or DDC write that didn't take).
/// - `.debug` — high-frequency or user-driven detail (each successful DDC write during a drag,
///   a user editing a schedule slider). Not persisted; visible only with `log stream --debug`,
///   so an active drag never bloats the report.
///
/// Display names are logged `.public`: this is an on-device personal app, and a redacted
/// `<private>` name would defeat the whole "which monitor" question these logs exist to answer.
enum AppLog {
    /// Must match the `subsystem ==` predicate in `script/build_and_run.sh` (`--telemetry`).
    private static let subsystem = "app.monitorflux.MonitorFlux"

    static let gamma = Logger(subsystem: subsystem, category: "gamma")
    static let ddc = Logger(subsystem: subsystem, category: "ddc")
    static let schedule = Logger(subsystem: subsystem, category: "schedule")
    static let keyboard = Logger(subsystem: subsystem, category: "keyboard")
}
