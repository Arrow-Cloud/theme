-- this is based off of Kuro's discord leaderboard scraper.
-- https://github.com/pogof/SimplyLove-DiscordLeaderboard

-- add future URL here
local BaseURL = "https://b4mdyahpki.execute-api.us-east-2.amazonaws.com/prod"

local function debugPrint(message)
  Trace("[ArrowCloud-SLmodule] " .. message)
end

--------------------------------------------------------------------------------------------------

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

--------------------------------------------------------------------------------------------------

local function readKey(player)
  local pdir
  if player == PLAYER_1 then
    pdir = 0
  else
    pdir = 1
  end

  local profilePath = PROFILEMAN:GetProfileDir(pdir)
  local filePath = profilePath .. "ArrowCloud.ini"

  local apiKey

    if not FILEMAN:DoesFileExist(filePath) then
		-- The file doesn't exist. We will create it for this profile, and then just return.
		IniFile.WriteFile(filePath, {
			["ArrowCloud"]={
				["ApiKey"]="",
				["Username"]="",
				["IsPadPlayer"]=0,
			}
		})
	else
		local contents = IniFile.ReadFile(filePath)
		for k,v in pairs(contents["ArrowCloud"]) do
			if k == "ApiKey" then
                apiKey = v
            end
        end
    end

		-- Always write the file back to disk to ensure it's up to date with
		-- any new fields that may have been added.
-- 		IniFile.WriteFile(path, {
-- 			["ArrowCloud"]={
-- 				["ApiKey"]=SL[pn].ApiKey,
-- 				["Username"]=SL[pn].GrooveStatsUsername,
-- 				["IsPadPlayer"]=SL[pn].IsPadPlayer and "1" or "0",
-- 			}
-- 		})
    return apiKey
end



--------------------------------------------------------------------------------------------------

local function escapeString(str)
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

local function encodeValue(value)
  local valueType = type(value)
  if valueType == "string" then
    return '"' .. escapeString(value) .. '"'
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
        table.insert(result, encodeValue(value[i]))
      end
      return "[" .. table.concat(result, ",") .. "]"
    else
      for k, v in pairs(value) do
        table.insert(result, '"' .. escapeString(k) .. '":' .. encodeValue(v))
      end
      return "{" .. table.concat(result, ",") .. "}"
    end
  else
    return "null"
  end
end

local function encode(value)
  return encodeValue(value)
end

--------------------------------------------------------------------------------------------------

local function sendData(data, apiKey, hash)
  -- Send HTTP POST request
  -- SCREENMAN:SystemMessage("Sending data to ArrowCloud...")

  local URL = BaseURL .. "/v1/chart/" .. hash .. "/play"
  debugPrint("HTTP POST URL: " .. URL)
  -- SCREENMAN:SystemMessage(URL)

  -- Convert data table to JSON string
  local jsonBody = encode(data)

  NETWORK:HttpRequest {
    url = URL,
    -- url = "https://b4mdyahpki.execute-api.us-east-2.amazonaws.com/prod/post-check", -- For testing purposes"
    method = "POST",
    body = jsonBody,
    headers = {
      ["Content-Type"] = "application/json",
      ["Authorization"] = "Bearer " .. apiKey
    },
    onResponse = function(response)
      -- SCREENMAN:SystemMessage("Success")
      if type(response) == "table" then
        response = table.concat(response)
      end
      debugPrint("HTTP Response: " .. response)
    end
  }
end

--------------------------------------------------------------------------------------------------

local function GetLifebarData(player, GraphWidth, GraphHeight)
  local steps = GAMESTATE:GetCurrentSteps(player)
  local timingData = steps:GetTimingData()
  local firstSecond = math.min(timingData:GetElapsedTimeFromBeat(0), 0)
  local chartStartSecond = GAMESTATE:GetCurrentSong():GetFirstSecond()
  local lastSecond = GAMESTATE:GetCurrentSong():GetLastSecond()
  local duration = lastSecond - firstSecond

  local lifebarData = {}
  local playerStageStats = STATSMAN:GetCurStageStats():GetPlayerStageStats(player)
  local lifeRecord = playerStageStats:GetLifeRecord(lastSecond, 100)   -- Use lastSecond and default samples

  for i, lifebarValue in ipairs(lifeRecord) do
    local stepSecond = chartStartSecond + (i - 1) * (duration / #lifeRecord)
    local xValue = ((stepSecond - firstSecond) / duration) * GraphWidth
    local yValue = lifebarValue * GraphHeight -- Scale y value to fit within GraphHeight
    table.insert(lifebarData, { x = xValue, y = yValue })
  end

  return lifebarData
end

--------------------------------------------------------------------------------------------------

local function getTimingData(player)
  local pn = ToEnumShortString(player)

  local sequential_offsets = SL[pn].Stages.Stats[SL.Global.Stages.PlayedThisGame + 1].sequential_offsets
  local worst_window = GetTimingWindow(math.max(2, GetWorstJudgment(sequential_offsets)))

  return sequential_offsets, worst_window
end

--------------------------------------------------------------------------------------------------

-- Im only interested in what affects EX score, which should be just Holds, Rolls and Mines
-- Hands I guess are a separate thing, but might as well include them lol
-- Not interested in other Tech notation (at least for now lol)
local function getRadar(player)
  local pss = STATSMAN:GetCurStageStats():GetPlayerStageStats(player)
  local RadarCategories = {'Holds', 'Mines', 'Rolls' }

  local radarValues = {}

  for i, RCType in ipairs(RadarCategories) do
    radarValues[RCType] = {}
    radarValues[RCType][1] = pss:GetRadarActual():GetValue("RadarCategory_" .. RCType)
    radarValues[RCType][2] = pss:GetRadarPossible():GetValue("RadarCategory_" .. RCType)
    radarValues[RCType][2] = clamp(radarValues[RCType][2], 0, 999)
  end

  return radarValues
end

--------------------------------------------------------------------------------------------------

local function getModifiers(player)
  local pn = ToEnumShortString(player)

  local playerOptions = GAMESTATE:GetPlayerState(pn):GetPlayerOptions("ModsLevel_Preferred")

  -- Speed modifiers
  local cmod = playerOptions:CMod()
  local mmod = playerOptions:MMod()
  local xmod = playerOptions:XMod()

  -- Format xmod to 2 decimal places if it exists
  if xmod ~= nil then
    xmod = tonumber(("%.2f"):format(xmod))
  end

  -- Mini percentage (convert to percentage and round)
  local mini = playerOptions:Mini()
  local miniPercent = nil
  if mini ~= nil then
    miniPercent = math.floor(100 * mini + 0.5)
  end

  -- Visual delay in milliseconds
  local visualDelay = playerOptions:VisualDelay()
  local visualDelayMs = nil
  if visualDelay ~= nil then
    visualDelayMs = math.floor(1000 * visualDelay + 0.5)
  end

  -- Turn modifiers
  local mirror = playerOptions:Mirror()
  local left = playerOptions:Left()
  local right = playerOptions:Right()
  local shuffle = playerOptions:Shuffle()
  --local turnnone = playerOptions:TurnNone() -- This doesn't seem to work in ITGMania

  -- Determine which turn modifier is active (only one should be true)
  local turnModifier = nil
  if mirror then
    turnModifier = "Mirror"
  elseif left then
    turnModifier = "Left"
  elseif right then
    turnModifier = "Right"
  elseif shuffle then
    turnModifier = "Shuffle"
  else
    turnModifier = "None" -- or could be nil
  end

  -- Return structured data
  local modifiers = {
    speed = {
      cmod = cmod,
      mmod = mmod,
      xmod = xmod
    },
    mini = miniPercent,
    visualDelay = visualDelayMs,
    turn = turnModifier
    -- Future modifiers can be easily added here:
    -- blender = blender,
    -- lrMirror = lrMirror,
    -- udMirror = udMirror
  }

  return modifiers
end

--------------------------------------------------------------------------------------------------

local function SongResultData(player, style)
  local pn = ToEnumShortString(player)

  local song = GAMESTATE:GetCurrentSong()

  -- Song Data
  local songInfo = {
    name        = escapeString(song:GetTranslitFullTitle()),
    artist      = escapeString(song:GetTranslitArtist()),
    pack        = escapeString(song:GetGroupName()),
    length      = string.format("%d:%02d", math.floor(song:MusicLengthSeconds() / 60),
      math.floor(song:MusicLengthSeconds() % 60)),
    stepartist  = escapeString(GAMESTATE:GetCurrentSteps(player):GetAuthorCredit()),
    difficulty  = GAMESTATE:GetCurrentSteps(player):GetMeter(),
    description = escapeString(GAMESTATE:GetCurrentSteps(player):GetDescription()),
    hash        = tostring(SL[pn].Streams.Hash),
    modifiers   = getModifiers(player)
  }

  -- Result Data
  local resultInfo = {
    -- playerName = escapeString(GAMESTATE:GetPlayerDisplayName(player)), -- unnecessary
    score = FormatPercentScore(STATSMAN:GetCurStageStats():GetPlayerStageStats(player):GetPercentDancePoints()):gsub(
    "%%", ""),
    exscore = ("%.2f"):format(CalculateExScore(player)),
    grade = STATSMAN:GetCurStageStats():GetPlayerStageStats(player):GetGrade(),
    radar = getRadar(player),
  }


  -- local scatterplotData, worst_window = getScatterplotData(player, 1000, 200)
  local timingData, worst_window = getTimingData(player)

  local lifebarInfo = GetLifebarData(player, 1000, 200)

  -- Return data as a table instead of JSON string
  local data = {
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
    radar = resultInfo.radar
  }

  return data
end

--------------------------------------------------------------------------------------------------

local function CourseResultData(player, style)
  local pn = ToEnumShortString(player)

  local course = GAMESTATE:GetCurrentCourse()
  local trail = GAMESTATE:GetCurrentTrail(player)



  -- Course Data
  local courseInfo = {
    name        = escapeString(course:GetTranslitFullTitle()),
    pack        = escapeString(course:GetGroupName()),
    difficulty  = trail:GetMeter(),
    description = escapeString(course:GetDescription()),
    entries     = "[",
    hash        = BinaryToHex(CRYPTMAN:SHA1File(course:GetCourseDir())):sub(1, 16),
    scripter    = escapeString(course:GetScripter()),
    modifiers   = getModifiers(player)
  }


  local trailSteps = trail:GetTrailEntries()
  for i in ipairs(trailSteps) do
    courseInfo.entries = courseInfo.entries ..
    "{name: " ..
    escapeString(trailSteps[i]:GetSong():GetTranslitFullTitle()) ..
    ", length: " ..
    trailSteps[i]:GetSong():MusicLengthSeconds() ..
    ", artist: " ..
    escapeString(trailSteps[i]:GetSong():GetTranslitArtist()) ..
    ", difficulty:  " ..
    trailSteps[i]:GetSteps():GetMeter() .. "},"                                                                                                                                                                                                                                                                                               -- ", difficulty = " .. trailSteps:GetSteps():GetMeter() ..
  end
  -- Remove the last comma and append the closing bracket
  if courseInfo.entries:sub(-1) == "," then
    courseInfo.entries = courseInfo.entries:sub(1, -2)
  end
  courseInfo.entries = courseInfo.entries .. "]"


  -- Result Data
  local resultInfo = {
    --playerName = escapeString(GAMESTATE:GetPlayerDisplayName(player)), -- unnecessary
    score = FormatPercentScore(STATSMAN:GetCurStageStats():GetPlayerStageStats(player):GetPercentDancePoints()):gsub(
    "%%", ""),
    exscore = ("%.2f"):format(CalculateExScore(player)),
    grade = STATSMAN:GetCurStageStats():GetPlayerStageStats(player):GetGrade(),
    radar = getRadar(player),
  }

  local lifebarInfo = GetLifebarData(player, 1000, 200)

  -- Return data as a table instead of JSON string
  local data = {
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

  return data
end


--------------------------------------------------------------------------------------------------

local u = {}

-- for player in ivalues(GAMESTATE:GetHumanPlayers()) do
--   local sequential_offsets = {}
--   u["ScreenGameplay"] = Def.Actor{
-- 	  JudgmentMessageCommand=function(self, params)
-- 		  if params.Player ~= player then return end
-- 		  if params.HoldNoteScore then return end

-- 		  if params.TapNoteOffset then
-- 			  -- If the judgment was a Miss, store the string "Miss" as offset instead of the number 0.
-- 			  -- For all other judgments, store the offset value provided by the engine as a number.
-- 			  local offset = params.TapNoteScore == "TapNoteScore_Miss" and "Miss" or params.TapNoteOffset

-- 			  -- Store judgment offsets (including misses) in an indexed table as they occur.
-- 			  -- Also store the CurMusicSeconds for Evaluation's scatter plot.
-- 		  	sequential_offsets[#sequential_offsets+1] = { GAMESTATE:GetSongBeat(), offset }
-- 		  end
-- 	  end,
-- 	  OffCommand=function(self)
-- 		  local storage = SL[ToEnumShortString(player)].Stages.Stats[SL.Global.Stages.PlayedThisGame + 1]
-- 		  storage.sequential_offsets_beat = sequential_offsets
--   	end
--   }
-- end

u["ScreenEvaluationStage"] = Def.Actor {
  ModuleCommand = function(self)
    -- single, versus, double
    local style = GAMESTATE:GetCurrentStyle():GetName()
    if style == "versus" then style = "single" end
    for player in ivalues(GAMESTATE:GetHumanPlayers()) do
      local partValid, allValid = ValidForGrooveStats(player)
      local apiKey = readKey(player)
      if apiKey ~= nil then
        local data = SongResultData(player, style)
        local pn = ToEnumShortString(player)
        local hash = tostring(SL[pn].Streams.Hash)
        sendData(data, apiKey, hash)
      end
    end
  end
}


u["ScreenEvaluationNonstop"] = Def.ActorFrame {
  ModuleCommand = function(self)
    local fixed = GAMESTATE:GetCurrentCourse():AllSongsAreFixed()
    local autogen = GAMESTATE:GetCurrentCourse():IsAutogen()
    local endless = GAMESTATE:GetCurrentCourse():IsEndless()

    -- Would be kinda unfair
    if fixed and not autogen and not endless then
      -- single, versus, double
      local style = GAMESTATE:GetCurrentStyle():GetName()
      if style == "versus" then style = "single" end
      for player in ivalues(GAMESTATE:GetHumanPlayers()) do
        -- Doesn't return true for courses, but I can use everything else lol
        local partValid, allValid = ValidForGrooveStats(player)

        allValid = true
        for i, valid in ipairs(partValid) do
          if i ~= 3 and not valid then
            allValid = false
            break
          end
        end

        local apiKey = readKey(player)
        if allValid and apiKey ~= nil then
          -- Different day different data
          local data = CourseResultData(player, style)
          local course = GAMESTATE:GetCurrentCourse()
          local hash = BinaryToHex(CRYPTMAN:SHA1File(course:GetCourseDir())):sub(1, 16)
          sendData(data, apiKey, hash)
        end
      end
    end
  end
}


return u
