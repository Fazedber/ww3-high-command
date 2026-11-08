-- Sound effects and music (upstream client/sound: SoundManager + Sounds.ts).
-- Effects are OpenFront's resources/sounds (, see NOTICE.md),
-- uploaded as Roblox audio. The upstream music is proprietary, so the game
-- plays tracks from Roblox's licensed APM library instead.

local SoundService = game:GetService("SoundService")
local Icons = require(script.Parent:WaitForChild("Icons"))

-- Effects: the original uploads belong to another Roblox account and fail to load
-- ("User is not authorized to access Asset") in every other place, so cues use the
-- engine's built-in sounds (always available). Swap any entry for your own
-- uploaded rbxassetid://... when you have audio files.
local S = "rbxasset://sounds/"
local PING = S .. "electronicpingshort.wav"
local SOFT_CLICK = S .. "switch.wav"
local THUD = S .. "bass.wav"
-- Everything is quiet and passes through a treble-cutting EQ (see softEq): soft "plink"
-- for rewards, dull ticks for actions, low thuds for explosions. Nothing sharp.
local EFFECTS = {
	["atom-hit"] = { id = THUD, speed = 0.8, volume = 0.35 },
	["atom-launch"] = { id = THUD, speed = 1.3, volume = 0.25 },
	["hydrogen-hit"] = { id = THUD, speed = 0.6, volume = 0.4 },
	["hydrogen-launch"] = { id = THUD, speed = 1.1, volume = 0.25 },
	["mirv-launch"] = { id = THUD, speed = 1.5, volume = 0.25 },
	["nuke-warning"] = { id = PING, speed = 0.6, volume = 0.3, repeats = 2, step = 0.3 },
	["alliance-suggested"] = { id = PING, speed = 0.9, volume = 0.2 },
	["alliance-accepted"] = { id = PING, speed = 1.1, volume = 0.22 },
	["alliance-declined"] = { id = SOFT_CLICK, speed = 0.7, volume = 0.22 },
	["alliance-broken"] = { id = SOFT_CLICK, speed = 0.6, volume = 0.25 },
	["build-city"] = { id = SOFT_CLICK, speed = 0.8, volume = 0.25 },
	["build-defense-post"] = { id = SOFT_CLICK, speed = 0.7, volume = 0.25 },
	["build-factory"] = { id = SOFT_CLICK, speed = 0.75, volume = 0.25 },
	["build-port"] = { id = SOFT_CLICK, speed = 0.7, volume = 0.25 },
	["build-train-station"] = { id = SOFT_CLICK, speed = 0.85, volume = 0.22 },
	["build-warship"] = { id = SOFT_CLICK, speed = 0.65, volume = 0.25 },
	["sam-built"] = { id = SOFT_CLICK, speed = 0.7, volume = 0.25 },
	["silo-built"] = { id = SOFT_CLICK, speed = 0.65, volume = 0.25 },
	["transport-ship"] = { id = SOFT_CLICK, speed = 0.7, volume = 0.22 },
	click = { id = S .. "clickfast.wav", speed = 0.9, volume = 0.18 },
	-- Crowd shout (Pro Sound Effects, free library) trimmed to 1.4 s, quiet, at most once per 6 s.
	attack = { id = 9114360647, volume = 0.18, from = 0.25, len = 1.4, gap = 6 },
	-- Dull tick while land is being captured.
	capture = { id = SOFT_CLICK, speed = 0.7, jitter = 0.05, volume = 0.2, gap = 0.5 },
	-- Someone is attacking you: two soft low pings.
	alert = { id = PING, speed = 0.6, volume = 0.3, repeats = 2, step = 0.28, gap = 5 },
	-- "You got something": one soft plink (conquest / gold payout).
	conquered = { id = PING, speed = 0.85, volume = 0.28 },
	["ka-ching"] = { id = PING, speed = 1.05, volume = 0.25 },
	spawn = { id = PING, speed = 0.75, volume = 0.22 },
	["game-start"] = { id = THUD, speed = 1.4, volume = 0.2 },
	victory = { id = S .. "victory.wav", volume = 0.3 },
	defeat = { id = THUD, speed = 0.7, volume = 0.3 },
}-- Same morse-code cue as the alliance request (Sounds.ts "message").
EFFECTS.message = EFFECTS["alliance-suggested"]

-- Structure ambience loops: the originals are private uploads (see above), so
-- ambience is off until you provide your own tracks.
local AMBIENCE = {}
local AMBIENCE_FADE = 0.5 -- SoundManager AMBIENCE_FADE_MS

-- Calm game-music tracks (DistroKid library, free): the old APM trailer-style cues were too epic.
local MUSIC = {
	75571947345222, -- Pixel Map
	80368797450384, -- Analog Path
	116391820922861, -- Crystal Circuit
	81992081796100, -- Soft Dungeon
	72334545577279, -- Hidden Pathways
	113892299771074, -- Mana Flow
}

local EFFECT_VOLUME = 0.55
local MUSIC_VOLUME = 0.1
-- Upstream AudioMixer budget: at most this many copies of one cue at once.
local MAX_PER_CUE = 3

local Audio = {}

local group = Instance.new("SoundGroup")
group.Name = "Effects"
group.Volume = EFFECT_VOLUME
group.Parent = SoundService
-- Soften every effect: cut the harsh treble a little.
local softEq = Instance.new("EqualizerSoundEffect")
softEq.HighGain = -32
softEq.MidGain = -6
softEq.LowGain = 0
softEq.Parent = group
local musicGroup = Instance.new("SoundGroup")
musicGroup.Name = "Music"
musicGroup.Volume = MUSIC_VOLUME
musicGroup.Parent = SoundService

local playing: { [string]: number } = {}
local lastPlayed: { [string]: number } = {}
local muted = false
-- Player volume (0..1) per channel, saved in the profile ("audio" setting).
local volume = { music = 1, effects = 1 }
local onChange: ((music: number, effects: number) -> ())? = nil

local function applyVolume()
	group.Volume = if muted then 0 else EFFECT_VOLUME * volume.effects
	musicGroup.Volume = if muted then 0 else MUSIC_VOLUME * volume.music
end

-- Plays a cue; `minGap` (seconds) drops repeats that come too quickly (the
-- MIRV and nuke-warning intervals in SoundEffectController).
function Audio.play(name: string, minGap: number?)
	local def = EFFECTS[name]
	if def == nil or muted or volume.effects <= 0 then
		return
	end
	local spec = if type(def) == "table" then def else { id = def }
	local gap = minGap or spec.gap
	local now = os.clock()
	if gap and lastPlayed[name] and now - lastPlayed[name] < gap then
		return
	end
	if (playing[name] or 0) >= MAX_PER_CUE then
		return
	end
	lastPlayed[name] = now
	for r = 1, spec.repeats or 1 do
		task.delay((r - 1) * (spec.step or 0.2), function()
			if muted then
				return
			end
			playing[name] = (playing[name] or 0) + 1
			local s = Instance.new("Sound")
			s.SoundId = if type(spec.id) == "string" then spec.id else `rbxassetid://{spec.id}`
			s.Volume = spec.volume or 1
			s.PlaybackSpeed = (spec.speed or 1) * (1 + (math.random() - 0.5) * 2 * (spec.jitter or 0))
			s.SoundGroup = group
			s.Parent = SoundService
			local released = false
			local function release()
				if released then
					return
				end
				released = true
				playing[name] -= 1
				s:Destroy()
			end
			s.Ended:Once(release)
			if spec.from then
				local t0 = os.clock()
				while not s.IsLoaded and os.clock() - t0 < 3 do
					task.wait()
				end
				s.TimePosition = spec.from
			end
			s:Play()
			if spec.len then
				task.delay(spec.len, function()
					if released then
						return
					end
					game:GetService("TweenService"):Create(s, TweenInfo.new(0.3), { Volume = 0 }):Play()
					task.delay(0.35, release)
				end)
			end
			-- A cue that never loads must not hold its budget slot forever.
			task.delay(25, release)
		end)
	end
end
-- Ambience (AmbienceController + SoundManager.setAmbience): one looping track
-- at a time, crossfaded; gain 0..0.3 from the zoom level. Follows the
-- effects volume.
local TweenService = game:GetService("TweenService")
local ambienceSounds: { [string]: Sound } = {}
local currentAmbience: string? = nil
function Audio.setAmbience(track: string?, gain: number)
	local target = gain * (if muted then 0 else volume.effects)
	if track ~= currentAmbience and currentAmbience then
		local old = ambienceSounds[currentAmbience]
		if old then
			local tw = TweenService:Create(old, TweenInfo.new(AMBIENCE_FADE), { Volume = 0 })
			tw.Completed:Once(function()
				if old.Volume == 0 then
					old:Stop()
				end
			end)
			tw:Play()
		end
	end
	currentAmbience = track
	if track == nil or AMBIENCE[track] == nil then
		return
	end
	local s = ambienceSounds[track]
	if s == nil then
		s = Instance.new("Sound")
		s.Name = "Ambience_" .. track
		s.SoundId = "rbxassetid://" .. AMBIENCE[track]
		s.Looped = true
		s.Volume = 0
		s.Parent = SoundService
		ambienceSounds[track] = s
	end
	if not s.IsPlaying then
		s:Play()
	end
	TweenService:Create(s, TweenInfo.new(AMBIENCE_FADE), { Volume = target }):Play()
end

-- Looping playlist; started once per client (Main is re-cloned every match,
-- this module is not).
local musicStarted = false
function Audio.startMusic()
	if musicStarted then
		return
	end
	musicStarted = true
	local track = Instance.new("Sound")
	track.Name = "MusicTrack"
	track.SoundGroup = musicGroup
	track.Parent = SoundService
	local i = math.random(#MUSIC)
	local function nextTrack()
		track.SoundId = `rbxassetid://{MUSIC[i]}`
		i = i % #MUSIC + 1
		track:Play()
	end
	track.Ended:Connect(nextTrack)
	nextTrack()
	-- Watchdog: a track that never loads (Ended never fires) or that the engine left
	-- paused must not silence the playlist for the rest of the session.
	task.spawn(function()
		local stuck = 0
		while track.Parent do
			task.wait(2)
			if track.IsPlaying then
				stuck = 0
			elseif track.IsPaused then
				track:Resume()
			else
				stuck += 1
				if stuck >= 3 then
					stuck = 0
					nextTrack()
				end
			end
		end
	end)
end

function Audio.isMuted(): boolean
	return muted
end

function Audio.setMuted(value: boolean)
	muted = value
	applyVolume()
end

-- Saved volumes from the profile ({ music, effects } or nil).
function Audio.load(saved)
	if type(saved) == "table" then
		volume.music = math.clamp(tonumber(saved.music) or 1, 0, 1)
		volume.effects = math.clamp(tonumber(saved.effects) or 1, 0, 1)
		applyVolume()
		if Audio.repaint then
			Audio.repaint()
		end
	end
end

-- Called with (music, effects) whenever the player changes a volume.
function Audio.onChange(fn)
	onChange = fn
end

local function mkButton(parent: Instance, name: string, text: string, size: Vector2): TextButton
	local b = Instance.new("TextButton")
	b.Name = name
	b.Size = UDim2.fromOffset(size.X, size.Y)
	b.BackgroundColor3 = Color3.fromRGB(10, 12, 32)
	b.BackgroundTransparency = 0.03
	b.AutoButtonColor = true
	b.TextSize = 16
	b.Font = Enum.Font.Arcade
	b.TextColor3 = Color3.fromRGB(240, 236, 228)
	b.Text = text
	b.ZIndex = 50
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 2)
	corner.Parent = b
	local inner = Instance.new("UIStroke")
	inner.Color = Color3.fromRGB(38, 42, 92)
	inner.Thickness = 2
	inner.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	inner.Parent = b
	b.Parent = parent
	return b
end

-- Speaker button left of the leaderboard (follows it as it opens / closes);
-- it opens a small panel: music and effects volume in 10 % steps.
function Audio.button(parent: Instance, board: GuiObject): TextButton
	local b = mkButton(parent, "AudioToggle", "", Vector2.new(44, 40))
	b.AnchorPoint = Vector2.new(1, 0)
	local speaker = Icons.label(b, "sound", 26, { white = true })
	speaker.AnchorPoint = Vector2.new(0.5, 0.5)
	speaker.Position = UDim2.fromScale(0.5, 0.5)
	speaker.ZIndex = 51
	local panel = Instance.new("Frame")
	panel.Name = "AudioPanel"
	panel.AnchorPoint = Vector2.new(1, 0)
	panel.Size = UDim2.fromOffset(230, 0)
	panel.AutomaticSize = Enum.AutomaticSize.Y
	panel.BackgroundColor3 = Color3.fromRGB(10, 12, 32)
	panel.BackgroundTransparency = 0.02
	panel.Visible = false
	panel.ZIndex = 50
	local pc = Instance.new("UICorner")
	pc.CornerRadius = UDim.new(0, 2)
	pc.Parent = panel
	local panelInner = Instance.new("UIStroke")
	panelInner.Color = Color3.fromRGB(38, 42, 92)
	panelInner.Thickness = 2
	panelInner.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	panelInner.Parent = panel
	local pad = Instance.new("UIPadding")
	for _, k in { "PaddingTop", "PaddingBottom", "PaddingLeft", "PaddingRight" } do
		pad[k] = UDim.new(0, 8)
	end
	pad.Parent = panel
	local list = Instance.new("UIListLayout")
	list.Padding = UDim.new(0, 6)
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Parent = panel
	panel.Parent = parent

	local rows = {}
	local function row(key: string, label: string, order: number)
		local r = Instance.new("Frame")
		r.Name = key
		r.BackgroundTransparency = 1
		r.Size = UDim2.new(1, 0, 0, 32)
		r.LayoutOrder = order
		r.ZIndex = 51
		r.Parent = panel
		local t = Instance.new("TextLabel")
		t.BackgroundTransparency = 1
		t.Size = UDim2.new(0, 80, 1, 0)
		t.Font = Enum.Font.Arcade
		t.TextSize = 13
		t.TextColor3 = Color3.new(1, 1, 1)
		t.TextXAlignment = Enum.TextXAlignment.Left
		t.Text = label
		t.ZIndex = 51
		t.Parent = r
		local minus = mkButton(r, "Minus", "−", Vector2.new(32, 32))
		minus.Position = UDim2.fromOffset(84, 0)
		local value = Instance.new("TextLabel")
		value.BackgroundTransparency = 1
		value.Position = UDim2.fromOffset(118, 0)
		value.Size = UDim2.fromOffset(60, 32)
		value.Font = Enum.Font.Arcade
		value.TextSize = 13
		value.TextColor3 = Color3.new(1, 1, 1)
		value.ZIndex = 51
		value.Parent = r
		local plus = mkButton(r, "Plus", "+", Vector2.new(32, 32))
		plus.Position = UDim2.fromOffset(180, 0)
		local function step(d: number)
			volume[key] = math.clamp(math.round((volume[key] + d) * 10) / 10, 0, 1)
			applyVolume()
			Audio.repaint()
			if onChange then
				onChange(volume.music, volume.effects)
			end
		end
		minus.Activated:Connect(function()
			step(-0.1)
		end)
		plus.Activated:Connect(function()
			step(0.1)
		end)
		rows[key] = value
	end
	row("music", "Music", 1)
	row("effects", "Effects", 2)
	local mute = mkButton(panel, "Mute", "", Vector2.new(214, 32))
	mute.LayoutOrder = 3
	mute.TextSize = 15
	mute.Activated:Connect(function()
		Audio.setMuted(not muted)
		Audio.repaint()
	end)

	function Audio.repaint()
		b.Text = if muted or (volume.music <= 0 and volume.effects <= 0) then "🔇" else "🔊"
		rows.music.Text = tostring(math.round(volume.music * 100)) .. "%"
		rows.effects.Text = tostring(math.round(volume.effects * 100)) .. "%"
		mute.Text = if muted then "Unmute" else "Mute all"
	end
	Audio.repaint()
	b.Activated:Connect(function()
		panel.Visible = not panel.Visible
	end)
	local function follow()
		-- Offsets relative to the parent (AbsolutePosition ignores IgnoreGuiInset).
		local origin = (parent :: any).AbsolutePosition
		local x = board.AbsolutePosition.X - origin.X - 8
		local y = board.AbsolutePosition.Y - origin.Y
		b.Position = UDim2.fromOffset(x, y)
		panel.Position = UDim2.fromOffset(x, y + 46)
	end
	board:GetPropertyChangedSignal("AbsolutePosition"):Connect(follow)
	board:GetPropertyChangedSignal("AbsoluteSize"):Connect(follow)
	follow()
	return b
end

return Audio
