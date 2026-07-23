return Def.ActorFrame{
	Def.Actor{
		BeginCommand=function(self)
			self:queuecommand("Load")
		end,
		LoadCommand=function()
			if SL.NewDownloadsCompleted and SCREENMAN:GetTopScreen():GetNextScreenName() == "ScreenSelectMusic" then
				SL.NewDownloadsCompleted = false
				SCREENMAN:GetTopScreen():SetNextScreenName("ScreenReloadSongsSSM")
			end
			SCREENMAN:GetTopScreen():Continue()
		end
	}
}
