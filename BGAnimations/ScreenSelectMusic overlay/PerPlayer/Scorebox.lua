-- Abort for courses; ArrowCloud + GS only on song wheel
if GAMESTATE:IsCourseMode() then return end

-- Respect existing preference for where to show a scorebox
if ThemePrefs.Get("MusicWheelGS") ~= "Scorebox" then return end

local player = ...
local pn = ToEnumShortString(player)

-- Previous logic returned if GrooveStats wasn't available. We now allow
-- ArrowCloud-only operation. We'll only skip entirely if BOTH services are unusable.
local gsUnavailable = (not IsServiceAllowed(SL.GrooveStats.GetScores)) or SL[pn].ApiKey == ""
local arrowcloudUnavailable = (not SL.ArrowCloud) or (not SL.ArrowCloud.Enabled)
if gsUnavailable and arrowcloudUnavailable then return end

local n = player==PLAYER_1 and "1" or "2"
local IsNotWide = (GetScreenAspectRatio() < 16/9)
local NoteFieldIsCentered = (GetNotefieldX(player) == _screen.cx)
-- GrooveStats shows 5 rows; ArrowCloud now returns 7. We render 7 rows total
-- (GS will leave rows 6-7 blank) to keep the layout simple and consistent.
local NumEntries = 7

-- With GrooveStats leaderboards hidden, the box only ever shows ITL (5 rows) or
-- Arrow Cloud (7 rows) content, never GrooveStats' own 5-row layout - so we can
-- afford a slightly larger, less cramped box instead of keeping it sized for GS.
local hideGrooveStats = ThemePrefs.Get("HideGrooveStats")

local border = hideGrooveStats and 8 or 5
-- Row text x-offsets (below) are fixed distances from center, not proportional to
-- width, so widening the box just adds slack on the right without moving the text -
-- leave width alone and only grow height (more row spacing) and border (padding).
local width = 162
local height = hideGrooveStats and 94 or 80
-- The box is positioned by its center, so growing height extends it both up and
-- down equally - shift the anchor up by half the growth so the bottom edge stays
-- lined up with the footer/PRESS START row instead of dropping into it.
local yShift = -(height - 80) / 2

-- Row display policy: GS/events show 5 rows; ArrowCloud shows 7 within same height
local GS_ROWS = 5
local AC_ROWS = 7
local function RowsForStyle(style)
	return (style >= 4) and AC_ROWS or GS_ROWS
end
local function RowSpacingForStyle(style)
	return height / RowsForStyle(style)
end
local function TextZoomForStyle(style)
	if style >= 4 then
		return hideGrooveStats and 0.80 or 0.75
	end
	return hideGrooveStats and 0.89 or 0.87
end
local function CrownZoomForStyle(style)
	if style >= 4 then
		return hideGrooveStats and 0.08 or 0.075
	end
	return hideGrooveStats and 0.092 or 0.09
end

local cur_style = 0
-- We reserve style indices (0-based, matching all_data[style+1]):
-- 0/1: GrooveStats ITG / EX (ordering dynamic)
-- 2: RPG (event)
-- 3: ITL (event)
-- 4: ArrowCloud ITG
-- 5: ArrowCloud EX
-- 6: ArrowCloud HardEX
local num_styles = 7

-- Styles in the order they actually became available, built incrementally as each
-- service (AC, GS) responds - never overwritten - so the rotation always reflects
-- genuine arrival order instead of racing whichever response processor happens to
-- run last. AC is normally fast and GS is normally slow, so this is usually AC's
-- styles first, with GS's (and event) styles appended once GS catches up.
local styleOrder = {}
local styleOrderSet = {}

local GrooveStatsBlue = color("#007b85")
local RpgYellow = color("1,0.972,0.792,1")
local ItlPink = color("1,0.2,0.406,1")
local BoogieStatsPurple = color("#8000ff")

local currentHash = "nothing"

local style_color = {
	[0] = GrooveStatsBlue,  -- GS ITG/EX slot A
	[1] = GrooveStatsBlue,  -- GS ITG/EX slot B
	[2] = RpgYellow,
	[3] = ItlPink,
	[4] = SL.JudgmentColors["FA+"][2], -- AC ITG
	[5] = SL.JudgmentColors["FA+"][1], -- AC EX
	[6] = SL.JudgmentColors["FA+"][7], -- AC HardEX
}

local self_color = color("#a1ff94")
local rival_color = color("#c29cff")

local loop_seconds = 5
local transition_seconds = 0.5
local anim_seconds = transition_seconds
local pendingRequests = 0
-- Set when the first GS/AC response (of possibly several in-flight for this
-- chart) has been handled, so we can show the scorebox as soon as any one
-- service has data instead of waiting for every enabled service to respond.
local firstResponseHandled = false
-- True while a GrooveStats request is in flight for the current chart. GS is
-- typically much slower to respond than ArrowCloud, so the box will often be
-- showing already (via AC) while this is still true - used to keep the
-- GrooveStats logo's loading glow going instead of prematurely settling it.
local gsPending = false
-- Bumped every time MakeRequestCommand starts a new request cycle (new chart
-- selected). Each in-flight request captures the value current at the moment it
-- was fired; if that value no longer matches requestGeneration by the time the
-- response arrives, the chart changed again in between and the response is
-- discarded outright rather than corrupting shared state (all_data,
-- pendingRequests, firstResponseHandled, gsPending) for whatever chart is
-- actually selected now. Without this, fast scrolling could let a slow, stale
-- GS/AC response land after a newer request cycle already started, which is the
-- likely cause of the box occasionally failing to load in properly.
local requestGeneration = 0

local all_data = {}

local ResetAllData = function()
	all_data = {}
	styleOrder = {}
	styleOrderSet = {}
	SL[pn].Rival = {}
	SL[pn].Rival.Score = 0
	SL[pn].Rival.ExScore = 0
	SL[pn].Rival.WRScore = 0
	SL[pn].Rival.WRExScore = 0

	for i=1,num_styles do
		local data = { has_data=false, scores={} }
		for j=1,NumEntries do
			data.scores[j] = {
				rank="",
				name="",
				score="",
				isSelf=false,
				isRival=false,
				isFail=false,
				isEx=false,
			}
		end
		all_data[i] = data
	end
end

-- Initialize the all_data object.
ResetAllData()

-- Appends a style to the rotation order the first time it gets data, preserving
-- genuine arrival order (see styleOrder declaration above). style_index 3 is ITL,
-- which should still be shown even if GrooveStats itself is hidden; 0/1/2 (GS
-- ITG/EX, RPG) are suppressed in that case, matching prior behavior.
local function AppendStyle(style_index)
	if hideGrooveStats and style_index <= 2 then return end
	if not styleOrderSet[style_index] then
		styleOrderSet[style_index] = true
		styleOrder[#styleOrder+1] = style_index
	end
end

local SetScoreData = function(data_idx, score_idx, rank, name, score, isSelf, isRival, isFail, isEx)
	if score_idx > NumEntries then return end
	all_data[data_idx].has_data = true

	local score_data = all_data[data_idx]["scores"][score_idx]
	score_data.rank = rank..((#rank > 0) and "." or "")
	score_data.name = name
	score_data.score = score
	score_data.isSelf = isSelf
	score_data.isRival = isRival
	score_data.isFail = isFail
	score_data.isEx = isEx
	
	if not isFail and (isRival or isSelf) then
		if data_idx == 3 then
			if tonumber(score) > SL[pn].Rival.ExScore then
				SL[pn].Rival.ExScore = tonumber(score)
			end
		else
			if tonumber(score) > SL[pn].Rival.Score then
				SL[pn].Rival.Score = tonumber(score)
			end
		end
	end
	
	if score_data.rank == 1 then
		if data_idx == 3 then
			SL[pn].Rival.WRExScore = tonumber(score)
		else
			if tonumber(score) > SL[pn].Rival.WRScore then
				SL[pn].Rival.WRScore = tonumber(score)
			end
		end
	end
end

local LeaderboardRequestProcessor = function(res, args)
	local master = args and args.parent
	-- Discard responses left over from a chart we've since navigated away from -
	-- see requestGeneration's declaration above. This must be the very first
	-- check, before any shared state gets touched.
	if not args or args.generation ~= requestGeneration then return end
	gsPending = false
  if master == nil then
		Trace("[Scorebox] master is nil, aborting")
		return
	end

	if res.error or res.statusCode ~= 200 then
		Trace("[Scorebox] GS FAILED statusCode="..tostring(res.statusCode).." error="..tostring(res.error))
		local error = res.error and ToEnumShortString(res.error) or nil
		local text = ""
		if error == "Timeout" then
			text = "Timed Out"
		elseif error or (res.statusCode ~= nil and res.statusCode ~= 200) then
			text = "Failed to Load 😞"
		end
		SetScoreData(1, 1, "", text, "", false, false, false, false)
		pendingRequests = pendingRequests - 1
		if not firstResponseHandled and master ~= nil then
			firstResponseHandled = true
			master:queuecommand("CheckScorebox")
		end
		return
	end

	local playerStr = "player"..n
	local data = JsonDecode(res.body)

	-- BoogieStats integration
	-- Find out whether this chart is ranked on GrooveStats. 
	-- If it is unranked, alter groovestats logo and the box border color to the BoogieStats theme
	local headers = res.headers
	local boogie = false
	local boogie_ex = false
	if headers["bs-leaderboard-player-" .. n] == "BS" then
		boogie = true
	elseif headers["bs-leaderboard-player-" .. n] == "BS-EX" then
		boogie_ex = true
	end
	-- The response can land after we've left ScreenSelectMusic (or after this player's
	-- box has otherwise gone away), so guard every step of this chain rather than just
	-- the first - a response arriving mid-transition shouldn't be able to crash us.
	local overlay = SCREENMAN:GetTopScreen():GetChild("Overlay")
	local scoreBox = overlay and overlay:GetChild("PerPlayer") and overlay:GetChild("PerPlayer"):GetChild("ScoreBox" .. pn)
	if not scoreBox then return end
	local gsBox = scoreBox:GetChild("GrooveStatsLogo")
	local bsBox = scoreBox:GetChild("BoogieStatsLogo")
	local bsExBox = scoreBox:GetChild("BoogieStatsEXLogo")
	if not (gsBox and bsBox and bsExBox) then return end

	gsBox:stopeffect()
	if boogie then
		style_color[0] = BoogieStatsPurple
		style_color[1] = BoogieStatsPurple
		bsBox:visible(true)
		bsExBox:visible(false)
		gsBox:visible(false)
	else
		style_color[0] = GrooveStatsBlue
		bsBox:visible(false)
		bsExBox:visible(false)
		gsBox:visible(true)
	end
	

	-- First check to see if the leaderboard even exists.
	if data and data[playerStr] then
		if SL[pn].Streams.Hash ~= data[playerStr]["chartHash"] then return end
		currentHash = SL[pn].Streams.Hash
		-- These will get overwritten if we have any entries in the leaderboard below.
		SetScoreData(1, 1, "", "No Scores", "", false, false, false, false)
		SetScoreData(2, 1, "", "No Scores", "", false, false, false, false)

		all_data[1].has_data = false
		all_data[2].has_data = false

		local showITG = SL["P"..n].ActiveModifiers.SBITGScore
		local showEX = SL["P"..n].ActiveModifiers.SBExScore
		local showEvents = SL["P"..n].ActiveModifiers.SBEvents

		local numEntries = 0
		if SL["P"..n].ActiveModifiers.ShowExScore then
			-- If the player is using EX scoring, then we want to display the EX leaderboard first.		
			if showEX then
				if data[playerStr]["exLeaderboard"] then
					local added = {}
					numEntries = 0
					for entry in ivalues(data[playerStr]["exLeaderboard"]) do
						if not added[entry["name"]] then
							added[entry["name"]] = true
							numEntries = numEntries + 1
							SetScoreData(1, numEntries,
											tostring(entry["rank"]),
											entry["name"],
											string.format("%.2f", entry["score"]/100),
											entry["isSelf"],
											entry["isRival"],
											entry["isFail"],
											true
										)
						end
					end
					numEntries = numEntries + 1
					for i=math.max(2,numEntries),NumEntries,1 do
						SetScoreData(1, i, "", "", "", "", "", "", true)
					end
				end
			end
			if all_data[1].has_data then AppendStyle(0) end

			if showITG then
				if data[playerStr]["gsLeaderboard"] then
					numEntries = 0
					local added = {}
					for entry in ivalues(data[playerStr]["gsLeaderboard"]) do
						if not added[entry["name"]] then
							added[entry["name"]] = true
							numEntries = numEntries + 1
							SetScoreData(2, numEntries,
											tostring(entry["rank"]),
											entry["name"],
											string.format("%.2f", entry["score"]/100),
											entry["isSelf"],
											entry["isRival"],
											entry["isFail"],
											boogie_ex
										)
						end
					end
					numEntries = numEntries + 1
					for i=math.max(2,numEntries),NumEntries,1 do
						SetScoreData(2, i, "", "", "", "", "", "", boogie_ex)
					end
				end
			end
			if all_data[2].has_data then AppendStyle(1) end
		else
			-- Display the main GrooveStats leaderboard first if player is not using EX scoring.
			if showITG then
				if data[playerStr]["gsLeaderboard"] then
					numEntries = 0
					local added = {}
					for entry in ivalues(data[playerStr]["gsLeaderboard"]) do
						if not added[entry["name"]] then
							added[entry["name"]] = true
							numEntries = numEntries + 1
							SetScoreData(1, numEntries,
											tostring(entry["rank"]),
											entry["name"],
											string.format("%.2f", entry["score"]/100),
											entry["isSelf"],
											entry["isRival"],
											entry["isFail"],
											boogie_ex
										)
						end
					end
					numEntries = numEntries + 1
					for i=math.max(2,numEntries),NumEntries,1 do
						SetScoreData(1, i, "", "", "", "", "", "", boogie_ex)
					end
				end
			end
			if all_data[1].has_data then AppendStyle(0) end

			if showEX then
				if data[playerStr]["exLeaderboard"] then
					numEntries = 0
					local added = {}
					for entry in ivalues(data[playerStr]["exLeaderboard"]) do
						if not added[entry["name"]] then
							added[entry["name"]] = true
							numEntries = numEntries + 1
							SetScoreData(2, numEntries,
											tostring(entry["rank"]),
											entry["name"],
											string.format("%.2f", entry["score"]/100),
											entry["isSelf"],
											entry["isRival"],
											entry["isFail"],
											true
										)
						end
					end
					numEntries = numEntries + 1
					for i=math.max(2,numEntries),NumEntries,1 do
						SetScoreData(2, i, "", "", "", "", "", "", true)
					end
				end
			end
			if all_data[2].has_data then AppendStyle(1) end
		end

		-- Display event boxes first if they are applicable
		if showEvents then
			if data[playerStr]["rpg"] then
				local numEntries = 0
				local added = {}
				SetScoreData(3, 1, "", "No Scores", "", false, false, false)

				if data[playerStr]["rpg"]["rpgLeaderboard"] then
					for entry in ivalues(data[playerStr]["rpg"]["rpgLeaderboard"]) do
						if not added[entry["name"]] then
							added[entry["name"]] = true
							numEntries = numEntries + 1
							SetScoreData(3, numEntries,
											tostring(entry["rank"]),
											entry["name"],
											string.format("%.2f", entry["score"]/100),
											entry["isSelf"],
											entry["isRival"],
											entry["isFail"],
											false
										)
						end
					end
					numEntries = numEntries + 1
					for i=numEntries,NumEntries,1 do
						SetScoreData(3, i,
										"",
										"",
										"",
										false,
										false,
										false)
					end
				end
			end
			if all_data[3].has_data then AppendStyle(2) end

			if data[playerStr]["itl"] then
				local numEntries = 0
				local added = {}
				SetScoreData(4, 1, "", "No Scores", "", false, false, false)

				if data[playerStr]["itl"]["itlLeaderboard"] then
					for entry in ivalues(data[playerStr]["itl"]["itlLeaderboard"]) do
						if not added[entry["name"]] then
							added[entry["name"]] = true
							if entry["isSelf"] then
								UpdateItlExScore(player, SL[pn].Streams.Hash, entry["score"])
								SL["P"..n].itlScore = entry["score"]
							end
							numEntries = numEntries + 1
							SetScoreData(4, numEntries,
											tostring(entry["rank"]),
											entry["name"],
											string.format("%.2f", entry["score"]/100),
											entry["isSelf"],
											entry["isRival"],
											entry["isFail"],
											true
										)
						end
					end
					numEntries = numEntries + 1
					for i=numEntries,NumEntries,1 do
						SetScoreData(4, i,
										"",
										"",
										"",
										false,
										false,
										false)
					end
				end
			end
			if all_data[4].has_data then AppendStyle(3) end
		end
 	end
	pendingRequests = pendingRequests - 1
	if not firstResponseHandled and master ~= nil then
		firstResponseHandled = true
		master:queuecommand("CheckScorebox")
	end
end

-- ArrowCloud integration --------------------------------------------------

-- Maps ArrowCloud leaderboard types to style indices (5..7 into all_data, 1-based).
local AcIndexMap = { ITG = 5, EX = 6, HardEX = 7 }

-- Puts the same placeholder text/style into all 3 AC slots and appends them to the
-- rotation - used both for actual failures (HTTP error, timeout, bad/missing body)
-- and for a well-formed response with no data yet. We used to just return on these
-- cases and leave the box with nothing to show at all - since AC is the primary/
-- expected-fast source, a chart with no usable response would go from spinner to
-- completely empty with no explanation (looked like "the leaderboard never even
-- tries to load"). GrooveStats already shows a "No Scores" pane in the equivalent
-- case; do the same here instead of silence.
local function ShowArrowCloudFailure(text)
	for _, style_index in pairs(AcIndexMap) do
		if all_data[style_index] then
			local isExType = style_index ~= 5
			SetScoreData(style_index, 1, "", text, "", false, false, false, isExType)
			for i=2, NumEntries do
				SetScoreData(style_index, i, "", "", "", false, false, false, isExType)
			end
			AppendStyle(style_index - 1)
		end
	end
end

-- `context` is a short "song=... hash=..." string (built by the caller, which has
-- the song title/hash in scope) so log lines can actually be correlated to a
-- specific chart - the earlier version of this logging only showed statusCode/error
-- with no way to tell which song a given line was for.
local ArrowCloudRequestProcessor = function(res, context)
	if not res then return end
	local ctx = context or "?"

	if res.error then
		local error = ToEnumShortString(res.error)
		Trace("[Scorebox][AC] "..ctx.." FAILED network error="..tostring(error))
		ShowArrowCloudFailure(error == "Timeout" and "Timed Out" or "Failed to Load 😞")
		return
	end
	if res.statusCode ~= 200 then
		Trace("[Scorebox][AC] "..ctx.." FAILED statusCode="..tostring(res.statusCode))
		ShowArrowCloudFailure("Failed to Load 😞")
		return
	end
	if not res.body or #res.body == 0 then
		Trace("[Scorebox][AC] "..ctx.." FAILED empty body")
		ShowArrowCloudFailure("Failed to Load 😞")
		return
	end
	local ok, parsed = pcall(JsonDecode, res.body)
	if not ok then
		Trace("[Scorebox][AC] "..ctx.." FAILED JSON decode error: "..tostring(parsed))
		ShowArrowCloudFailure("Failed to Load 😞")
		return
	end
	if type(parsed) ~= "table" or type(parsed.leaderboards) ~= "table" then
		Trace("[Scorebox][AC] "..ctx.." FAILED unexpected body shape, first 200 chars: "..tostring(res.body):sub(1,200))
		ShowArrowCloudFailure("Failed to Load 😞")
		return
	end

	-- We append to the rotation order in the same sequence parsed.leaderboards lists
	-- them, so the pane reflects the order ArrowCloud itself chose to return them in.
	local boardsSeen = 0
	for _, board in ipairs(parsed.leaderboards) do
		local style_index = AcIndexMap[board.type]
		if style_index and all_data[style_index] then
			boardsSeen = boardsSeen + 1
			local isExType = (board.type == "EX" or board.type == "HardEX")
			local slot = 1
			local any = false
			if type(board.scores) == "table" then
				for _, entry in ipairs(board.scores) do
					if slot > NumEntries then break end
					any = true
					local rank = tostring(entry.rank or "")
					local name = tostring(entry.alias or "--")
					local score = tostring(entry.score or "")
					local isSelf = not not entry.isSelf
					local isRival = not not entry.isRival
					-- ArrowCloud scores are already formatted server-side; pass through.
					SetScoreData(style_index, slot, rank, name, score, isSelf, isRival, false, isExType)
					slot = slot + 1
				end
			end
			if not any then
				-- Present but empty leaderboard -> show No Scores
				SetScoreData(style_index, 1, "", "No Scores", "", false, false, false, isExType)
				slot = 2
			end
			for i=slot, NumEntries do
				SetScoreData(style_index, i, "", "", "", false, false, false, isExType)
			end
			AppendStyle(style_index - 1)
		end
	end

	if boardsSeen == 0 then
		-- A well-formed 200 response with no matching boards at all (as opposed to
		-- a board that's present but has zero scores, handled above) - a chart
		-- ArrowCloud genuinely has no data for yet. GrooveStats shows a pane with
		-- "No Scores" rather than nothing in the equivalent case, so do the same
		-- here instead of leaving the box blank with no explanation.
		ShowArrowCloudFailure("No Scores Yet")
	end
end

local af = Def.ActorFrame{
	Name="ScoreBox"..pn,
	InitCommand=function(self)
		if #GAMESTATE:GetHumanPlayers() == 1 then
			self:x(_screen.cx + 80):y(_screen.cy + 160 + yShift)
			if pn == "P2" then
				self:y(_screen.cy*1.65 - 55 + yShift)
			end
		else
			if pn == "P1" then
				self:zoom(0.65):x(_screen.cx - 65):y(_screen.cy + 178 + yShift)
				if IsNotWide then
					self:x(_screen.cx - 48)
				end
			else
				self:zoom(0.65):x(_screen.cx + 371):y(_screen.cy + 178 + yShift)
				if IsNotWide then
					self:x(_screen.cx + 279)
				end
			end
		end
		self.isFirst = true
	end,
	ResetCommand=function(self) self:stoptweening() end,
	OffCommand=function(self) self:stoptweening() end,
	PlayerJoinedMessageCommand=function(self, params)
		if pn == "P1" then
			self:zoom(0.65):x(_screen.cx - 65):y(_screen.cy + 178 + yShift)
			if IsNotWide then
				self:x(_screen.cx - 48)
			end
		else
			self:zoom(0.65):x(_screen.cx + 371):y(_screen.cy + 178 + yShift)
			if IsNotWide then
				self:x(_screen.cx + 279)
			end
		end
	end,
	PlayerUnjoinedMessageCommand=function(self, params)
		if params.Player == player then
			self:visible(false)
		end
		self:x(_screen.cx + 80):y(_screen.cy + 160 + yShift):zoom(1)
		if pn == "P2" then
			self:y(_screen.cy*1.65 - 55 + yShift)
		end
	end,
	CurrentSongChangedMessageCommand=function(self)
		self:finishtweening():visible(false)
		self.isFirst = true
	end,
	CheckScoreboxCommand=function(self)
		if GAMESTATE:GetCurrentSong() and GAMESTATE:GetCurrentSteps(player) then
			self:queuecommand("LoopScorebox")
		end
	end,
	LoopScoreboxCommand=function(self)
		self:visible(true)

		if #styleOrder == 0 then return end

		self:finishtweening()

		-- On first display, use zero animation time so content appears instantly.
		anim_seconds = self.isFirst and 0 or transition_seconds

		-- Walk styleOrder in the order styles actually became available (see its
		-- declaration above), rather than a fixed 0..6 sweep. This is what makes the
		-- first-shown style consistently "whichever responded first" (normally AC)
		-- instead of racing whichever response processor happened to run last.
		if self.isFirst then
			self.isFirst = false
			self.orderPos = 1
		else
			self.orderPos = (self.orderPos % #styleOrder) + 1
		end
		cur_style = styleOrder[self.orderPos]

		for i=1,NumEntries do
			local show = (i <= RowsForStyle(cur_style))
			self:GetChild("Name"..i):visible(show)
			self:GetChild("Score"..i):visible(show)
			self:GetChild("Rank"..i):visible(show)
		end
		self:GetChild("BoogieStatsLogo"):stopeffect()
		self:GetChild("BoogieStatsEXLogo"):stopeffect()
		self:GetChild("SRPGLogo"):visible(true)
		self:GetChild("ITLLogo"):visible(true)
    self:GetChild("ACLogo"):visible(true)
    self:GetChild("ACModeLabel"):visible(true)
		self:GetChild("Outline"):visible(true)
		self:GetChild("Background"):linear(anim_seconds/2):diffusealpha(1):visible(true)

		-- Keep rotating if there's more than one style to show, or if another
		-- service (typically GS) might still append more styles once it responds -
		-- that way this loop picks up newly-available styles on its own next tick
		-- rather than needing an external re-trigger.
		if #styleOrder > 1 or pendingRequests > 0 then
			self:sleep(loop_seconds):queuecommand("LoopScorebox")
		end
	end,

	RequestResponseActor(0, 0)..{
		OnCommand=function(self)
			self:queuecommand("MakeRequest")
			-- Create variables for both players, even if they're not currently active.
			self.IsParsing = {false, false}
		end,
		-- Broadcasted from ./PerPlayer/DensityGraph.lua
		P1ChartParsingMessageCommand=function(self)	self.IsParsing[1] = true end,
		P2ChartParsingMessageCommand=function(self)	self.IsParsing[2] = true end,
		P1ChartParsedMessageCommand=function(self)
			self.IsParsing[1] = false
			if pn == "P1" then
				self:queuecommand("ChartParsed")
			end
		end,
		P2ChartParsedMessageCommand=function(self)
			self.IsParsing[2] = false
			if pn == "P2" then
				self:queuecommand("ChartParsed")
			end
		end,
		ChartParsedMessageCommand=function(self)
			if not self.leaving_screen then
				self:queuecommand("MakeRequest")
			end
		end,
		MakeRequestCommand=function(self)
			-- Section/group headers in the wheel (e.g. hovering a series name when
			-- sorted by series) have no current song - GAMESTATE:GetCurrentSteps can
			-- still report stale data from whatever song was last actually selected,
			-- which would otherwise cause this to spuriously re-fire and flash the
			-- loading indicator while just browsing folder headers. Bail out entirely
			-- unless a real song is currently selected.
			if not GAMESTATE:GetCurrentSong() then
				self:GetParent():finishtweening():visible(false)
				return
			end
			local songTitle = GAMESTATE:GetCurrentSong():GetDisplayFullTitle()

			local sendRequest = false
			local headers = {}
			-- GrooveStats remains at 5 results regardless of AC's 7
			local query = {
				maxLeaderboardResults=GS_ROWS,
			}

			-- Don't even ask GrooveStats for leaderboards when the player has it
			-- hidden - previously we still fired the request (and kept the loading
			-- spinner going for it) even though its results would never be shown.
			if not hideGrooveStats and SL[pn].ApiKey ~= "" and SL[pn].Streams.Hash ~= "" then
				query["chartHashP"..n] = SL[pn].Streams.Hash
				headers["x-api-key-player-"..n] = SL[pn].ApiKey
				sendRequest = true
			end

			-- We technically will send two requests in ultrawide versus mode since
			-- both players will have their own individual scoreboxes.
			-- Should be fine though.
			-- Break ArrowCloud readiness into explicit booleans so the final value is never nil.
			local acEnabled = (SL.ArrowCloud and SL.ArrowCloud.Enabled) or false
			local acKey = (SL[pn] and SL[pn].ArrowCloudApiKey and #SL[pn].ArrowCloudApiKey > 0) or false
			local acHash = (SL[pn] and SL[pn].Streams and SL[pn].Streams.Hash and #SL[pn].Streams.Hash > 0) or false
			-- ComputeChartHash (SL-ChartParser.lua) always updates Streams.Filename once
			-- it has actually run for the current chart, even when it couldn't produce a
			-- hash (some charts fail to parse - GetSimfileString/GetSimfileChartString
			-- returning nil - and it silently leaves Hash as ""). If Filename matches the
			-- currently selected steps, hashing was genuinely attempted and failed, as
			-- opposed to just not having settled yet after the wheel-scroll debounce.
			local currentSteps = GAMESTATE:GetCurrentSteps(player)
			local hashFailed = (not acHash) and currentSteps and SL[pn].Streams.Filename == currentSteps:GetFilename()
			local willDoArrowCloud = acEnabled and acKey and (acHash or hashFailed)
			if sendRequest or willDoArrowCloud then
				if self.IsParsing[1] or self.IsParsing[2] then return end
				if currentHash == SL[pn].Streams.Hash and not willDoArrowCloud then
					self:GetParent():visible(true)
					self:GetParent():queuecommand("CheckScorebox")
					return
				end

				-- pendingRequests just tracks how many services are still in flight (for
				-- debugging/bookkeeping); the scorebox itself is shown as soon as the
				-- first response (GS or AC, whichever answers first) has data - see
				-- firstResponseHandled below.
				pendingRequests = 0
				gsPending = sendRequest
				firstResponseHandled = false
				requestGeneration = requestGeneration + 1
				local myGeneration = requestGeneration
				if willDoArrowCloud then pendingRequests = pendingRequests + 1 end
				if sendRequest then pendingRequests = pendingRequests + 1 end

				-- ArrowCloud direct request (independent of GS). We perform a separate HTTP call.
						if willDoArrowCloud then
					local ach = SL[pn].Streams.Hash
					local acContext = "song=\""..tostring(songTitle).."\" hash="..tostring(ach)

					if hashFailed then
						-- This chart's hash could never be computed (see hashFailed's
						-- declaration above) - there's no hash to request a leaderboard
						-- with. Showing the explanation has to be deferred (like the
						-- watchdog below) rather than done inline here: ResetAllData()
						-- runs unconditionally right after this block and would
						-- immediately wipe out anything set synchronously.
						Trace("[Scorebox][AC] "..acContext.." SKIPPED - chart hash could not be computed")
						self.hashFailedGeneration = myGeneration
						self.hashFailedContext = acContext
						self:queuecommand("ArrowCloudHashFailed")
					else
						local acHeaders = {}
						acHeaders["Authorization"] = "Bearer " .. SL[pn].ArrowCloudApiKey
						-- ArrowCloud HTTP request
						NETWORK:HttpRequest{
							url = SL.ArrowCloud.BaseURL .. "/v1/chart/" .. ach .. "/leaderboards",
							method = "GET",
							headers = acHeaders,
							connectTimeout = SL.ArrowCloud.RequestTimeout,
							transferTimeout = SL.ArrowCloud.RequestTimeout,
							onResponse = function(acres)
								-- Discard if we've since moved on to a different chart - see
								-- requestGeneration's declaration above.
								if myGeneration ~= requestGeneration then
									Trace("[Scorebox][AC] "..acContext.." response arrived but generation is stale, discarding")
									return
								end
								ArrowCloudRequestProcessor(acres, acContext)
								pendingRequests = pendingRequests - 1
								if not firstResponseHandled then
									firstResponseHandled = true
									self:GetParent():queuecommand("CheckScorebox")
								end
							end
						}
						-- Safety net: if the engine's connect/transferTimeout doesn't
						-- actually fire onResponse (observed as the box getting stuck on
						-- the loading spinner indefinitely for specific charts, likely
						-- related to the engine only dispatching one HTTP request at a
						-- time under rapid navigation), give up after a bit longer than
						-- the request's own timeout instead of spinning forever.
						self.acWatchdogGeneration = myGeneration
						self.acWatchdogContext = acContext
						self:sleep((SL.ArrowCloud.RequestTimeout or 5) + 3):queuecommand("ArrowCloudWatchdog")
					end
				end
				
				RemoveStaleCachedRequests()
				ResetAllData()
				
				self:GetParent():visible(true)
				for i=1,NumEntries do
					local parent = self:GetParent()
					parent:GetChild("Name"..i):settext(""):visible(false)
					parent:GetChild("Score"..i):settext(""):visible(false)
					local rankChild = parent:GetChild("Rank"..i)
					if rankChild then
						if i == 1 then
							-- Crown sprite: no settext
							rankChild:diffusealpha(0):visible(false)
						else
							rankChild:settext(""):visible(false)
						end
					end
				end
				-- The loading indicator - both the initial "nothing has responded yet"
				-- state and "GS specifically is still catching up" once AC data is
				-- already showing (see gsPending in the master LoopScoreboxCommand) -
				-- is the generic spinner, not the GrooveStats logo. GrooveStatsLogo
				-- itself is only shown later, as the watermark for actual GS data in
				-- the rotation (its own LoopScoreboxCommand).
				self:GetParent():GetChild("LoadingSpinner"):visible(true)
				self:GetParent():GetChild("GrooveStatsLogo"):visible(false)
				self:GetParent():GetChild("BoogieStatsLogo"):visible(false)
				self:GetParent():GetChild("BoogieStatsEXLogo"):visible(false)
				self:GetParent():GetChild("SRPGLogo"):diffusealpha(0):visible(false)
				self:GetParent():GetChild("ITLLogo"):diffusealpha(0):visible(false)
				self:GetParent():GetChild("ACLogo"):diffusealpha(0):visible(false)
				self:GetParent():GetChild("ACModeLabel"):diffusealpha(0):visible(false)
				self:GetParent():GetChild("Outline"):diffusealpha(0):visible(false)
				self:GetParent():GetChild("Background"):diffusealpha(0):visible(false)
				
				if IsItlSong(player) then
					UpdatePathMap(player, SL[pn].Streams.Hash)
				end
				
				ResetAllData()
				if sendRequest then
					-- GS HTTP request
					self:playcommand("MakeGrooveStatsRequest", {
						endpoint="?action=playerLeaderboards&"..NETWORK:EncodeQueryParameters(query),
						method="GET",
						headers=headers,
						timeout=10,
						callback=LeaderboardRequestProcessor,
						args={parent=self:GetParent(), generation=myGeneration},
					})
				end
			end
		end,
	ArrowCloudWatchdogCommand=function(self)
		-- See the sleep/queuecommand scheduled right after the ArrowCloud HttpRequest
		-- in MakeRequestCommand. If this generation's request never resolved
		-- (onResponse simply never called - not even with an error), treat it the
		-- same as an error response instead of leaving the box on the loading
		-- spinner forever.
		if self.acWatchdogGeneration ~= requestGeneration then return end
		if firstResponseHandled then return end
		Trace("[Scorebox][AC] "..tostring(self.acWatchdogContext).." WATCHDOG FIRED - request never resolved, giving up")
		ShowArrowCloudFailure("Failed to Load 😞")
		pendingRequests = math.max(0, pendingRequests - 1)
		firstResponseHandled = true
		self:GetParent():queuecommand("CheckScorebox")
	end,
	-- Deferred from the hashFailed branch in MakeRequestCommand - see the comment
	-- there. Runs after ResetAllData() has already happened for this request cycle.
	ArrowCloudHashFailedCommand=function(self)
		if self.hashFailedGeneration ~= requestGeneration then return end
		ShowArrowCloudFailure("Chart Unsupported")
		pendingRequests = math.max(0, pendingRequests - 1)
		if not firstResponseHandled then
			firstResponseHandled = true
			self:GetParent():queuecommand("CheckScorebox")
		end
	end,
	},

	-- Outline
	Def.Quad{
		Name="Outline",
		InitCommand=function(self)
			self:diffuse(GrooveStatsBlue):setsize(width + border, height + border)
			if IsNotWide and #GAMESTATE:GetHumanPlayers() > 1 then
				self:setsize(width + border - 40, height + border)
			end
		end,
		PlayerJoinedMessageCommand=function(self,params)
			if IsNotWide then
				self:setsize(width + border - 40, height + border)
			else
				self:setsize(width + border, height + border)
			end
		end,
		PlayerUnjoinedMessageCommand=function(self,params)
			self:setsize(width + border, height + border)
		end,
		LoopScoreboxCommand=function(self)
			self:linear(anim_seconds):diffuse(style_color[cur_style])
		end,
		ResetCommand=function(self) self:stoptweening() end,
		OffCommand=function(self) self:stoptweening() end
	},
	-- Main body
	Def.Quad{
		Name="Background",
		InitCommand=function(self)
			self:diffuse(color("#000000")):setsize(width, height)
			if IsNotWide and #GAMESTATE:GetHumanPlayers() > 1 then
				self:setsize(width - 40, height)
			end
		end,
		PlayerJoinedMessageCommand=function(self,params)
			if IsNotWide then
				self:setsize(width - 40, height)
			else
				self:setsize(width, height)
			end
		end,
		PlayerUnjoinedMessageCommand=function(self,params)
			self:setsize(width, height)
		end,
	},
	-- GrooveStats Logo
	Def.Sprite{
		Texture=THEME:GetPathG("", "GrooveStats.png"),
		Name="GrooveStatsLogo",
		InitCommand=function(self)
			self:zoom(0.8):diffusealpha(0.5)
		end,
		LoopScoreboxCommand=function(self)
			if cur_style == 0 or cur_style == 1 then
				self:sleep(anim_seconds/2):linear(anim_seconds/2):diffusealpha(0.5)
			else
				self:linear(anim_seconds/2):diffusealpha(0)
			end
		end,
		ResetCommand=function(self) self:stoptweening() end,
		OffCommand=function(self) self:stoptweening():stopeffect() end
	},
	-- BoogieStats Logo
	Def.Sprite{
		Texture=THEME:GetPathG("", "BoogieStats.png"),
		Name="BoogieStatsLogo",
		InitCommand=function(self)
			self:zoom(0.8):diffusealpha(0.5)
		end,
		LoopScoreboxCommand=function(self)
			if cur_style == 0 or cur_style == 1 then
				self:sleep(anim_seconds/2):linear(anim_seconds/2):diffusealpha(0.5)
			else
				self:linear(anim_seconds/2):diffusealpha(0)
			end
		end,
		ResetCommand=function(self) self:stoptweening() end,
		OffCommand=function(self) self:stoptweening():stopeffect() end
	},
	-- BoogieStats EX Logo
	Def.Sprite{
		Texture=THEME:GetPathG("", "BoogieStatsEX.png"),
		Name="BoogieStatsEXLogo",
		InitCommand=function(self)
			self:zoom(0.8):diffusealpha(0.5)
		end,
		LoopScoreboxCommand=function(self)
			if cur_style == 0 then
				self:sleep(anim_seconds/2):linear(anim_seconds/2):diffusealpha(0.5)
			else
				self:linear(anim_seconds/2):diffusealpha(0)
			end
		end,
		ResetCommand=function(self) self:stoptweening() end,
		OffCommand=function(self) self:stoptweening():stopeffect() end
	},
	-- EX Text
	Def.BitmapText{
		Font=ThemePrefs.Get("ThemeFont") .. " Normal",
		Text="EX",
		InitCommand=function(self)
			self:diffusealpha(0):x(2):y(-5)
		end,
		LoopScoreboxCommand=function(self)
			if (cur_style == 1 and not SL["P"..n].ActiveModifiers.ShowExScore) or (cur_style == 0 and SL["P"..n].ActiveModifiers.ShowExScore) then
				self:sleep(anim_seconds/2):linear(anim_seconds/2):diffusealpha(0.3)
			else
				self:linear(anim_seconds/2):diffusealpha(0)
			end
		end,
		ResetCommand=function(self) self:stoptweening() end,
		OffCommand=function(self) self:stoptweening():stopeffect() end
	},
	-- SRPG Logo
	Def.Sprite{
		Texture=THEME:GetPathG("", "_VisualStyles/SRPG10/logo_alt (doubleres).png"),
		Name="SRPGLogo",
		InitCommand=function(self)
			self:diffusealpha(0.4):zoom(0.07):diffusealpha(0)
		end,
		LoopScoreboxCommand=function(self)
			if cur_style == 2 then
				self:linear(anim_seconds/2):diffusealpha(0.5)
			else
				self:sleep(anim_seconds/2):linear(anim_seconds/2):diffusealpha(0)
			end
		end,
		ResetCommand=function(self) self:stoptweening() end,
		OffCommand=function(self) self:stoptweening() end
	},
	-- ITL Logo
	Def.Sprite{
		Texture=THEME:GetPathG("", "ITL.png"),
		Name="ITLLogo",
		InitCommand=function(self)
			self:diffusealpha(0.2):zoom(0.45):diffusealpha(0)
		end,
		LoopScoreboxCommand=function(self)
			if cur_style == 3 then
				self:linear(anim_seconds/2):diffusealpha(0.2)
			else
				self:sleep(anim_seconds/2):linear(anim_seconds/2):diffusealpha(0)
			end
		end,
		ResetCommand=function(self) self:stoptweening() end,
		OffCommand=function(self) self:stoptweening() end
	},

	-- ArrowCloud Logo
	Def.Sprite{
		Texture=THEME:GetPathG("", "Arrow Cloud/ac logo.png"),
		Name="ACLogo",
		InitCommand=function(self)
			-- Reduced scale (was 0.42); 0.14 approximates one-third the previous size
			self:diffusealpha(0):zoom(0.08):xy(0,0)
		end,
		LoopScoreboxCommand=function(self)
			if cur_style >= 4 then
				self:sleep(anim_seconds/2):linear(anim_seconds/2):diffusealpha(0.25)
			else
				self:linear(anim_seconds/2):diffusealpha(0)
			end
		end,
		ResetCommand=function(self) self:stoptweening() end,
		OffCommand=function(self) self:stoptweening() end
	},

	-- ArrowCloud Mode Text (bottom-right ITG / EX / H.EX)
	LoadFont(ThemePrefs.Get("ThemeFont") .. " Normal")..{
		Name="ACModeLabel",
		Text="",
		InitCommand=function(self)
			self:diffusealpha(0):zoom(1.0):horizalign(center):vertalign(middle)
			self:xy(0,0)
		end,
		LoopScoreboxCommand=function(self)
			local label = ""
			if     cur_style == 4 then label = "ITG"
			elseif cur_style == 5 then label = "EX"
			elseif cur_style == 6 then label = "H.EX" end
			if label ~= "" then
				-- Explicit colors per request
				if label == "ITG" then
					self:diffuse(SL.JudgmentColors["FA+"][2])
				elseif label == "EX" then
					self:diffuse(SL.JudgmentColors["FA+"][1])
				elseif label == "H.EX" then
					self:diffuse(SL.JudgmentColors["FA+"][7])
				end
				self:settext(label)
				self:sleep(anim_seconds/2):linear(anim_seconds/2):diffusealpha(0.65)
			else
				self:linear(anim_seconds/2):diffusealpha(0)
			end
		end,
		ResetCommand=function(self) self:stoptweening() end,
		OffCommand=function(self) self:stoptweening() end
	},

	-- Generic loading spinner, shown from the moment a request is fired until the
	-- first response (GS or AC) actually has content to display - see
	-- MakeRequestCommand. Deliberately not GrooveStats-branded since this box may
	-- be showing ArrowCloud-only results.
	Def.Sprite{
		Texture=THEME:GetPathG("", "LoadingSpinner 10x3.png"),
		Name="LoadingSpinner",
		Frames=Sprite.LinearFrames(30,1),
		InitCommand=function(self)
			self:zoom(0.15):diffuse(GetHexColor(SL.Global.ActiveColorIndex, true)):visible(false)
		end,
		VisualStyleSelectedMessageCommand=function(self)
			self:diffuse(GetHexColor(SL.Global.ActiveColorIndex, true))
		end,
		LoopScoreboxCommand=function(self)
			-- Keep spinning while GS is still in flight (it's typically much slower
			-- than AC, so the box is often already showing AC data here); hide once
			-- nothing is left pending.
			if not gsPending then
				self:visible(false)
			end
		end,
		ResetCommand=function(self) self:stoptweening() end,
		OffCommand=function(self) self:stoptweening():visible(false) end
	},
}

for i=1,NumEntries do
	local y = -height/2 + 16 * i - 8
	local zoom = 0.87

	-- Rank 1 gets a crown.
	if i == 1 then
		af[#af+1] = Def.Sprite{
			Name="Rank"..i,
			Texture=THEME:GetPathG("", "crown.png"),
			InitCommand=function(self)
				self:zoom(0.09):xy(-width/2 + 14, y):diffusealpha(0)
				if IsNotWide and #GAMESTATE:GetHumanPlayers() > 1 then
					self:x(-width/2 + 32)
				end
			end,
			PlayerJoinedMessageCommand=function(self,params)
				if IsNotWide then
					self:x(-width/2 + 32)
				else
					self:x(-width/2 + 14)
				end
			end,
			PlayerUnjoinedMessageCommand=function(self,params)
				self:x(-width/2 + 14)
			end,
			LoopScoreboxCommand=function(self)
				self:linear(anim_seconds/2):diffusealpha(0):queuecommand("SetScorebox")
			end,
			SetScoreboxCommand=function(self)
				local displayRows = RowsForStyle(cur_style)
				if i > displayRows then self:visible(false) return end
				local spacing = RowSpacingForStyle(cur_style)
				local yy = -height/2 + spacing * i - spacing/2
				self:y(yy):zoom(CrownZoomForStyle(cur_style)):visible(true)
				local score = all_data[cur_style+1]["scores"][i]
				if score.rank ~= "" then
					self:linear(anim_seconds/2):diffusealpha(1)
				else
					self:diffusealpha(0)
				end
			end,
			ResetCommand=function(self) self:stoptweening() end,
			OffCommand=function(self) self:stoptweening() end
		}
	else
		af[#af+1] = LoadFont(ThemePrefs.Get("ThemeFont") .. " Normal")..{
			Name="Rank"..i,
			Text="",
			InitCommand=function(self)
				self:diffuse(Color.White):xy(-width/2 + 27, y):maxwidth(30):horizalign(right):zoom(zoom)
				if IsNotWide and #GAMESTATE:GetHumanPlayers() > 1 then
					self:x(-width/2 + 42)
				end
			end,
			PlayerJoinedMessageCommand=function(self,params)
				if IsNotWide then
					self:x(-width/2 + 42)
				else
					self:x(-width/2 + 27)
				end
			end,
			PlayerUnjoinedMessageCommand=function(self,params)
				self:x(-width/2 + 27)
			end,
			LoopScoreboxCommand=function(self)
				self:linear(anim_seconds/2):diffusealpha(0):queuecommand("SetScorebox")
			end,
			SetScoreboxCommand=function(self)
				local displayRows = RowsForStyle(cur_style)
				if i > displayRows then self:visible(false) return end
				local spacing = RowSpacingForStyle(cur_style)
				local yy = -height/2 + spacing * i - spacing/2
				self:y(yy):zoom(TextZoomForStyle(cur_style)):visible(true)
				local score = all_data[cur_style+1]["scores"][i]
				local clr = Color.White
				if score.isSelf then
					clr = self_color
				elseif score.isRival then
					clr = rival_color
				end
				self:settext(score.rank)
				self:linear(anim_seconds/2):diffusealpha(1):diffuse(clr)
			end,
			ResetCommand=function(self) self:stoptweening() end,
			OffCommand=function(self) self:stoptweening() end
		}
	end

	af[#af+1] = LoadFont(ThemePrefs.Get("ThemeFont") .. " Normal")..{
		Name="Name"..i,
		Text="",
		InitCommand=function(self)
			self:diffuse(Color.White):xy(-width/2 + 30, y):maxwidth(100):horizalign(left):zoom(zoom)
			if IsNotWide and #GAMESTATE:GetHumanPlayers() > 1 then
				self:x(-width/2 + 45):maxwidth(70)
			end
		end,
		PlayerJoinedMessageCommand=function(self,params)
			if IsNotWide then
				self:x(-width/2 + 45):maxwidth(70)
			else
				self:x(-width/2 + 30):maxwidth(100)
			end
		end,
		PlayerUnjoinedMessageCommand=function(self,params)
			self:x(-width/2 + 30):maxwidth(100)
		end,
		LoopScoreboxCommand=function(self)
			self:linear(anim_seconds/2):diffusealpha(0):queuecommand("SetScorebox")
		end,
		SetScoreboxCommand=function(self)
			local displayRows = RowsForStyle(cur_style)
			if i > displayRows then self:visible(false) return end
			local spacing = RowSpacingForStyle(cur_style)
			local yy = -height/2 + spacing * i - spacing/2
			self:y(yy):zoom(TextZoomForStyle(cur_style)):visible(true)
			local score = all_data[cur_style+1]["scores"][i]
			local clr = Color.White
			if score.isSelf then
				clr = self_color
			elseif score.isRival then
				clr = rival_color
			end
			self:settext(score.name)
			self:linear(anim_seconds/2):diffusealpha(1):diffuse(clr)
		end,
		ResetCommand=function(self) self:stoptweening() end,
		OffCommand=function(self) self:stoptweening() end
	}

	af[#af+1] = LoadFont(ThemePrefs.Get("ThemeFont") .. " Normal")..{
		Name="Score"..i,
		Text="",
		InitCommand=function(self)
			self:diffuse(Color.White):xy(-width/2 + 160, y):horizalign(right):zoom(zoom)
			if IsNotWide and #GAMESTATE:GetHumanPlayers() > 1 then
				self:x(-width/2 + 140)
			end
		end,
		PlayerJoinedMessageCommand=function(self,params)
			if IsNotWide then
				self:x(-width/2 + 140)
			else
				self:x(-width/2 + 160)
			end
		end,
		PlayerUnjoinedMessageCommand=function(self,params)
			self:x(-width/2 + 160)
		end,
		LoopScoreboxCommand=function(self)
			self:linear(anim_seconds/2):diffusealpha(0):queuecommand("SetScorebox")
		end,
		SetScoreboxCommand=function(self)
			local displayRows = RowsForStyle(cur_style)
			if i > displayRows then self:visible(false) return end
			local spacing = RowSpacingForStyle(cur_style)
			local yy = -height/2 + spacing * i - spacing/2
			self:y(yy):zoom(TextZoomForStyle(cur_style)):visible(true)
			local score = all_data[cur_style+1]["scores"][i]
			local clr = Color.White
			if score.isFail then
				clr = Color.Red
			elseif cur_style == 6 then
				-- HardEX pane: render scores in pink
				clr = SL.JudgmentColors["FA+"][7]
			elseif score.isEx then
				-- EX scoring (non-HardEX) in red
				clr = SL.JudgmentColors["FA+"][1]
			elseif score.isSelf then
				clr = self_color
			elseif score.isRival then
				clr = rival_color
			end
			self:settext(score.score)
			self:linear(anim_seconds/2):diffusealpha(1):diffuse(clr)
		end,
		ResetCommand=function(self) self:stoptweening() end,
		OffCommand=function(self) self:stoptweening() end
	}
end
return af
