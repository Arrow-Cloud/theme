-- Arrow Cloud Leaderboard overlay (accessed from SortMenu)
-- Modelled after Leaderboard.lua (GrooveStats) but uses the ArrowCloud API directly.

local NumEntries = 15
local RowHeight = 20

-- Score type colors matching the scorebox display
local function getLeaderboardTypeColor(typeLabel)
	if not typeLabel then return Color.White end
	local t = typeLabel:upper()
	if t == "HARDEX" or t == "H.EX" then
		return color("#ff00cc")
	elseif t == "EX" then
		local c = SL and SL.JudgmentColors and SL.JudgmentColors["ITG"] and SL.JudgmentColors["ITG"][1]
		return c or color("#21CCE8")
	else
		return Color.White
	end
end

local SetEntryText = function(rank, name, score, date, actor)
	if actor == nil then return end
	actor:GetChild("Rank"):settext(rank)
	actor:GetChild("Name"):settext(name)
	actor:GetChild("Score"):settext(score)
	actor:GetChild("Date"):settext(date)
end

local SetLeaderboardForPlayer = function(player_num, leaderboard, leaderboardData)
	if leaderboard == nil or leaderboardData == nil then return end
	local entryNum = 1
	local rivalNum = 1

	-- Hide self and rival highlights; will be repositioned below
	leaderboard:GetChild("Self"):visible(false)
	for i=1,3 do
		leaderboard:GetChild("Rival"..i):visible(false)
	end

	-- Header
	if leaderboardData["Name"] then
		leaderboard:GetChild("Header"):settext(leaderboardData["Name"])
	end

	-- Show/hide type badge
	local typeBadge = leaderboard:GetChild("TypeBadge")
	if typeBadge then
		if leaderboardData["TypeLabel"] then
			typeBadge:settext(leaderboardData["TypeLabel"]):visible(true)
		else
			typeBadge:visible(false)
		end
	end

	if leaderboardData["Data"] then
		local scoreColor = getLeaderboardTypeColor(leaderboardData["TypeLabel"])
		for _, entry in ipairs(leaderboardData["Data"]) do
			if entryNum > NumEntries then break end
			local row = leaderboard:GetChild("LeaderboardEntry"..entryNum)
			SetEntryText(
				entry["rank"] and (entry["rank"]..".") or "",
				entry["name"] or "",
				entry["score"] or "",
				entry["date"] or "",
				row
			)
			if entry["isSelf"] then
				row:GetChild("Rank"):diffuse(Color.Black)
				row:GetChild("Name"):diffuse(Color.Black)
				row:GetChild("Score"):diffuse(Color.Black)
				row:GetChild("Date"):diffuse(Color.Black)
				leaderboard:GetChild("Self"):y(row:GetY()):visible(true)
			elseif entry["isRival"] and rivalNum <= 3 then
				row:GetChild("Rank"):diffuse(Color.Black)
				row:GetChild("Name"):diffuse(Color.Black)
				row:GetChild("Score"):diffuse(Color.Black)
				row:GetChild("Date"):diffuse(Color.Black)
				leaderboard:GetChild("Rival"..rivalNum):y(row:GetY()):visible(true)
				rivalNum = rivalNum + 1
			else
				row:GetChild("Rank"):diffuse(Color.White)
				row:GetChild("Name"):diffuse(Color.White)
				row:GetChild("Score"):diffuse(scoreColor)
				row:GetChild("Date"):diffuse(Color.White)
			end
			entryNum = entryNum + 1
		end
	end

	-- Empty remaining rows
	for i=entryNum, NumEntries do
		local row = leaderboard:GetChild("LeaderboardEntry"..i)
		if i == 1 then
			SetEntryText("", "No Scores", "", "", row)
		else
			SetEntryText("", "", "", "", row)
		end
	end
end

-- Process the ArrowCloud /v1/chart/{hash}/leaderboards response
local ACLeaderboardRequestProcessor = function(res, master)
	if master == nil then return end

	if not res or (res.statusCode ~= 200) then
		local text = "Failed to Load"
		if res and res.statusCode == 0 then text = "Offline" end
		for i=1, 2 do
			local pn = "P"..i
			local leaderboard = master:GetChild(pn.."ACLeaderboard")
			for j=1, NumEntries do
				local entry = leaderboard:GetChild("LeaderboardEntry"..j)
				if j == 1 then
					SetEntryText("", text, "", "", entry)
				else
					SetEntryText("", "", "", "", entry)
				end
			end
		end
		return
	end

	local ok, parsed = pcall(JsonDecode, res.body)
	if not ok or type(parsed) ~= "table" or type(parsed.leaderboards) ~= "table" then
		for i=1, 2 do
			local pn = "P"..i
			local leaderboard = master:GetChild(pn.."ACLeaderboard")
			SetEntryText("", "Failed to Load", "", "", leaderboard:GetChild("LeaderboardEntry1"))
			for j=2, NumEntries do
				SetEntryText("", "", "", "", leaderboard:GetChild("LeaderboardEntry"..j))
			end
		end
		return
	end

	-- Build leaderboard list from response
	local boards = parsed.leaderboards
	for i=1, 2 do
		local pn = "P"..i
		local leaderboard = master:GetChild(pn.."ACLeaderboard")
		local leaderboardList = master[pn]["Leaderboards"]

		for _, board in ipairs(boards) do
			local boardType = board.type or "Unknown"
			local entries = {}
			if type(board.scores) == "table" then
				for _, s in ipairs(board.scores) do
					if s and (s.rank or s.alias or s.userAlias or s.score) then
						entries[#entries+1] = {
							rank = s.rank,
							name = s.alias or s.userAlias or "--",
							score = tostring(s.score or ""),
							date = "",
							isSelf = not not s.isSelf,
							isRival = not not s.isRival,
						}
					end
				end
			end
			leaderboardList[#leaderboardList+1] = {
				Name = "Arrow Cloud",
				TypeLabel = boardType,
				Data = entries,
			}
		end

		if #leaderboardList > 0 then
			master[pn]["LeaderboardIndex"] = 1
			if #leaderboardList > 1 then
				leaderboard:GetChild("PaneIcons"):visible(true)
			end
			SetLeaderboardForPlayer(i, leaderboard, leaderboardList[1])
		else
			-- No leaderboards returned at all
			SetEntryText("", "No Scores", "", "", leaderboard:GetChild("LeaderboardEntry1"))
			for j=2, NumEntries do
				SetEntryText("", "", "", "", leaderboard:GetChild("LeaderboardEntry"..j))
			end
		end
	end
end

-- Colors
local ACHeaderColor = color("#2a6099")

local af = Def.ActorFrame{
	Name="ACLeaderboardMaster",
	InitCommand=function(self) self:visible(false) end,
	ShowACLeaderboardCommand=function(self)
		self:visible(true)
		for i=1, 2 do
			local pn = "P"..i
			self[pn] = {}
			self[pn].Leaderboards = {}
			self[pn].LeaderboardIndex = 0
		end
		MESSAGEMAN:Broadcast("ACResetEntry")
		self:queuecommand("SendACLeaderboardRequest")
	end,
	HideACLeaderboardCommand=function(self) self:visible(false) end,
	ACLeaderboardResponseMessageCommand=function(self, params)
		ACLeaderboardRequestProcessor(params.response, self)
	end,
	ACLeaderboardInputEventMessageCommand=function(self, event)
		local pn = ToEnumShortString(event.PlayerNumber)
		if not self[pn] or #self[pn].Leaderboards == 0 then return end

		if event.type == "InputEventType_FirstPress" then
			if event.GameButton == "MenuLeft" then
				self[pn].LeaderboardIndex = self[pn].LeaderboardIndex - 1
				if self[pn].LeaderboardIndex == 0 then
					self[pn].LeaderboardIndex = #self[pn].Leaderboards
				end
			elseif event.GameButton == "MenuRight" then
				self[pn].LeaderboardIndex = self[pn].LeaderboardIndex + 1
				if self[pn].LeaderboardIndex > #self[pn].Leaderboards then
					self[pn].LeaderboardIndex = 1
				end
			end

			if event.GameButton == "MenuLeft" or event.GameButton == "MenuRight" then
				local leaderboard = self:GetChild(pn.."ACLeaderboard")
				local leaderboardList = self[pn]["Leaderboards"]
				local leaderboardData = leaderboardList[self[pn].LeaderboardIndex]
				SetLeaderboardForPlayer("P1" == pn and 1 or 2, leaderboard, leaderboardData)
			end
		end
	end,

	-- Fullscreen dark backdrop
	Def.Quad{ InitCommand=function(self) self:FullScreen():diffuse(0,0,0,0.875) end },

	-- Dismiss instructions
	LoadFont(ThemePrefs.Get("ThemeFont") .. " Normal")..{
		Text=THEME:GetString("Common", "PopupDismissText"),
		InitCommand=function(self) self:xy(_screen.cx, _screen.h-50):zoom(1.1) end
	},

	-- Invisible actor to fire the HTTP request
	Def.Actor{
		SendACLeaderboardRequestCommand=function(self)
			local master = self:GetParent()

			-- Find a chart hash from either player
			local hash = ""
			local apiKey = ""
			for i=1, 2 do
				local pn = "P"..i
				if SL[pn] and SL[pn].Streams and SL[pn].Streams.Hash and #SL[pn].Streams.Hash > 0 then
					hash = SL[pn].Streams.Hash
				end
				if SL[pn] and SL[pn].ArrowCloudApiKey and #SL[pn].ArrowCloudApiKey > 0 then
					apiKey = SL[pn].ArrowCloudApiKey
				end
			end

			if hash == "" or apiKey == "" or not SL.ArrowCloud or not SL.ArrowCloud.Enabled then
				-- Can't make request; show error
				for i=1, 2 do
					local pn = "P"..i
					local leaderboard = master:GetChild(pn.."ACLeaderboard")
					local entry1 = leaderboard:GetChild("LeaderboardEntry1")
					if not SL.ArrowCloud or not SL.ArrowCloud.Enabled then
						SetEntryText("", "Arrow Cloud Disabled", "", "", entry1)
					elseif apiKey == "" then
						SetEntryText("", "No API Key", "", "", entry1)
					else
						SetEntryText("", "No Chart Selected", "", "", entry1)
					end
					for j=2, NumEntries do
						SetEntryText("", "", "", "", leaderboard:GetChild("LeaderboardEntry"..j))
					end
				end
				return
			end

			-- Show loading state
			for i=1, 2 do
				local pn = "P"..i
				local leaderboard = master:GetChild(pn.."ACLeaderboard")
				local entry1 = leaderboard:GetChild("LeaderboardEntry1")
				SetEntryText("", "Loading ...", "", "", entry1)
			end

			local headers = {}
			headers["Authorization"] = "Bearer " .. apiKey

			NETWORK:HttpRequest{
				url = SL.ArrowCloud.BaseURL .. "/v1/chart/" .. hash .. "/leaderboards?limit=15",
				method = "GET",
				headers = headers,
				connectTimeout = SL.ArrowCloud.RequestTimeout or 10,
				transferTimeout = SL.ArrowCloud.RequestTimeout or 10,
				onResponse = function(response)
					MESSAGEMAN:Broadcast("ACLeaderboardResponse", { response = response })
				end
			}
		end
	}
}

local paneWidth1Player = 330
local paneWidth2Player = 230
local paneWidth = (GAMESTATE:GetNumSidesJoined() == 1) and paneWidth1Player or paneWidth2Player
local paneHeight = 360
local borderWidth = 2

for player in ivalues( PlayerNumber ) do
	af[#af+1] = Def.ActorFrame{
		Name=ToEnumShortString(player).."ACLeaderboard",
		InitCommand=function(self)
			self:y(_screen.cy - 15)
			self:queuecommand("Refresh")
		end,
		PlayerJoinedMessageCommand=function(self)
			self:queuecommand("Refresh")
		end,

		RefreshCommand=function(self)
			self:visible(GAMESTATE:IsSideJoined(player))

			if GAMESTATE:GetNumSidesJoined() == 1 then
				self:xy(_screen.cx, _screen.cy - 15)
			else
				self:xy(_screen.cx + 160 * (player==PLAYER_1 and -1 or 1), _screen.cy - 15)
			end
			self:SetWidth(paneWidth)
		end,

		-- White border
		Def.Quad {
			InitCommand=function(self)
				self:diffuse(Color.White)
			end,
			RefreshCommand=function(self)
				local width = self:GetParent():GetWidth()
				self:zoomto(width + borderWidth, paneHeight + borderWidth)
			end
		},

		-- Main black body
		Def.Quad {
			InitCommand=function(self)
				self:diffuse(Color.Black)
			end,
			RefreshCommand=function(self)
				local width = self:GetParent():GetWidth()
				self:zoomto(width, paneHeight)
			end
		},

		-- Header border
		Def.Quad {
			InitCommand=function(self)
				self:diffuse(Color.White):y(-paneHeight/2 + RowHeight/2)
			end,
			RefreshCommand=function(self)
				local width = self:GetParent():GetWidth()
				self:zoomto(width + borderWidth, RowHeight + borderWidth)
			end
		},

		-- Header background (Arrow Cloud blue)
		Def.Quad {
			InitCommand=function(self)
				self:diffuse(ACHeaderColor):y(-paneHeight/2 + RowHeight/2)
			end,
			RefreshCommand=function(self)
				local width = self:GetParent():GetWidth()
				self:zoomto(width, RowHeight)
			end
		},

		-- Header Text
		LoadFont(ThemePrefs.Get("ThemeFont") .. " Normal").. {
			Name="Header",
			Text="Arrow Cloud",
			InitCommand=function(self)
				self:zoom(1.0)
				self:y(-paneHeight/2 + RowHeight/2)
			end
		},

		-- Type badge (ITG / EX / HardEX)
		LoadFont(ThemePrefs.Get("ThemeFont") .. " Normal").. {
			Name="TypeBadge",
			Text="",
			InitCommand=function(self)
				self:zoom(0.7)
				self:horizalign(right)
				self:y(-paneHeight/2 + RowHeight/2)
				self:x(paneWidth/2 - 4)
				self:visible(false)
			end
		},

		-- Self highlight
		Def.Quad {
			Name="Self",
			InitCommand=function(self)
				self:diffuse(color("#A1FF94")):visible(false)
			end,
			ACResetEntryMessageCommand=function(self)
				self:visible(false)
			end,
			RefreshCommand=function(self)
				local width = self:GetParent():GetWidth()
				self:zoomto(width, RowHeight)
			end
		},

		-- Rival highlights (up to 3)
		Def.Quad {
			Name="Rival1",
			InitCommand=function(self)
				self:diffuse(color("#BD94FF")):visible(false)
			end,
			ACResetEntryMessageCommand=function(self)
				self:visible(false)
			end,
			RefreshCommand=function(self)
				local width = self:GetParent():GetWidth()
				self:zoomto(width, RowHeight)
			end
		},
		Def.Quad {
			Name="Rival2",
			InitCommand=function(self)
				self:diffuse(color("#BD94FF")):visible(false)
			end,
			ACResetEntryMessageCommand=function(self)
				self:visible(false)
			end,
			RefreshCommand=function(self)
				local width = self:GetParent():GetWidth()
				self:zoomto(width, RowHeight)
			end
		},
		Def.Quad {
			Name="Rival3",
			InitCommand=function(self)
				self:diffuse(color("#BD94FF")):visible(false)
			end,
			ACResetEntryMessageCommand=function(self)
				self:visible(false)
			end,
			RefreshCommand=function(self)
				local width = self:GetParent():GetWidth()
				self:zoomto(width, RowHeight)
			end
		},

		-- Pane navigation icons (hidden by default)
		Def.ActorFrame{
			Name="PaneIcons",
			InitCommand=function(self)
				self:y(paneHeight/2 - RowHeight/2)
				self:visible(false)
			end,
			ACResetEntryMessageCommand=function(self)
				self:visible(false)
			end,

			LoadFont(ThemePrefs.Get("ThemeFont") .. " Normal").. {
				Name="LeftIcon",
				Text="&MENULEFT;",
				InitCommand=function(self)
					self:x(-paneWidth/2 + 10)
				end,
				OnCommand=function(self) self:queuecommand("Bounce") end,
				BounceCommand=function(self)
					self:decelerate(0.5):addx(10):accelerate(0.5):addx(-10)
					self:queuecommand("Bounce")
				end,
			},

			LoadFont(ThemePrefs.Get("ThemeFont") .. " Normal").. {
				Name="Text",
				Text="More Leaderboards",
				InitCommand=function(self)
					self:diffuse(Color.White)
				end,
			},

			LoadFont(ThemePrefs.Get("ThemeFont") .. " Normal").. {
				Name="RightIcon",
				Text="&MENURiGHT;",
				InitCommand=function(self)
					self:x(paneWidth/2 - 10)
				end,
				OnCommand=function(self) self:queuecommand("Bounce") end,
				BounceCommand=function(self)
					self:decelerate(0.5):addx(-10):accelerate(0.5):addx(10)
					self:queuecommand("Bounce")
				end,
			},
		}
	}

	local af2 = af[#af]
	for i=1, NumEntries do
		af2[#af2+1] = Def.ActorFrame{
			Name="LeaderboardEntry"..i,
			InitCommand=function(self)
				if NumEntries % 2 == 1 then
					self:y(RowHeight*(i - (NumEntries+1)/2) )
				else
					self:y(RowHeight*(i - NumEntries/2))
				end
			end,
			RefreshCommand=function(self)
				self:GetChild("Date"):visible(GAMESTATE:GetNumSidesJoined() == 1)
			end,

			LoadFont(ThemePrefs.Get("ThemeFont") .. " Normal").. {
				Name="Rank",
				Text="",
				InitCommand=function(self)
					self:horizalign(right)
					self:zoom(0.75)
					self:maxwidth(40)
					self:diffuse(Color.White)
				end,
				RefreshCommand=function(self)
					local width = self:GetParent():GetParent():GetWidth()
					self:x(-width/2 + 30)
				end,
				ACResetEntryMessageCommand=function(self)
					self:settext("")
					self:diffuse(Color.White)
				end
			},

			LoadFont(ThemePrefs.Get("ThemeFont") .. " Normal").. {
				Name="Name",
				Text=(i==1 and "Loading ..." or ""),
				InitCommand=function(self)
					self:horizalign(center)
					self:zoom(0.75)
					self:diffuse(Color.White)
				end,
				RefreshCommand=function(self)
					local width = self:GetParent():GetParent():GetWidth()
					self:maxwidth(width * 0.8)
				end,
				ACResetEntryMessageCommand=function(self)
					self:settext(i==1 and "Loading ..." or "")
					self:diffuse(Color.White)
				end
			},

			LoadFont(ThemePrefs.Get("ThemeFont") .. " Normal").. {
				Name="Score",
				Text="",
				InitCommand=function(self)
					self:horizalign(right)
					self:zoom(0.75)
					self:diffuse(Color.White)
				end,
				RefreshCommand=function(self)
					local width = self:GetParent():GetParent():GetWidth()
					self:x(width/2 - borderWidth)
				end,
				ACResetEntryMessageCommand=function(self)
					self:settext("")
					self:diffuse(Color.White)
				end
			},

			LoadFont(ThemePrefs.Get("ThemeFont") .. " Normal").. {
				Name="Date",
				Text="",
				InitCommand=function(self)
					self:horizalign(right)
					self:zoom(0.75)
					self:diffuse(Color.White)
				end,
				RefreshCommand=function(self)
					local width = self:GetParent():GetParent():GetWidth()
					self:x(width/2 + 100 - borderWidth)
				end,
				ACResetEntryMessageCommand=function(self)
					self:settext("")
					self:diffuse(Color.White)
				end
			},
		}
	end
end

return af
