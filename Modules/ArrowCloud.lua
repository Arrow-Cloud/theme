--[[
ArrowCloud Module for SimplyLove
Inspired and adapted from Kuro's discord leaderboard scraper: https://github.com/pogof/SimplyLove-DiscordLeaderboard
]]

-- Module configuration
local ArrowCloud = {}

-- Constants
local BASE_URL = "https://b4mdyahpki.execute-api.us-east-2.amazonaws.com/prod"
local MODULE_TAG = "[ArrowCloud-SLmodule]"

-- Utility functions
local function debugPrint(message)
  Trace(MODULE_TAG .. " " .. message)
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

-- Profile and API key management
local function readApiKey(player)
  local playerIndex = (player == PLAYER_1) and 0 or 1
  local profilePath = PROFILEMAN:GetProfileDir(playerIndex)
  local filePath = profilePath .. "ArrowCloud.ini"
  local apiKey

  if not FILEMAN:DoesFileExist(filePath) then
    -- Create file with empty API key for this profile
    IniFile.WriteFile(filePath, {
      ["ArrowCloud"] = {
        ["ApiKey"] = "",
      }
    })
  else
    local contents = IniFile.ReadFile(filePath)
    if contents["ArrowCloud"] and contents["ArrowCloud"]["ApiKey"] then
      apiKey = contents["ArrowCloud"]["ApiKey"]
    end
  end

  return apiKey
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
local function sendScoreData(data, apiKey, hash)
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
      if type(response) == "table" then
        response = table.concat(response)
      end
      debugPrint("HTTP Response: " .. response)
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
    score = FormatPercentScore(STATSMAN:GetCurStageStats():GetPlayerStageStats(player):GetPercentDancePoints()):gsub("%%", ""),
    exscore = ("%.2f"):format(CalculateExScore(player)),
    grade = STATSMAN:GetCurStageStats():GetPlayerStageStats(player):GetGrade(),
    radar = getRadarData(player),
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
    hash = songInfo.hash,
    timingData = timingData,
    lifebarInfo = lifebarInfo,
    worstWindow = worst_window,
    style = style,
    modifiers = songInfo.modifiers,
    radar = resultInfo.radar,
    _arrowCloudBodyVersion = "1.0"
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
    score = FormatPercentScore(STATSMAN:GetCurStageStats():GetPlayerStageStats(player):GetPercentDancePoints()):gsub("%%", ""),
    exscore = ("%.2f"):format(CalculateExScore(player)),
    grade = STATSMAN:GetCurStageStats():GetPlayerStageStats(player):GetGrade(),
    radar = getRadarData(player),
  }

  local lifebarInfo = getLifebarData(player, 1000, 200)

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
    lifebarInfo = lifebarInfo,
    style = style,
    modifiers = courseInfo.modifiers,
    radar = resultInfo.radar
  }
end

-- Module registration and event handlers
local moduleRegistration = {}

moduleRegistration["ScreenEvaluationStage"] = Def.Actor {
  ModuleCommand = function(self)
    local style = GAMESTATE:GetCurrentStyle():GetName()
    if style == "versus" then 
      style = "single" 
    end
    
    for player in ivalues(GAMESTATE:GetHumanPlayers()) do
      local partValid, allValid = ValidForGrooveStats(player)
      local apiKey = readApiKey(player)
      
      if apiKey ~= nil then
        local data = buildSongResultData(player, style)
        local pn = ToEnumShortString(player)
        local hash = tostring(SL[pn].Streams.Hash)
        sendScoreData(data, apiKey, hash)
      end
    end
  end
}

moduleRegistration["ScreenEvaluationNonstop"] = Def.ActorFrame {
  ModuleCommand = function(self)
    local fixed = GAMESTATE:GetCurrentCourse():AllSongsAreFixed()
    local autogen = GAMESTATE:GetCurrentCourse():IsAutogen()
    local endless = GAMESTATE:GetCurrentCourse():IsEndless()

    -- Only process fixed, non-autogen, non-endless courses
    if fixed and not autogen and not endless then
      local style = GAMESTATE:GetCurrentStyle():GetName()
      if style == "versus" then 
        style = "single" 
      end
      
      for player in ivalues(GAMESTATE:GetHumanPlayers()) do
        local partValid, allValid = ValidForGrooveStats(player)

        -- Override course validation logic
        allValid = true
        for i, valid in ipairs(partValid) do
          if i ~= 3 and not valid then
            allValid = false
            break
          end
        end

        local apiKey = readApiKey(player)
        if allValid and apiKey ~= nil then
          local data = buildCourseResultData(player, style)
          local course = GAMESTATE:GetCurrentCourse()
          local hash = BinaryToHex(CRYPTMAN:SHA1File(course:GetCourseDir())):sub(1, 16)
          sendScoreData(data, apiKey, hash)
        end
      end
    end
  end
}

return moduleRegistration
