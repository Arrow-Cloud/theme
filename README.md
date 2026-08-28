# Arrow Cloud Theme

An ITGmania theme. This is a fork of a fork: [Simply Love](https://github.com/Simply-Love/Simply-Love-SM5) →
[Zmod](https://github.com/zarzob/Simply-Love-SM5) (Zarzob/Zankoku's quality-of-life fork of Simply Love) →
**Arrow Cloud** (this repo), which layers the [Arrow Cloud](https://arrowcloud.dance) online-score service on top
of Zmod.

Only for ITGmania. Use the `itgmania-release` branch.

## What Arrow Cloud adds

Arrow Cloud is this fork's own cloud leaderboard/login service (the product, at arrowcloud.dance; the API at
api.arrowcloud.dance). Everything below is specific to this fork and lives mainly in `Modules/ArrowCloud.lua`
(~3,400 lines) and `Scripts/SL-Helpers-ArrowCloud.lua`, hooked into the theme via the `Modules/` system described
in `Modules/README.md`.

### Login

Login is device-code style, done from Select Music rather than a dedicated login screen:

- A modal ("ACLoginModal") walks each joined player through checking their saved API key
  (`Save/[profile]/ArrowCloud.ini`) against `/auth-check`, or starting a fresh device-login flow
  (`/device-login/start` → poll `/device-login/poll`) that renders a QR code for the player to scan and approve
  on their phone.
- Retry/backoff is built in (`self.backoffs = {3, 5, 8}`) for players whose check fails or times out.
- A compact "✔ Arrow Cloud" / "❌ Arrow Cloud" connection indicator sits top-right on the Title Menu
  (`moduleRegistration["ScreenTitleMenu"]`), doing an unauthenticated hit against the API root so operators can
  tell at a glance whether the machine can reach the service. If the host isn't allowed
  (`HttpAllowHosts` in `Preferences.ini`), it surfaces that directly: `Add "*.arrowcloud.dance" to HttpAllowHosts`.

### Cloud leaderboards

- `BGAnimations/ScreenSelectMusic overlay/ACLeaderboard.lua` — a leaderboard overlay reachable from the Sort Menu
  (`ArrowCloud → ACLeaderboard`, alongside the existing GrooveStats entry), fetching
  `GET /v1/chart/{hash}/leaderboards`. Modeled after Simply Love's own `Leaderboard.lua` but talks to the Arrow
  Cloud API directly rather than through GrooveStats' request plumbing. Score entries are color-coded by type
  (white = ITG, blue = EX, pink = H.EX) with self/rival highlighting.
- The Select Music scorebox (`PerPlayer/Scorebox.lua`) fires an independent Arrow Cloud request
  (`willDoArrowCloud`) alongside — not instead of — the existing GrooveStats request, gated on a valid
  `ArrowCloudApiKey` and chart hash. The box appears as soon as *either* service responds (it doesn't wait for
  both), and rotates through whichever leaderboard types actually have data (GrooveStats ITG/EX, RPG/ITL event
  boards, Arrow Cloud ITG/EX/HardEX) in the order they genuinely became available — tracked via an
  append-only `styleOrder` list that response handlers only ever add to, never overwrite, so a slow GrooveStats
  response can't yank the display away from Arrow Cloud data that's already showing. GrooveStats is typically
  much slower to respond than Arrow Cloud; while it's still in flight the GrooveStats logo keeps its loading
  glow rather than settling as if it had come back empty.
- Linking a fresh Arrow Cloud account (via the QR/device-login flow) immediately refreshes the in-memory API
  key and re-checks the scorebox, so a newly-linked profile doesn't need a song reselect or profile reload
  before its leaderboard shows up.

### Score submission

Hooked into `ScreenEvaluationStage` (regular songs) and `ScreenEvaluationNonstop` (fixed, non-autogen,
non-endless courses only):

- `ArrowCloud.isEligible(player, opts)` runs the same category of sanity checks GrooveStats does before allowing
  a submission — game is `dance`, style isn't `solo`, not course mode (unless explicitly overridden for the
  Nonstop path), `GameMode == "ITG"`, `LifeDifficultyScale <= 1`, music rate between 0.10x–10.00x, no
  note-removal/note-addition mods active, fail type is Immediate/ImmediateContinue, human player (or an
  `allowAutoplay` testing override), and `MinTNSToScoreNotes` no more permissive than W3 — each check reported
  individually (`{ id, desc, pass }`) rather than as a single pass/fail.
- On success, `POST /v1/chart/{hash}/play` submits the score; per-player submission state renders inline on the
  Evaluation screen (`ACSubmitP1`/`ACSubmitP2` text, `ACErrorP1`/`ACErrorP2` for failures).
- The engine appears to only actually dispatch one HTTP request at a time, and GrooveStats' own submission
  request (`AutoSubmitScore.lua`) fires from `OnCommand` — earlier than Arrow Cloud's, which fires from the
  module system's `ModuleCommand`. Since GrooveStats can take 10+ seconds while Arrow Cloud is normally
  near-instant, `AutoSubmitScore.lua` deliberately defers its own request dispatch by half a second
  (`self:sleep(0.5):queuecommand("SendGrooveStatsRequest")`) so Arrow Cloud's request always gets to go first.
- **Offline queueing**: a failed submission is appended to a per-profile JSONL file (one JSON object per line,
  capped at 50 entries) and retried automatically next time a score is submitted successfully — entries are
  processed from the front of the file one at a time, since each successful removal shifts the remaining line
  indices. A small pending-count badge (`ACPendingP1`/`ACPendingP2`) shows how many scores are queued, with a
  "(FULL)" suffix at capacity.
- A dismissible dialog actor (`createACDialogActor`) is available for rendering backend-controlled messages on
  the Evaluation screen, using the same input-redirection/dismissal pattern as other Simply Love prompts.

### Hard EX Score

An Arrow Cloud-original scoring display (not from Zmod or mainline Simply Love): `PerPlayer/ScoreHardEx.lua`, plus
marquee behavior in the Evaluation screen's `JudgmentLabels.lua`/`JudgmentNumbers.lua` that alternates between the
normal ITG/EX score and a pink "H.EX" (Hard EX) score when both `ShowExScore` and `ShowHardEXScore` player options
are enabled.

### Operator/player-facing config

- `SL.ArrowCloud` (`Scripts/SL_Init.lua`) holds the live config — `Enabled`, `BaseURL`
  (`https://api.arrowcloud.dance`), `RequestTimeout`, and a local `LogPath` for response logging. It's explicitly
  preserved across `InitializeSimplyLove()` re-inits (see the comment in `SL_Init.lua`) — a bare `SL = {...}`
  reassignment there would silently drop it.
- `[ScreenArrowCloudOptions]` in `metrics.ini` exposes a `HideGrooveStats` operator/player preference (defined in
  `Scripts/99 SL-ThemePrefs.lua`) for players who want the GrooveStats UI out of the way in favor of Arrow Cloud.
- Dropping `Other/GrooveStats_UAT.txt` still redirects *GrooveStats* traffic to a local mock — that mechanism is
  inherited from upstream and doesn't affect Arrow Cloud's own requests, which always go to `SL.ArrowCloud.BaseURL`.

### API surface used by this theme

| Endpoint | Purpose |
|---|---|
| `GET /auth-check` | Validate a saved API key |
| `POST /device-login/start` | Begin a QR/device-code login |
| `POST /device-login/poll` | Poll for login approval |
| `GET /v1/chart/{hash}/leaderboards` | Fetch a chart's Arrow Cloud leaderboard |
| `POST /v1/chart/{hash}/play` | Submit a score |
| `GET /` | Unauthenticated health check (Title Menu connection indicator) |

`example-leaderboards-response.json` and `example-submission-response.json` (repo root) are captured example
payloads for the leaderboards and submission endpoints, useful when working on the parsing/rendering code without
hitting the live API.

## Inherited from Zmod / Simply Love

This fork carries forward Zmod's quality-of-life feature set on top of mainline Simply Love — event-specific
(ITL/SRPG) leaderboards and progress panes, GrooveStats-integrated Scorebox and Step Statistics, Hard/held-miss
judgment support, per-foot/per-arrow scatterplots, configurable theme fonts, BoogieStats integration, ghost data,
ITGmania's Online Lobbies (multiplayer), Routine/Couples mode, NoteSkin Variants, and more. See
`Modules/README.md` for how third-party/isolated screen hooks like Arrow Cloud's plug in without editing core
theme files, and `CLAUDE.md` for repository layout and the local dev/test workflow.

# Credits

Zmod (the base this fork builds on) is worked on by Zarzob and Zankoku. Contact them on Discord at `zarzob` or
`zankoku`, or via [Zarzob's Discord server](https://discord.gg/zarzob).

## Additional Contributors

  * sorae
  * MegaSphere
  * @florczakraf
  * @HURG-IIDX
