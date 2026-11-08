-- Nuke aiming preview: port of OpenFrontIO render/gl/utils/NukeTrajectory.ts
-- (Bezier control points + untargetable / SAM-intercept thresholds, same
-- math as the sim's parabola) drawn like NukeTrajectoryPass: a dashed white
-- arc, sparse dots while out of SAM reach, red after the first hostile SAM
-- would intercept, circles at the zone boundaries and an X at the intercept.

local NukePreview = {}
NukePreview.__index = NukePreview

local PARABOLA_MIN_HEIGHT = 50
local TARGETABLE_RANGE = 150
local TARGETABLE_RANGE_SQ = TARGETABLE_RANGE * TARGETABLE_RANGE
local THRESHOLD_SAMPLES = 32
local MAX_SAM_RANGE = 130 -- Config.maxSamRange (Roblox tuning; upstream 150)
local SAM_SAFETY_MARGIN = 0.75

-- render-settings.json nukeTrajectory
local DASH_TARGETABLE, GAP_TARGETABLE = 8, 4
local DASH_UNTARGETABLE, GAP_UNTARGETABLE = 2, 6
local LINE_PX = 2.5
local LINE_COLOR = Color3.new(1, 1, 1)
local INTERCEPT_COLOR = Color3.new(1, 0.314, 0.314)
local OUTLINE_COLOR = Color3.new(0.549, 0.549, 0.549)
local INTERCEPT_OUTLINE = Color3.new(0.588, 0.353, 0.353)
local MARKER_CIRCLE_PX = 6
local MARKER_X_PX = 9
local RENDER_SAMPLES = 96

function NukePreview.samRange(level: number): number
	return MAX_SAM_RANGE - 480 / (level + 5)
end

local function round(v: number): number
	return math.floor(v + 0.5)
end

function NukePreview.controlPoints(srcX, srcY, dstX, dstY, mapH, directionUp)
	local dx, dy = dstX - srcX, dstY - srcY
	local dist = math.sqrt(dx * dx + dy * dy)
	local maxHeight = math.max(dist / 3, PARABOLA_MIN_HEIGHT)
	local hm = if directionUp then -1 else 1
	return {
		p0x = srcX,
		p0y = srcY,
		p1x = srcX + dx / 4,
		p1y = math.clamp(srcY + dy / 4 + hm * maxHeight, 0, mapH - 1),
		p2x = srcX + dx * 3 / 4,
		p2y = math.clamp(srcY + dy * 3 / 4 + hm * maxHeight, 0, mapH - 1),
		p3x = dstX,
		p3y = dstY,
	}
end

-- Binary search for the t where the curve enters / leaves rangeSq of (cx, cy).
local function refineCrossing(ax, bx, cx_, dx_, ay, by, cy_, dy_, cx, cy, rangeSq, tLo, tHi, exiting)
	local foundInside = false
	for _ = 1, 10 do
		local t = (tLo + tHi) * 0.5
		local x = round(((ax * t + bx) * t + cx_) * t + dx_)
		local y = round(((ay * t + by) * t + cy_) * t + dy_)
		local ddx, ddy = x - cx, y - cy
		local inside = ddx * ddx + ddy * ddy <= rangeSq
		if inside then
			foundInside = true
		end
		if if exiting then inside else not inside then
			tLo = t
		else
			tHi = t
		end
	end
	if not exiting and not foundInside then
		local x = round(((ax * tHi + bx) * tHi + cx_) * tHi + dx_)
		local y = round(((ay * tHi + by) * tHi + cy_) * tHi + dy_)
		local ddx, ddy = x - cx, y - cy
		if ddx * ddx + ddy * ddy > rangeSq then
			return 1.0
		end
	end
	return (tLo + tHi) * 0.5
end

-- computeTrajectoryThresholds: t values of the untargetable span and the
-- first SAM intercept (1 = none). dstX/dstY are the integer target tile.
function NukePreview.thresholds(cp, srcX, srcY, dstX, dstY, sams)
	local tStart, tEnd, tSam = -1, -1, 1.0
	local dt = 1.0 / THRESHOLD_SAMPLES
	local cx_ = 3 * (cp.p1x - cp.p0x)
	local bx = 3 * (cp.p2x - 2 * cp.p1x + cp.p0x)
	local ax = dstX - 3 * cp.p2x + 3 * cp.p1x - cp.p0x
	local dx_ = cp.p0x
	local cy_ = 3 * (cp.p1y - cp.p0y)
	local by = 3 * (cp.p2y - 2 * cp.p1y + cp.p0y)
	local ay = dstY - 3 * cp.p2y + 3 * cp.p1y - cp.p0y
	local dy_ = cp.p0y
	local sdx, sdy = dstX - srcX, dstY - srcY
	local hasUntargetable = sdx * sdx + sdy * sdy > 4 * TARGETABLE_RANGE_SQ
	local samLen = #sams
	local prevX, prevY = round(cp.p0x), round(cp.p0y)

	for i = 1, THRESHOLD_SAMPLES do
		local t = i * dt
		local tPrev = t - dt
		local x = round(((ax * t + bx) * t + cx_) * t + dx_)
		local y = round(((ay * t + by) * t + cy_) * t + dy_)
		local untargetable = false
		if hasUntargetable then
			if tStart < 0 then
				local ex, ey = x - srcX, y - srcY
				if ex * ex + ey * ey > TARGETABLE_RANGE_SQ then
					local fx, fy = x - dstX, y - dstY
					if fx * fx + fy * fy >= TARGETABLE_RANGE_SQ then
						tStart = refineCrossing(ax, bx, cx_, dx_, ay, by, cy_, dy_, srcX, srcY, TARGETABLE_RANGE_SQ, tPrev, t, true)
						untargetable = true
					end
				end
			elseif tEnd < 0 then
				local fx, fy = x - dstX, y - dstY
				if fx * fx + fy * fy < TARGETABLE_RANGE_SQ then
					tEnd = refineCrossing(ax, bx, cx_, dx_, ay, by, cy_, dy_, dstX, dstY, TARGETABLE_RANGE_SQ, tPrev, t, false)
				else
					untargetable = true
				end
			end
		end

		if tEnd >= 0 and tPrev < tEnd and t >= tEnd and samLen > 0 then
			local xe = round(((ax * tEnd + bx) * tEnd + cx_) * tEnd + dx_)
			local ye = round(((ay * tEnd + by) * tEnd + cy_) * tEnd + dy_)
			for _, sam in sams do
				local ddx, ddy = xe - sam.x, ye - sam.y
				if ddx * ddx + ddy * ddy <= sam.r * sam.r then
					tSam = tEnd
					break
				end
			end
			if tSam < 1.0 then
				break
			end
		end

		if not untargetable and samLen > 0 then
			local segDx, segDy = x - prevX, y - prevY
			local l2 = segDx * segDx + segDy * segDy
			local invL2 = if l2 == 0 then 0 else 1.0 / l2
			local maxDist = math.sqrt(l2) + MAX_SAM_RANGE + SAM_SAFETY_MARGIN
			local maxDSrcSq = maxDist * maxDist
			for _, sam in sams do
				local sx, sy = sam.x - prevX, sam.y - prevY
				local dSrcSq = sx * sx + sy * sy
				if dSrcSq > maxDSrcSq then
					continue
				end
				local dot = sx * segDx + sy * segDy
				local dSq
				if dot <= 0 then
					dSq = dSrcSq
				elseif dot >= l2 then
					dSq = dSrcSq + l2 - 2 * dot
				else
					dSq = dSrcSq - dot * dot * invL2
				end
				local cand = (sam.r + SAM_SAFETY_MARGIN) * (sam.r + SAM_SAFETY_MARGIN)
				if dSq <= cand then
					local lo = if tEnd >= 0 and tPrev < tEnd then tEnd else tPrev
					local hit = refineCrossing(ax, bx, cx_, dx_, ay, by, cy_, dy_, sam.x, sam.y, sam.r * sam.r, lo, t, false)
					if hit < 1.0 then
						tSam = hit
						break
					end
				end
			end
			if tSam < 1.0 then
				break
			end
		end
		prevX, prevY = x, y
	end
	return tStart, tEnd, tSam
end

local function bezier(cp, t: number): (number, number)
	local u = 1 - t
	local a, b, c, d = u * u * u, 3 * u * u * t, 3 * u * t * t, t * t * t
	return a * cp.p0x + b * cp.p1x + c * cp.p2x + d * cp.p3x, a * cp.p0y + b * cp.p1y + c * cp.p2y + d * cp.p3y
end

function NukePreview.new(parent: GuiObject, camera, map)
	local container = Instance.new("Frame")
	container.Name = "NukePreview"
	container.BackgroundTransparency = 1
	container.Size = UDim2.fromScale(1, 1)
	container.ZIndex = 18
	container.Parent = parent
	return setmetatable({ container = container, camera = camera, map = map, pool = {}, used = 0, data = nil }, NukePreview)
end

-- data = { srcX, srcY, dstX, dstY, directionUp, sams = { {x, y, r} } } or nil.
function NukePreview:set(data)
	if data then
		local cp = NukePreview.controlPoints(data.srcX, data.srcY, data.dstX, data.dstY, self.map:height(), data.directionUp)
		local tStart, tEnd, tSam = NukePreview.thresholds(cp, data.srcX, data.srcY, round(data.dstX), round(data.dstY), data.sams)
		if data.blocked then
			tSam = math.min(tSam, 0.9999) -- impassable target: X at the destination
		end
		self.data = { cp = cp, tStart = tStart, tEnd = tEnd, tSam = tSam }
	else
		self.data = nil
	end
	self:render()
end

function NukePreview:_frame()
	self.used += 1
	local f = self.pool[self.used]
	if f == nil then
		f = Instance.new("Frame")
		f.AnchorPoint = Vector2.new(0.5, 0.5)
		f.BorderSizePixel = 0
		f.ZIndex = 18
		local s = Instance.new("UIStroke")
		s.Thickness = 1
		s.Parent = f
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, 0)
		c.Parent = f
		f.Parent = self.container
		self.pool[self.used] = f
	end
	f.Visible = true
	f.Rotation = 0
	f.BackgroundTransparency = 0
	f.UIStroke.Transparency = 0
	f.UIStroke.Thickness = 1
	f.UICorner.CornerRadius = UDim.new(0, 0)
	return f
end

function NukePreview:render()
	self.used = 0
	local d = self.data
	if d then
		local camera, cp = self.camera, d.cp
		-- Screen-space polyline.
		local pts = table.create(RENDER_SAMPLES + 1)
		for i = 0, RENDER_SAMPLES do
			local t = i / RENDER_SAMPLES
			local x, y = bezier(cp, t)
			pts[i + 1] = camera:screenPos(x + 0.5, y + 0.5)
		end
		-- Walk it in pixels, emitting dashes by zone.
		local i, along = 1, 0
		local segLen = (pts[2] - pts[1]).Magnitude
		local total = 0
		for k = 1, RENDER_SAMPLES do
			total += (pts[k + 1] - pts[k]).Magnitude
		end
		local pos = 0
		while pos < total and self.used < 900 do
			while along > segLen and i < RENDER_SAMPLES do
				along -= segLen
				i += 1
				segLen = (pts[i + 1] - pts[i]).Magnitude
			end
			local t = (i - 1 + (if segLen > 0 then along / segLen else 0)) / RENDER_SAMPLES
			local untargetable = d.tStart >= 0 and t >= d.tStart and t <= d.tEnd
			local dash = if untargetable then DASH_UNTARGETABLE else DASH_TARGETABLE
			local gap = if untargetable then GAP_UNTARGETABLE else GAP_TARGETABLE
			local a, b = pts[i], pts[i + 1]
			local dir = if segLen > 0 then (b - a) / segLen else Vector2.xAxis
			local p = a + dir * (along + dash / 2)
			local intercepted = t >= d.tSam
			local f = self:_frame()
			f.Position = UDim2.fromOffset(p.X, p.Y)
			f.Size = UDim2.fromOffset(dash, LINE_PX)
			f.Rotation = math.deg(math.atan2(dir.Y, dir.X))
			f.BackgroundColor3 = if intercepted then INTERCEPT_COLOR else LINE_COLOR
			f.UIStroke.Color = if intercepted then INTERCEPT_OUTLINE else OUTLINE_COLOR
			along += dash + gap
			pos += dash + gap
		end
		-- Markers.
		local function marker(t: number, isX: boolean)
			local x, y = bezier(cp, t)
			local p = camera:screenPos(x + 0.5, y + 0.5)
			if isX then
				for _, rot in { 45, -45 } do
					local f = self:_frame()
					f.Position = UDim2.fromOffset(p.X, p.Y)
					f.Size = UDim2.fromOffset(MARKER_X_PX * 2, 3)
					f.Rotation = rot
					f.BackgroundColor3 = INTERCEPT_COLOR
					f.UIStroke.Color = Color3.new(0, 0, 0)
				end
			else
				local f = self:_frame()
				f.Position = UDim2.fromOffset(p.X, p.Y)
				f.Size = UDim2.fromOffset(MARKER_CIRCLE_PX * 2, MARKER_CIRCLE_PX * 2)
				f.UICorner.CornerRadius = UDim.new(0.5, 0)
				f.BackgroundTransparency = 1
				f.UIStroke.Color = LINE_COLOR
				f.UIStroke.Thickness = 2
			end
		end
		if d.tStart >= 0 then
			marker(d.tStart, false)
			if d.tEnd >= 0 then
				marker(d.tEnd, false)
			end
		end
		if d.tSam < 1.0 then
			marker(d.tSam, true)
		end
	end
	for k = self.used + 1, #self.pool do
		local f = self.pool[k]
		if not f.Visible then
			break
		end
		f.Visible = false
	end
end

return NukePreview
