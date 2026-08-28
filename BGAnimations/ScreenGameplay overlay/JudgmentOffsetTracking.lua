-- In this file, we're storing judgment offset data that occurs during gameplay so that
-- ScreenEvaluation can use it to draw both the scatterplot and the offset histogram.
--
-- Similar to PerColumnJudgmentTracking.lua, this file doesn't override or recreate the engine's
-- judgment system in any way. It just allows transient judgment data to persist beyond ScreenGameplay.
------------------------------------------------------------

-- don't bother tracking for Casual gamemode
if SL.Global.GameMode == "Casual" then return end

local player = ...
local sequential_offsets = {}
local worst_window = 2
local PlayerState = GAMESTATE:GetPlayerState(player)
local streams = SL[ToEnumShortString(player)].Streams
local foot

local hitEarly = false
local earlyOffset = 0
local heldMiss = false

local require_step_on_hold_heads = THEME:GetMetric("Player", "RequireStepOnHoldHeads")

return Def.Actor{
	EarlyHitMessageCommand=function(self, params)
		if SL[ToEnumShortString(player)].ActiveModifiers.TrackRecalc then
			earlyOffset = params.TapNoteScore == "TapNoteScore_Miss" and "Miss" or params.TapNoteOffset
			if earlyOffset ~= "Miss" then
				hitEarly = true
				local window = DetermineTimingWindow(earlyOffset)
				if window > worst_window then
					worst_window = window
				end
			end
		end
	end,
	JudgmentMessageCommand=function(self, params)
		if params.Player ~= player then return end
		if params.HoldNoteScore then return end

		local tns = params.TapNoteScore

		if params.TapNoteOffset then
			-- Store "Miss" for misses (including checkpoint misses, which the engine
			-- reports with a meaningless 0ms offset); store the engine's offset otherwise.
			local offset = (tns == "TapNoteScore_Miss" or tns == "TapNoteScore_CheckpointMiss") and "Miss" or params.TapNoteOffset
			
			-- Track worst window a hit happened in
			if offset ~= "Miss" then
				local window = DetermineTimingWindow(offset)
				if window > worst_window then
					worst_window = window
				end
			end

			-- A note you don't have to hit. Pump hold heads/ticks.
			local is_autohit = false
			if tns == "TapNoteScore_CheckpointHit" then
				is_autohit = true
			elseif not require_step_on_hold_heads and params.Notes then
				local only_hold_heads, found_note = true, false
				for _,tapnote in pairs(params.Notes) do
					found_note = true
					if tapnote:GetTapNoteType() ~= "TapNoteType_HoldHead" then
						only_hold_heads = false
						break
					end
				end
				is_autohit = found_note and only_hold_heads
			end
			
			-- Store which arrow the tap was on
			local arrow = 0
			for col,tapnote in pairs(params.Notes) do
				local tnt = ToEnumShortString(tapnote:GetTapNoteType())
				if tnt == "Tap" or tnt == "HoldHead" or tnt == "Lift" then
					local tns = ToEnumShortString(params.TapNoteScore)
					arrow = arrow + col
					
					if tnt ~= "Lift" and tns == "Miss" and tapnote:GetTapNoteResult():GetHeld() then
						heldMiss = true
					end
					
					if arrow == 1 then
						foot=true
					elseif arrow == 4 then
						foot=false
					else
						foot = not foot
					end
				end
			end
			
			-- If current step is part of a stream, store which foot the tap was on
			local isStream = false
			if streams.Measures and #streams.Measures > 0 then
				local currMeasure = (math.floor(PlayerState:GetSongPosition():GetSongBeatVisible()))/4
				for i=1,#streams.Measures do
					run = streams.Measures[i]
					if currMeasure >= run.streamStart and currMeasure <= run.streamEnd and not run.isBreak then
						isStream = true
						break
					elseif currMeasure < run.streamStart then
						break
					end
				end
			end
			
			local courseOffset = 0
			if GAMESTATE:IsCourseMode() then
				local curCourseSong = GAMESTATE:GetCourseSongIndex()
				local courseEntries = GAMESTATE:GetCurrentTrail(ToEnumShortString(player)):GetTrailEntries()
				
				for i=1,curCourseSong do
					courseOffset = courseOffset + courseEntries[i]:GetSong():GetLastSecond()
				end
			end

			-- Store judgment offsets (including misses) in an indexed table as they occur.
			-- Also store the CurMusicSeconds for Evaluation's scatter plot.
			sequential_offsets[#sequential_offsets+1] = { courseOffset + GAMESTATE:GetCurMusicSeconds(), offset, arrow, isStream, foot, hitEarly, earlyOffset, heldMiss, is_autohit }
			hitEarly = false
			heldMiss = false
			earlyOffset = 0
		end
	end,
	OffCommand=function(self)
		local storage = SL[ToEnumShortString(player)].Stages.Stats[SL.Global.Stages.PlayedThisGame + 1]
		storage.sequential_offsets = sequential_offsets
		storage.worst_window = worst_window
	end
}