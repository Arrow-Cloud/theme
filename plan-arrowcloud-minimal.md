# Minimal ArrowCloud Integration Plan (Logging Only)

## Scope
Add a minimal ArrowCloud API call that fetches `/v1/charts/{hash}/leaderboards` when the existing leaderboard overlay is shown and append the raw response (or error metadata) to a newline-delimited JSON (ndjson) log file. No UI changes, no prioritization logic, no multi-board handling, no caching, and no parsing beyond simple metadata wrapping.

## Non-Goals
- Do NOT alter existing GrooveStats rendering or flow.
- Do NOT introduce selection/priority between services.
- Do NOT display ArrowCloud data in-game.
- Do NOT implement events, caching, normalization, or multi-board UI.

## Current GrooveStats Flow (Relevant Extract)
1. `LeaderboardMaster` ActorFrame becomes visible (via `ShowLeaderboardCommand`).
2. Each player context is initialized; `SendLeaderboardRequestCommand` queued.
3. In `SendLeaderboardRequestCommand` (in `Leaderboard.lua`):
   - Validate service eligibility via `IsServiceAllowed`.
   - Build query & headers (API keys, chart hashes) for `player-leaderboards.php`.
   - Fire request via `RequestResponseActor` (spinner, timeout, cancellation safe).
4. Callback `LeaderboardRequestProcessor` parses JSON and constructs multiple leaderboard panes (GrooveStats, EX, events, local fallback).
5. Local fallback if request invalid or not eligible.

We piggyback a **parallel** ArrowCloud request here without touching existing logic.

## Data Needed For ArrowCloud Request
- A single chart hash (prefer P1, else P2). Source: `SL.P1.Streams.Hash` / `SL.P2.Streams.Hash`.
- Base URL (temporary constant): `https://b4mdyahpki.execute-api.us-east-2.amazonaws.com/prod/` (can be swapped later by editing helper config).
- Endpoint path: `charts/{hash}/leaderboards`.
- Optional future: Auth (not in this phase). For now assume public or pre-authorized content.

## File Additions
- `Scripts/SL-Helpers-ArrowCloud.lua` (new): Holds config + `ArrowCloudRequest(chartHash)` function.
- (Optional) This plan file: `plan-arrowcloud-minimal.md` (created).

## Minimal Helper Structure
```lua
SL = SL or {}
SL.ArrowCloud = SL.ArrowCloud or {
  Enabled = true,
  BaseURL = "https://b4mdyahpki.execute-api.us-east-2.amazonaws.com/prod/",
  RequestTimeout = 5,
  LogPath = THEME:GetCurrentThemeDirectory() .. "Other/ArrowCloud_Responses.ndjson" -- one JSON object per line
}

function ArrowCloudRequest(chartHash)
  if not SL.ArrowCloud.Enabled or not chartHash or #chartHash == 0 then return end
  NETWORK:HttpRequest{
    url = SL.ArrowCloud.BaseURL .. "charts/" .. chartHash .. "/leaderboards",
    method = "GET",
    connectTimeout = SL.ArrowCloud.RequestTimeout,
    transferTimeout = SL.ArrowCloud.RequestTimeout,
    onResponse = function(res)
      local out = {
        timestamp = os.time(),
        chartHash = chartHash,
        statusCode = res.statusCode,
        error = res.error and ToEnumShortString(res.error) or nil,
        body = res.body, -- raw; keep even on non-200 for debugging
      }
      local f = RageFileUtil:CreateRageFile()
      if f:Open(SL.ArrowCloud.LogPath, 2) then
        -- APPEND behavior (simple read/concat approach can be optimized later)
        local existing = nil
        f:Close() -- ensure we reopen correctly; replaced by helper in actual implementation
      end
      f:destroy()
    end
  }
end
```

## Integration Point (Single Code Touch)
Inside `SendLeaderboardRequestCommand` of `Leaderboard.lua` (after existing local fallback insertion but before or after sending GrooveStats request):
```lua
local hash = ""
if SL.P1 and SL.P1.Streams and SL.P1.Streams.Hash ~= "" then
  hash = SL.P1.Streams.Hash
elseif SL.P2 and SL.P2.Streams and SL.P2.Streams.Hash ~= "" then
  hash = SL.P2.Streams.Hash
end
if SL.ArrowCloud and SL.ArrowCloud.Enabled and hash ~= "" then
  ArrowCloudRequest(hash)
end
```
No dependency on GrooveStats success/failure.

## Logging Format
`Other/ArrowCloud_Responses.ndjson` (appended, one JSON object per line; example single line pretty-printed here for clarity):
```json
{
  "timestamp": 1734499999,
  "chartHash": "<hash>",
  "statusCode": 200,
  "error": null,
  "body": "{...raw ArrowCloud JSON...}"
}
```

## Error Handling
| Condition | Result |
|-----------|--------|
| Host blocked / not in HttpAllowHosts | `error` set (engine-provided), file written |
| Timeout | `error="Timeout"` (or engine short string), no crash |
| Non-200 | `statusCode` recorded, raw body retained |
| Empty hash | No request made |
| Append failure (file write) | Silently ignored |

## Edge Considerations
- Both players differ: first non-empty selected (future: verify identical; out of scope now).
- Rapid reopens overwrite prior log (intentional minimal behavior).
- Multi-thread / concurrent: StepMania typically serializes; worst-case last completion wins.

## Manual Test Procedure
1. Ensure `api.arrowcloud.com` is present in `Preferences.ini` `HttpAllowHosts` line.
2. Start game, join at least one player, navigate to song select.
3. Open leaderboard overlay (whatever triggers `ShowLeaderboardCommand`).
4. Inspect `Themes/<ThemeName>/Other/ArrowCloud_LastResponse.json`.
5. Disconnect network and retry to confirm error logging.

## Future (Deferred) Enhancements (Not Implemented Now)
- Append log rotation (timestamped files).
- Simple in-memory throttle (avoid repeat within same song selection span).
- Basic JSON parse & validation.
- UI integration & multi-board model.

## Implementation Steps (Execution Order)
1. Add helper file with config + request.
2. Require/load helper early (e.g., in `SL_Init.lua`).
3. Inject snippet into `SendLeaderboardRequestCommand`.
4. Verify log file creation and appended lines (subsequent openings add new line).

## Acceptance Criteria
- GrooveStats behavior unchanged.
- No Lua runtime errors on screen load (check logs).
- File is created/appended with each overlay activation (when valid hash exists).
- Error or success both appear in JSON file as described.

-- End of minimal plan.


# Utility notes

```bash
# WSL command (run from anywhere)
rsync -av --delete /home/sam/projects/arrow-cloud/theme/ "/mnt/c/Games/ITGmania/Themes/Arrow Cloud Alpha/"
```