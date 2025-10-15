--[[
ArrowCloud Module for SimplyLove
Inspired and adapted from Kuro's discord leaderboard scraper: https://github.com/pogof/SimplyLove-DiscordLeaderboard
]]

-- Module configuration
local ArrowCloud = {}

-- Constants
local BASE_URL = "https://api.arrowcloud.dance"
local MODULE_TAG = "[ArrowCloud-SLmodule]"

-- luacheck: globals GAMESTATE PREFSMAN THEME SL PLAYER_1 PLAYER_2 STATSMAN CRYPTMAN PROFILEMAN IniFile NETWORK IsHumanPlayer FormatPercentScore CalculateExScore GetTimingWindow GetWorstJudgment BinaryToHex clamp Trace ToEnumShortString ivalues MESSAGEMAN

-- forward declaration so isEligible can reference it
local debugPrint

-- Guarded stub declarations (only for tooling; real objects provided by engine at runtime)
if not GAMESTATE then GAMESTATE = {} end
if not PREFSMAN then PREFSMAN = { GetPreference = function(...) return 0 end } end
if not THEME then THEME = { GetMetric = function(...) return 0 end } end
if not SL then SL = { Global = { GameMode = "ITG", ActiveModifiers = { MusicRate = 1 }, Stages = { PlayedThisGame = 0 } }, P1 = { ActiveModifiers = { TimingWindows = { true, true, true, true, true } } }, P2 = { ActiveModifiers = { TimingWindows = { true, true, true, true, true } } } } end
if not PLAYER_1 then PLAYER_1 = 0 end
if not PLAYER_2 then PLAYER_2 = 1 end
if not STATSMAN then
  STATSMAN = {
    GetCurStageStats = function(...)
      return {
        GetPlayerStageStats = function(...)
          return {
            GetPercentDancePoints = function(...) return 0 end,
            GetGrade = function(...)
              return
              "Grade_Tier01"
            end,
            GetLifeRecord = function(...) return {} end,
            GetRadarActual = function(...) return { GetValue = function(...) return 0 end } end,
            GetRadarPossible = function(...) return { GetValue = function(...) return 0 end } end
          }
        end
      }
    end
  }
end
if not CRYPTMAN then CRYPTMAN = { SHA1File = function(...) return "" end } end
if not PROFILEMAN then PROFILEMAN = { GetProfileDir = function(...) return "" end } end
if not IniFile then IniFile = { WriteFile = function(...) end, ReadFile = function(...) return {} end } end
if not NETWORK then NETWORK = { HttpRequest = function(...) return {} end } end
if not IsHumanPlayer then IsHumanPlayer = function(...) return true end end
if not FormatPercentScore then FormatPercentScore = function(...) return "0%" end end
if not CalculateExScore then CalculateExScore = function(...) return 0 end end
if not GetTimingWindow then GetTimingWindow = function(...) return 0 end end
if not GetWorstJudgment then GetWorstJudgment = function(...) return 0 end end
if not BinaryToHex then BinaryToHex = function(...) return "" end end
if not clamp then clamp = function(v, min, max) if v < min then return min elseif v > max then return max else return v end end end
if not Trace then Trace = function(...) end end
if not ToEnumShortString then
  ToEnumShortString = function(v, ...)
    if v == PLAYER_1 then
      return "P1"
    elseif v == PLAYER_2 then
      return
      "P2"
    else
      return tostring(v)
    end
  end
end
if not ivalues then
  ivalues = function(t, ...)
    local i = 0
    return function()
      i = i + 1
      if t[i] ~= nil then return t[i] end
    end
  end
end
if not FILEMAN then FILEMAN = { DoesFileExist = function(...) return false end } end
if not MESSAGEMAN then MESSAGEMAN = { Broadcast = function(...) end } end
-- Screen dimensions (tooling stub only)
if not _screen then _screen = { w = 640, h = 480, cx = 320, cy = 240 } end
-- LoadFont (tooling stub only)
if not LoadFont then LoadFont = function(...) return Def.Actor end end

-- -------------------------------------------------------------------------------------------------
-- Eligibility checks (refactored from ValidForGrooveStats in SL-Helpers-GrooveStats.lua)
-- We only submit scores when a collection of sanity conditions are satisfied.  These are
-- intended to prevent accidental submission of obviously invalid scores – not to be
-- tamper‑proof.  This version is self‑contained for ArrowCloud usage and returns a rich result
-- for future UI/telemetry use.
--
-- ArrowCloud.isEligible(player, opts?) -> {
--    ok = boolean,
--    checks = { { id=string, pass=boolean, desc=string } ... },
--    failures = { <id>, ... }
-- }
-- opts.ignoreCourse (boolean)  : if true, we will not invalidate due to course mode.
-- opts.logger (function(msg))  : optional logger (defaults to debugPrint)
-- -------------------------------------------------------------------------------------------------

function ArrowCloud.isEligible(player, opts)
  opts = opts or {}
  local log = opts.logger or debugPrint
  local pn = ToEnumShortString(player)

  local results = { ok = true, checks = {}, failures = {} }

  local function addCheck(id, desc, pass)
    table.insert(results.checks, { id = id, desc = desc, pass = pass })
    if not pass then
      results.ok = false
      table.insert(results.failures, id)
    end
  end

  -- 1. Game must be dance
  addCheck("game", "Game type must be 'dance'", GAMESTATE:GetCurrentGame():GetName() == "dance")

  -- 2. Style not solo (GrooveStats / ArrowCloud currently single/versus/double only)
  local styleName = GAMESTATE:GetCurrentStyle():GetName()
  addCheck("style", "Style must not be 'solo'", styleName ~= "solo")

  -- 3. Not course mode (can be optionally ignored by caller – e.g. for Nonstop handler)
  if not opts.ignoreCourse then
    addCheck("course", "Not a course/nonstop/endless chart", not GAMESTATE:IsCourseMode())
  else
    addCheck("course", "Course mode ignored (override)", true)
  end

  -- 4. GameMode must be ITG (ArrowCloud currently tailored to ITG / FA+ scoring expectations)
  addCheck("gamemode", "GameMode must be ITG", SL.Global.GameMode == "ITG")

  -- 5. LifeDifficultyScale <= 1 (standard or harder)
  addCheck("lifediff", "LifeDifficultyScale must be standard or harder (<=1)",
    PREFSMAN:GetPreference("LifeDifficultyScale") <= 1)

  -- TimingWindowScale and granular timing window metric validation intentionally omitted:
  -- backend recomputes and validates precise timing data.

  -- 8. Rate between 0.10x and 10.00x (inclusive)
  -- This is super extreme ends of what will ever actually be done. The backend actually gates
  -- this on a per leaderboard basis and today all leaderboards require exactly 1.0 rate, so
  -- this is simply a future looking idea.
  local rate = SL.Global.ActiveModifiers.MusicRate * 100
  addCheck("rate", "Music Rate must be 0.10x - 10.00x", rate >= 10 and rate <= 1000)

  -- Player options for note removal/addition
  local po = GAMESTATE:GetPlayerState(player):GetPlayerOptions("ModsLevel_Preferred")
  local removes = (po:Little() or po:NoHolds() or po:NoStretch() or po:NoHands() or po:NoJumps() or po:NoFakes() or po:NoLifts() or po:NoQuads() or po:NoRolls())
  addCheck("no_remove", "No note-removal mods active", not removes)

  local adds = (po:Wide() or po:Skippy() or po:Quick() or po:Echo() or po:BMRize() or po:Stomp() or po:Big())
  addCheck("no_add", "No note-addition mods active", not adds)

  -- Fail type must be Immediate or ImmediateContinue
  local failType = GAMESTATE:GetPlayerFailType(player)
  local ftValid = (failType == "FailType_Immediate" or failType == "FailType_ImmediateContinue")
  addCheck("failtype", "Fail type must be Immediate/ImmediateContinue", ftValid)

  -- Must be a human player unless override provided via opts.allowAutoplay
  local allowAutoplay = opts.allowAutoplay == true
  addCheck("human", allowAutoplay and "Autoplay allowed (testing override)" or "Player must be human (no autoplay)",
    IsHumanPlayer(player) or allowAutoplay)

  -- MinTNSToScoreNotes cannot hide W1/W2 (must be Greats or worse)
  local minTNSToScoreNores = ToEnumShortString(PREFSMAN:GetPreference("MinTNSToScoreNotes"))
  local rehitsOk = (SL.Global.GameMode == "ITG") and (minTNSToScoreNores ~= "W1" and minTNSToScoreNores ~= "W2") or false
  addCheck("rehit", "MinTNSToScoreNotes must be >= W3", rehitsOk)

  -- Log summary (only if failing) – compact
  if not results.ok then
    local msgs = {}
    for _, c in ipairs(results.checks) do if not c.pass then table.insert(msgs, c.id) end end
    log("Eligibility failed for P" .. (pn == "P1" and "1" or "2") .. ": " .. table.concat(msgs, ","))
  end

  return results
end

-- Utility functions
debugPrint = function(message)
  if Trace then Trace(MODULE_TAG .. " " .. message) end
end

local function printTable(t, indent)
  indent = indent or 0
  local indentStr = string.rep("  ", indent)

  for k, v in pairs(t) do
    if type(v) == "table" then
      debugPrint(indentStr .. tostring(k) .. ":")
      printTable(v, indent + 1)
    else
      debugPrint(indentStr .. tostring(k) .. ": " .. tostring(v))
    end
  end
end

-- Profile and API key management (returns table { apiKey, allowAutoplay })
local function readApiKey(player)
  local playerIndex = (player == PLAYER_1) and 0 or 1
  local profilePath = PROFILEMAN:GetProfileDir(playerIndex)
  local filePath = profilePath .. "ArrowCloud.ini"
  local apiKey
  local allowAutoplay = false

  if not FILEMAN:DoesFileExist(filePath) then
    IniFile.WriteFile(filePath, {
      ["ArrowCloud"] = {
        ["ApiKey"] = "",
        ["AllowAutoplay"] = "0" -- set to 1 for testing autoplay submissions
      }
    })
  else
    local contents = IniFile.ReadFile(filePath)
    if contents["ArrowCloud"] then
      if contents["ArrowCloud"]["ApiKey"] then
        apiKey = contents["ArrowCloud"]["ApiKey"]
      end
      if contents["ArrowCloud"]["AllowAutoplay"] ~= nil then
        allowAutoplay = tostring(contents["ArrowCloud"]["AllowAutoplay"]) == "1"
      else
        contents["ArrowCloud"]["AllowAutoplay"] = "0"
        IniFile.WriteFile(filePath, contents)
      end
    end
  end

  return { apiKey = apiKey, allowAutoplay = allowAutoplay }
end

-- JSON encoding utilities
local function escapeJsonString(str)
  local replacements = {
    ['"'] = '\\"',
    ['\\'] = '\\\\',
    ['\b'] = '\\b',
    ['\f'] = '\\f',
    ['\n'] = '\\n',
    ['\r'] = '\\r',
    ['\t'] = '\\t'
  }
  return str:gsub('[%z\1-\31\\"]', replacements)
end

local function encodeJsonValue(value)
  local valueType = type(value)

  if valueType == "string" then
    return '"' .. escapeJsonString(value) .. '"'
  elseif valueType == "number" or valueType == "boolean" then
    return tostring(value)
  elseif valueType == "table" then
    local isArray = true
    local maxIndex = 0

    for k, _ in pairs(value) do
      if type(k) ~= "number" or k <= 0 or math.floor(k) ~= k then
        isArray = false
        break
      end
      if k > maxIndex then
        maxIndex = k
      end
    end

    local result = {}
    if isArray then
      for i = 1, maxIndex do
        table.insert(result, encodeJsonValue(value[i]))
      end
      return "[" .. table.concat(result, ",") .. "]"
    else
      for k, v in pairs(value) do
        table.insert(result, '"' .. escapeJsonString(k) .. '":' .. encodeJsonValue(v))
      end
      return "{" .. table.concat(result, ",") .. "}"
    end
  else
    return "null"
  end
end

local function encodeJson(value)
  return encodeJsonValue(value)
end

-- HTTP communication
local function sendScoreData(data, apiKey, hash, player)
  local url = BASE_URL .. "/v1/chart/" .. hash .. "/play"
  debugPrint("HTTP POST URL: " .. url)

  local jsonBody = encodeJson(data)

  NETWORK:HttpRequest {
    url = url,
    method = "POST",
    body = jsonBody,
    headers = {
      ["Content-Type"] = "application/json",
      ["Authorization"] = "Bearer " .. apiKey
    },
    onResponse = function(response)
      local ok = false
      local status = nil
      local err = nil
      local body = ""
      if type(response) == "table" then
        status = response.statusCode
        err = response.error and ToEnumShortString(response.error) or nil
        body = response.body or ""
        if type(body) ~= "string" then body = tostring(body) end
        if #body > 256 then body = body:sub(1, 256) .. "…" end
        ok = (status ~= nil and status >= 200 and status < 300)
      else
        -- Legacy path; treat as failure but log what we saw.
        body = tostring(response)
      end
      debugPrint("Submit response: status=" .. tostring(status) .. (err and (" error=" .. err) or "") .. " body=" .. body)

      -- Notify UI listeners on evaluation screens.
      local pn = player and ToEnumShortString(player) or nil
      MESSAGEMAN:Broadcast("ArrowCloudSubmitResult", { ok = ok, player = pn, status = status, error = err })
    end
  }
end

-- Game data collection functions
local function getLifebarData(player)
  local steps = GAMESTATE:GetCurrentSteps(player)
  local timingData = steps:GetTimingData()
  local firstSecond = math.min(timingData:GetElapsedTimeFromBeat(0), 0)
  local chartStartSecond = GAMESTATE:GetCurrentSong():GetFirstSecond()
  local lastSecond = GAMESTATE:GetCurrentSong():GetLastSecond()
  local duration = lastSecond - firstSecond

  local lifebarData = {}
  local playerStageStats = STATSMAN:GetCurStageStats():GetPlayerStageStats(player)
  local lifeRecord = playerStageStats:GetLifeRecord(lastSecond, 100)

  for i, lifebarValue in ipairs(lifeRecord) do
    local stepSecond = chartStartSecond + (i - 1) * (duration / #lifeRecord)
    local xValue = stepSecond
    local yValue = lifebarValue
    table.insert(lifebarData, { x = xValue, y = yValue })
  end

  return lifebarData
end

local function getNPSData(player)
  if GAMESTATE:IsCourseMode() then return {} end

  local pn = ToEnumShortString(player)
  local steps = GAMESTATE:GetCurrentSteps(player)
  local song = GAMESTATE:GetCurrentSong()
  if not steps or not song then return {} end

  -- Ensure Streams data populated (wrapped to avoid hard crash if parser fails)
  pcall(ParseChartInfo, steps, pn)

  local peak = SL[pn] and SL[pn].Streams and SL[pn].Streams.PeakNPS or nil
  local perMeasure = SL[pn] and SL[pn].Streams and SL[pn].Streams.NPSperMeasure or nil
  if not (peak and perMeasure and #perMeasure > 1) then return {} end

  local timingData = steps:GetTimingData()
  local firstSecond = math.min(timingData:GetElapsedTimeFromBeat(0), 0)
  local lastSecond = song:GetLastSecond()

  local points = {}
  local started = false
  for i, nps in ipairs(perMeasure) do
    if nps > 0 then started = true end
    if started then
      local t = timingData:GetElapsedTimeFromBeat((i - 1) * 4)
      local normX = 0
      if lastSecond > firstSecond then
        normX = (t - firstSecond) / (lastSecond - firstSecond)
      end
      if normX < 0 then normX = 0 elseif normX > 1 then normX = 1 end
      local normY = 0
      if peak > 0 then normY = nps / peak end
      if normY < 0 then normY = 0 elseif normY > 1 then normY = 1 end
      table.insert(points, { x = normX, y = normY, nps = nps, measure = i - 1 })
    end
  end

  return {
    points = points,
    peakNPS = peak,
    firstSecond = firstSecond,
    lastSecond = lastSecond
  }
end

local function getTimingData(player)
  local pn = ToEnumShortString(player)
  local sequential_offsets = SL[pn].Stages.Stats[SL.Global.Stages.PlayedThisGame + 1].sequential_offsets
  local worst_window = GetTimingWindow(math.max(2, GetWorstJudgment(sequential_offsets)))
  return sequential_offsets, worst_window
end

local function getRadarData(player)
  local playerStageStats = STATSMAN:GetCurStageStats():GetPlayerStageStats(player)
  local radarCategories = { 'Holds', 'Mines', 'Rolls' }
  local radarValues = {}

  for _, category in ipairs(radarCategories) do
    radarValues[category] = {}
    radarValues[category][1] = playerStageStats:GetRadarActual():GetValue("RadarCategory_" .. category)
    radarValues[category][2] = playerStageStats:GetRadarPossible():GetValue("RadarCategory_" .. category)
    radarValues[category][2] = clamp(radarValues[category][2], 0, 999)
  end

  return radarValues
end

-- Player modifiers analysis
local function getPlayerModifiers(player)
  local pn = ToEnumShortString(player)
  local playerOptions = GAMESTATE:GetPlayerState(pn):GetPlayerOptions("ModsLevel_Preferred")

  -- Speed modifier detection
  local function getSpeedModifier()
    local cmod, cmodeSpeed = playerOptions:CMod()
    local mmod, mmodSpeed = playerOptions:MMod()
    local xmod, xmodSpeed = playerOptions:XMod()

    if cmod then
      return "C", cmod
    elseif mmod then
      return "M", mmod
    elseif xmod then
      return "X", tonumber(("%.2f"):format(xmod))
    else
      return "X", 1.0
    end
  end

  -- Mini percentage calculation
  local function getMiniPercentage()
    local mini = playerOptions:Mini()
    if mini and mini > 0 then
      return math.floor(100 * mini + 0.5)
    end
    return 100
  end

  -- Perspective detection
  local function getPerspective()
    if playerOptions:Overhead() then
      return "Overhead"
    elseif playerOptions:Hallway() then
      return "Hallway"
    elseif playerOptions:Distant() then
      return "Distant"
    elseif playerOptions:Incoming() then
      return "Incoming"
    elseif playerOptions:Space() then
      return "Space"
    else
      return "Overhead"
    end
  end

  -- Noteskin detection
  local function getNoteskin()
    local noteskin = playerOptions:NoteSkin()
    return noteskin or "default"
  end

  -- Turn modifier detection
  local function getTurnModifier()
    if playerOptions:Mirror() then
      return "Mirror"
    elseif playerOptions:Left() then
      return "Left"
    elseif playerOptions:Right() then
      return "Right"
    elseif playerOptions:LRMirror() then
      return "LR-Mirror"
    elseif playerOptions:UDMirror() then
      return "UD-Mirror"
    elseif playerOptions:Shuffle() then
      return "Shuffle"
    elseif playerOptions:SoftShuffle() then
      return "Shuffle"
    elseif playerOptions:SuperShuffle() then
      return "Shuffle"
    elseif playerOptions:HyperShuffle() then
      return "Shuffle"
    else
      return "None"
    end
  end

  -- Scroll modifier detection
  local function getScrollModifier()
    if playerOptions:Reverse() and playerOptions:Reverse() > 0.5 then
      return "Reverse"
    elseif playerOptions:Split() and playerOptions:Split() > 0.5 then
      return "Split"
    elseif playerOptions:Alternate() and playerOptions:Alternate() > 0.5 then
      return "Alternate"
    elseif playerOptions:Cross() and playerOptions:Cross() > 0.5 then
      return "Cross"
    elseif playerOptions:Centered() and playerOptions:Centered() > 0.5 then
      return "Centered"
    else
      return nil
    end
  end

  -- Disabled timing windows detection
  local function getDisabledTimingWindows()
    local disabledWindows = playerOptions:GetDisabledTimingWindows()
    if not disabledWindows or #disabledWindows == 0 then
      return "None"
    end

    local windowNames = {}
    for _, window in ipairs(disabledWindows) do
      if window == "TimingWindow_W5" then
        table.insert(windowNames, "Way Offs")
      elseif window == "TimingWindow_W4" then
        table.insert(windowNames, "Decents")
      elseif window == "TimingWindow_W1" then
        table.insert(windowNames, "Fantastics")
      elseif window == "TimingWindow_W2" then
        table.insert(windowNames, "Excellents")
      end
    end

    if #windowNames == 0 then
      return "None"
    elseif #windowNames == 1 then
      return windowNames[1]
    else
      return table.concat(windowNames, " + ")
    end
  end

  -- Acceleration modifiers detection
  local function getAccelerationModifiers()
    local accelMods = {}

    if playerOptions:Boost() and playerOptions:Boost() > 0 then
      table.insert(accelMods, "Boost")
    end
    if playerOptions:Brake() and playerOptions:Brake() > 0 then
      table.insert(accelMods, "Brake")
    end
    if playerOptions:Wave() and playerOptions:Wave() > 0 then
      table.insert(accelMods, "Wave")
    end
    if playerOptions:Expand() and playerOptions:Expand() > 0 then
      table.insert(accelMods, "Expand")
    end
    if playerOptions:Boomerang() and playerOptions:Boomerang() > 0 then
      table.insert(accelMods, "Boomerang")
    end

    return accelMods
  end

  -- Effect modifiers detection
  local function getEffectModifiers()
    local effectMods = {}

    if playerOptions:Drunk() and playerOptions:Drunk() > 0 then
      table.insert(effectMods, "Drunk")
    end
    if playerOptions:Dizzy() and playerOptions:Dizzy() > 0 then
      table.insert(effectMods, "Dizzy")
    end
    if playerOptions:Confusion() and playerOptions:Confusion() > 0 then
      table.insert(effectMods, "Confusion")
    end
    if playerOptions:Big() then
      table.insert(effectMods, "Big")
    end
    if playerOptions:Flip() and playerOptions:Flip() > 0 then
      table.insert(effectMods, "Flip")
    end
    if playerOptions:Invert() and playerOptions:Invert() > 0 then
      table.insert(effectMods, "Invert")
    end
    if playerOptions:Tornado() and playerOptions:Tornado() > 0 then
      table.insert(effectMods, "Tornado")
    end
    if playerOptions:Tipsy() and playerOptions:Tipsy() > 0 then
      table.insert(effectMods, "Tipsy")
    end
    if playerOptions:Bumpy() and playerOptions:Bumpy() > 0 then
      table.insert(effectMods, "Bumpy")
    end
    if playerOptions:Beat() and playerOptions:Beat() > 0 then
      table.insert(effectMods, "Beat")
    end

    return effectMods
  end

  -- Appearance modifiers detection
  local function getAppearanceModifiers()
    local appearanceMods = {}

    if playerOptions:Hidden() and playerOptions:Hidden() > 0 then
      table.insert(appearanceMods, "Hidden")
    end
    if playerOptions:Sudden() and playerOptions:Sudden() > 0 then
      table.insert(appearanceMods, "Sudden")
    end
    if playerOptions:Stealth() and playerOptions:Stealth() > 0 then
      table.insert(appearanceMods, "Stealth")
    end
    if playerOptions:Blink() and playerOptions:Blink() > 0 then
      table.insert(appearanceMods, "Blink")
    end
    if playerOptions:RandomVanish() and playerOptions:RandomVanish() > 0 then
      table.insert(appearanceMods, "R.Vanish")
    end

    return appearanceMods
  end

  -- Build complete modifiers structure
  local speedType, speedValue = getSpeedModifier()

  return {
    speed = {
      type = speedType,
      value = speedValue
    },
    mini = getMiniPercentage(),
    perspective = getPerspective(),
    noteskin = getNoteskin(),
    turn = getTurnModifier(),
    scroll = getScrollModifier(),
    disabledWindows = getDisabledTimingWindows(),
    acceleration = getAccelerationModifiers(),
    effect = getEffectModifiers(),
    appearance = getAppearanceModifiers(),
    visualDelay = playerOptions:VisualDelay() and math.floor(playerOptions:VisualDelay() * 1000 + 0.5) or 0
  }
end

-- Data formatting and aggregation functions
local function buildSongResultData(player, style)
  local pn = ToEnumShortString(player)
  local song = GAMESTATE:GetCurrentSong()

  -- Song metadata
  local songInfo = {
    name        = escapeJsonString(song:GetTranslitFullTitle()),
    artist      = escapeJsonString(song:GetTranslitArtist()),
    pack        = escapeJsonString(song:GetGroupName()),
    length      = string.format("%d:%02d", math.floor(song:MusicLengthSeconds() / 60),
      math.floor(song:MusicLengthSeconds() % 60)),
    stepartist  = escapeJsonString(GAMESTATE:GetCurrentSteps(player):GetAuthorCredit()),
    difficulty  = GAMESTATE:GetCurrentSteps(player):GetMeter(),
    description = escapeJsonString(GAMESTATE:GetCurrentSteps(player):GetDescription()),
    hash        = tostring(SL[pn].Streams.Hash),
    modifiers   = getPlayerModifiers(player)
  }

  -- Performance results
  local resultInfo = {
    score = FormatPercentScore(STATSMAN:GetCurStageStats():GetPlayerStageStats(player):GetPercentDancePoints()):gsub(
      "%%", ""),
    exscore = ("%.2f"):format(CalculateExScore(player)),
    grade = STATSMAN:GetCurStageStats():GetPlayerStageStats(player):GetGrade(),
    radar = getRadarData(player),
    passed = not STATSMAN:GetCurStageStats():GetPlayerStageStats(player):GetFailed(),
  }

  -- Gameplay data
  local timingData, worst_window = getTimingData(player)
  local lifebarInfo = getLifebarData(player)

  -- Combined result
  return {
    songName = songInfo.name,
    artist = songInfo.artist,
    pack = songInfo.pack,
    length = songInfo.length,
    stepartist = songInfo.stepartist,
    difficulty = songInfo.difficulty,
    description = songInfo.description,
    itgScore = resultInfo.score,
    exScore = resultInfo.exscore,
    grade = resultInfo.grade,
    passed = resultInfo.passed,
    hash = songInfo.hash,
    timingData = timingData,
    lifebarInfo = lifebarInfo,
    worstWindow = worst_window,
    style = style,
    modifiers = songInfo.modifiers,
    radar = resultInfo.radar,
    npsInfo = getNPSData(player),
    usedAutoplay = not IsHumanPlayer(player),
    musicRate = SL.Global.ActiveModifiers and SL.Global.ActiveModifiers.MusicRate or 1,
    _arrowCloudBodyVersion = "1.2"
  }
end

--------------------------------------------------------------------------------------------------

local function buildCourseResultData(player, style)
  local pn = ToEnumShortString(player)
  local course = GAMESTATE:GetCurrentCourse()
  local trail = GAMESTATE:GetCurrentTrail(player)

  -- Course metadata
  local courseInfo = {
    name        = escapeJsonString(course:GetTranslitFullTitle()),
    pack        = escapeJsonString(course:GetGroupName()),
    difficulty  = trail:GetMeter(),
    description = escapeJsonString(course:GetDescription()),
    entries     = "[",
    hash        = BinaryToHex(CRYPTMAN:SHA1File(course:GetCourseDir())):sub(1, 16),
    scripter    = escapeJsonString(course:GetScripter()),
    modifiers   = getPlayerModifiers(player)
  }

  -- Build course entries list
  local trailSteps = trail:GetTrailEntries()
  for i in ipairs(trailSteps) do
    courseInfo.entries = courseInfo.entries ..
        "{name: " .. escapeJsonString(trailSteps[i]:GetSong():GetTranslitFullTitle()) ..
        ", length: " .. trailSteps[i]:GetSong():MusicLengthSeconds() ..
        ", artist: " .. escapeJsonString(trailSteps[i]:GetSong():GetTranslitArtist()) ..
        ", difficulty: " .. trailSteps[i]:GetSteps():GetMeter() .. "},"
  end

  -- Clean up entries format
  if courseInfo.entries:sub(-1) == "," then
    courseInfo.entries = courseInfo.entries:sub(1, -2)
  end
  courseInfo.entries = courseInfo.entries .. "]"

  -- Performance results
  local resultInfo = {
    score = FormatPercentScore(STATSMAN:GetCurStageStats():GetPlayerStageStats(player):GetPercentDancePoints()):gsub(
      "%%", ""),
    exscore = ("%.2f"):format(CalculateExScore(player)),
    grade = STATSMAN:GetCurStageStats():GetPlayerStageStats(player):GetGrade(),
    radar = getRadarData(player),
    passed = not STATSMAN:GetCurStageStats():GetPlayerStageStats(player):GetFailed(),
  }

  local lifebarInfo = getLifebarData(player)

  -- Combined result
  return {
    courseName = courseInfo.name,
    pack = courseInfo.pack,
    entries = courseInfo.entries,
    hash = courseInfo.hash,
    scripter = courseInfo.scripter,
    difficulty = courseInfo.difficulty,
    description = courseInfo.description,
    itgScore = resultInfo.score,
    exScore = resultInfo.exscore,
    grade = resultInfo.grade,
    passed = resultInfo.passed,
    lifebarInfo = lifebarInfo,
    style = style,
    modifiers = courseInfo.modifiers,
    radar = resultInfo.radar,
    npsInfo = getNPSData(player),
    usedAutoplay = not IsHumanPlayer(player),
    musicRate = SL.Global.ActiveModifiers and SL.Global.ActiveModifiers.MusicRate or 1,
    _arrowCloudBodyVersion = "1.2"
  }
end

-- Module registration and event handlers
local moduleRegistration = {}

moduleRegistration["ScreenEvaluationStage"] = Def.ActorFrame {
  InitCommand = function(self)
    self.waiting = { P1 = false, P2 = false }
  end,
  ModuleCommand = function(self)
    -- Clear previous texts
    local p1Text = self:GetChild("ACSubmitP1")
    local p2Text = self:GetChild("ACSubmitP2")
    if p1Text then p1Text:settext("") end
    if p2Text then p2Text:settext("") end
    self.waiting = { P1 = false, P2 = false }

    local style = GAMESTATE:GetCurrentStyle():GetName()
    if style == "versus" then
      style = "single"
    end

    local players = GAMESTATE:GetHumanPlayers()
    for _, player in ipairs(players) do
      local pn = ToEnumShortString(player)
      local label = (pn == "P1") and p1Text or p2Text
      local profileCfg = readApiKey(player)
      local eligibility = ArrowCloud.isEligible(player, { allowAutoplay = profileCfg.allowAutoplay })
      local apiKey = profileCfg.apiKey

      if apiKey ~= nil and apiKey ~= "" and eligibility.ok then
        if label then label:settext("Arrow Cloud: submitting…") end
        self.waiting[pn] = true
        local data = buildSongResultData(player, style)
        local hash = tostring(SL[pn].Streams.Hash)
        sendScoreData(data, apiKey, hash, player)
      else
        if label then label:settext("❌ Arrow Cloud") end
        if apiKey ~= nil and not eligibility.ok then
          debugPrint("Skipping submission (ineligible)")
        end
      end
    end
  end,

  ArrowCloudSubmitResultMessageCommand = function(self, params)
    if not params or not params.player then return end
    local pn = params.player
    local label = self:GetChild(pn == "P1" and "ACSubmitP1" or "ACSubmitP2")
    if not label then return end
    if self.waiting[pn] then
      label:settext(params.ok and "✔ Arrow Cloud" or "❌ Arrow Cloud")
      self.waiting[pn] = false
    end
  end,

  LoadFont("Common Normal") .. {
    Name = "ACSubmitP1",
    InitCommand = function(self)
      self:xy(10, _screen.h - 32):zoom(0.6):halign(0)
      self:settext("")
    end
  },
  LoadFont("Common Normal") .. {
    Name = "ACSubmitP2",
    InitCommand = function(self)
      self:xy(_screen.w - 10, _screen.h - 32):zoom(0.6):halign(1)
      self:settext("")
    end
  }
}

moduleRegistration["ScreenEvaluationNonstop"] = Def.ActorFrame {
  InitCommand = function(self)
    self.waiting = { P1 = false, P2 = false }
  end,
  ModuleCommand = function(self)
    local fixed = GAMESTATE:GetCurrentCourse():AllSongsAreFixed()
    local autogen = GAMESTATE:GetCurrentCourse():IsAutogen()
    local endless = GAMESTATE:GetCurrentCourse():IsEndless()

    -- Only process fixed, non-autogen, non-endless courses
    if fixed and not autogen and not endless then
      local p1Text = self:GetChild("ACSubmitP1")
      local p2Text = self:GetChild("ACSubmitP2")
      if p1Text then p1Text:settext("") end
      if p2Text then p2Text:settext("") end
      self.waiting = { P1 = false, P2 = false }

      local style = GAMESTATE:GetCurrentStyle():GetName()
      if style == "versus" then
        style = "single"
      end

      local players = GAMESTATE:GetHumanPlayers()
      for _, player in ipairs(players) do
        local profileCfg = readApiKey(player)
        -- Ignore the course restriction for nonstop; reuse other checks.
        local eligibility = ArrowCloud.isEligible(player,
          { ignoreCourse = true, allowAutoplay = profileCfg.allowAutoplay })

        local apiKey = profileCfg.apiKey
        if eligibility.ok and apiKey ~= nil and apiKey ~= "" then
          local pn = ToEnumShortString(player)
          local label = (pn == "P1") and p1Text or p2Text
          if label then label:settext("Arrow Cloud: submitting…") end
          self.waiting[pn] = true
          local data = buildCourseResultData(player, style)
          local course = GAMESTATE:GetCurrentCourse()
          local hash = BinaryToHex(CRYPTMAN:SHA1File(course:GetCourseDir())):sub(1, 16)
          sendScoreData(data, apiKey, hash, player)
        else
          local pn = ToEnumShortString(player)
          local label = (pn == "P1") and p1Text or p2Text
          if label then label:settext("❌ Arrow Cloud") end
          if apiKey ~= nil and not eligibility.ok then
            debugPrint("Skipping course submission (ineligible)")
          end
        end
      end
    end
  end,

  ArrowCloudSubmitResultMessageCommand = function(self, params)
    if not params or not params.player then return end
    local pn = params.player
    local label = self:GetChild(pn == "P1" and "ACSubmitP1" or "ACSubmitP2")
    if not label then return end
    if self.waiting[pn] then
      label:settext(params.ok and "✔ Arrow Cloud" or "❌ Arrow Cloud")
      self.waiting[pn] = false
    end
  end,

  LoadFont("Common Normal") .. {
    Name = "ACSubmitP1",
    InitCommand = function(self)
      self:xy(10, _screen.h - 32):zoom(0.6):halign(0)
      self:settext("")
    end
  },
  LoadFont("Common Normal") .. {
    Name = "ACSubmitP2",
    InitCommand = function(self)
      self:xy(_screen.w - 10, _screen.h - 32):zoom(0.6):halign(1)
      self:settext("")
    end
  }
}

-- ---------------------------------------------------------------------------------------------
-- Title screen connection status for Arrow Cloud
-- Simple check: hit /auth-check with the first available ArrowCloud API key. No partial states.
-- Renders a compact label in the top-right: "✔ Arrow Cloud" or "❌ Arrow Cloud".

moduleRegistration["ScreenTitleMenu"] = Def.ActorFrame {
  InitCommand = function(self)
    -- position near top-right
    self:xy(_screen.w - 10, 15):zoom(0.8):halign(1)
  end,
  ModuleCommand = function(self)
    self:queuecommand("CheckConnection")
  end,

  -- Perform the auth check.
  CheckConnectionCommand = function(self)
    local bmt = self:GetChild("Status")
    if not bmt then return end

    -- start with a neutral label while checking
    bmt:settext("Arrow Cloud: checking…")

    -- Hit the hello-world endpoint (root) without auth headers.
    local url = BASE_URL .. "/"
    NETWORK:HttpRequest{
      url = url,
      method = "GET",
      connectTimeout = 6,
      transferTimeout = 6,
      onResponse = function(response)
        -- Treat HTTP 200 as success; anything else (including errors) as failure.
        local ok = false
        if type(response) == "table" and response.statusCode == 200 then
          ok = true
        end
        -- Log details safely (truncate body, avoid secrets)
        local status = response and response.statusCode or "(nil)"
        local err = response and response.error and ToEnumShortString(response.error) or nil
        local body = response and response.body or ""
        if type(body) ~= "string" then body = tostring(body) end
        if #body > 256 then body = body:sub(1, 256) .. "…" end
        debugPrint("Hello-check: status=" .. tostring(status) .. (err and (" error=" .. err) or "") .. " body=" .. body)

        if ok then
          bmt:settext("✔ Arrow Cloud")
        else
          bmt:settext("❌ Arrow Cloud")
        end
      end
    }
  end,

  -- The text node we update
  LoadFont("Common Normal") .. {
    Name = "Status",
    InitCommand = function(self)
      self:halign(1)
      self:settext("Arrow Cloud")
    end
  }
}

return moduleRegistration
