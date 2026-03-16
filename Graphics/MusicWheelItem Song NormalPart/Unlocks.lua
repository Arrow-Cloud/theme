local player = ...
local pn = ToEnumShortString(player)

local af = Def.ActorFrame {
	PlayerJoinedMessageCommand=function(self, params)
		if not PROFILEMAN:IsPersistentProfile(params.Player) then
			GAMESTATE:ResetPlayerOptions(params.Player)
			SL[ToEnumShortString(params.Player)]:initialize()
		end
		if pn == nil then
			player = params.Player
			pn = ToEnumShortString(player)
		end
	end,
    Def.Sprite{
        InitCommand=function(self)
            self:animate(false):visible(false)
            if #GAMESTATE:GetHumanPlayers() > 1 then
                self:x(-12)
            else
                self:x(-15)
            end
            self:Load( THEME:GetPathG("", "lock.png") )
        end,
        SetCommand=function(self, params)
            if params.Song then
                local song = params.Song
                local song_dir = song:GetSongDir()

                local year = 2026
                if string.find(string.lower(song_dir), "itl online "..year.." unlocks") then
                    local unlockData = SL[pn].ITLData["unlockFolders"][song_dir] or {}
                    self:visible(unlockData[song_dir] or false)
                else
                    self:visible(false)
                end

                if #GAMESTATE:GetHumanPlayers() > 1 then
                    self:zoomto(15,15)
                    self:y(pn == "P1" and -8 or 8)
                else
                    self:zoomto(20,20):y(0)
                end
            end
        end,
    }
}

return af
