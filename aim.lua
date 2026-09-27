--!strict
--
-- AimAssist — single-script, client-side aim system with settings GUI.
-- Placement: StarterPlayer > StarterPlayerScripts as a **LocalScript**
-- (or a Script with RunContext = Client). It manipulates the local
-- camera only — no remotes, no server involvement.
--
-- Controls:
--   Right Mouse Button ..... hold to aim (active in all modes)
--   Right Shift ............ toggle settings window
--
-- Modes:
--   Legit ... smooth exponential camera pull toward target (held aim only)
--   Instant .. hard snap to target every frame while aim is held
--   Lock ..... sticky target acquisition per hold; hard lock until released
--

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
	-- Can happen if pasted into a server context; refuse to run.
	return
end

local Camera = workspace.CurrentCamera

--==============================================================================
-- CONFIG / STATE
--==============================================================================

type AimMode = "Legit" | "Instant" | "Lock"

local MODE_ORDER: { AimMode } = { "Legit", "Instant", "Lock" }

local Settings = {
	Enabled = true,
	FovRadius = 150, -- px, screen-space target radius
	Smoothness = 5, -- 1..10, maps to exponential pull rate
	NoFov = false, -- ignore FOV circle, target anywhere on screen
	Mode = "Legit" :: AimMode,
	FovColor = Color3.fromRGB(255, 64, 64),
}

local Runtime = {
	aimHeld = false,
	windowVisible = true,
	lockedTarget: Player? = nil,
	lastStep = os.clock(),
}

-- Central connection registry: everything dies together, no leaks.
local Connections: { RBXScriptConnection } = {}
local function track(conn: RBXScriptConnection): RBXScriptConnection
	table.insert(Connections, conn)
	return conn
end

local function cleanup()
	for _, conn in Connections do
		conn:Disconnect()
	end
	table.clear(Connections)
	RunService:UnbindFromRenderStep("AimAssistStep")
	RunService:UnbindFromRenderStep("AimAssistFovDraw")
end

--==============================================================================
-- TARGETING CORE
--==============================================================================

local RayParams = RaycastParams.new()
RayParams.FilterType = Enum.RaycastFilterType.Exclude
RayParams.IgnoreWater = true

local function getAimPart(player: Player): BasePart?
	local character = player.Character
	if not character then
		return nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return nil
	end
	local part = character:FindFirstChild("Head") :: BasePart?
		or character:FindFirstChild("HumanoidRootPart") :: BasePart?
	return part
end

local function isTargetVisible(targetPart: BasePart, targetCharacter: Model): boolean
	local character = LocalPlayer.Character
	if not character then
		return false
	end
	local origin = Camera.CFrame.Position
	local direction = targetPart.Position - origin
	-- Origin slightly forward so local head/hat meshes never occlude.
	local firstHit = workspace:Raycast(origin + direction.Unit * 1.5, direction.Magnitude * direction.Unit, RayParams)
	if not firstHit then
		return true
	end
	-- Hit something: visible only if that something belongs to the target.
	return firstHit.Instance:IsDescendantOf(targetCharacter)
end

-- Returns the best target player + its aim part for this frame, or nil.
local function acquireTarget(): (Player?, BasePart?)
	local character = LocalPlayer.Character
	if not character then
		return nil, nil
	end

	-- Lock mode: sticky target for the duration of a hold.
	if Settings.Mode == "Lock" and Runtime.lockedTarget then
		local part = getAimPart(Runtime.lockedTarget)
		if part then
			return Runtime.lockedTarget, part
		end
		Runtime.lockedTarget = nil -- target died/despawned, fall through to reacquire
	end

	local mouse = UserInputService:GetMouseLocation()
	local bestPlayer: Player? = nil
	local bestPart: BasePart? = nil
	local bestScore = math.huge

	for _, player in Players:GetPlayers() do
		if player == LocalPlayer then
			continue
		end
		local part = getAimPart(player)
		if not part then
			continue
		end
		if player.Character then
			RayParams.FilterDescendantsInstances = { character, player.Character :: Model, Camera }
		end

		local viewportPoint, onScreen = Camera:WorldToViewportPoint(part.Position)
		if not onScreen then
			continue
		end

		local screenPos = Vector2.new(viewportPoint.X, viewportPoint.Y)
		local distToCursor = (screenPos - mouse).Magnitude

		if not Settings.NoFov and distToCursor > Settings.FovRadius then
			continue
		end

		if not isTargetVisible(part, player.Character :: Model) then
			continue
		end

		if distToCursor < bestScore then
			bestScore = distToCursor
			bestPlayer = player
			bestPart = part
		end
	end

	if Settings.Mode == "Lock" and bestPlayer then
		Runtime.lockedTarget = bestPlayer
	end

	return bestPlayer, bestPart
end

--==============================================================================
-- CAMERA STEP
--==============================================================================

local function onStep()
	local now = os.clock()
	local dt = math.min(now - Runtime.lastStep, 0.05)
	Runtime.lastStep = now

	if not Settings.Enabled or not Runtime.aimHeld then
		if Settings.Mode == "Lock" then
			Runtime.lockedTarget = nil -- release sticky lock when aim is not held
		end
		return
	end

	local character = LocalPlayer.Character
	if not character then
		return
	end

	local _, aimPart = acquireTarget()
	if not aimPart then
		return
	end

	-- Lead slightly toward the head top for a stable visual anchor.
	local aimPosition = aimPart.Position
	local currentCF = Camera.CFrame
	local goalCF = CFrame.lookAt(currentCF.Position, aimPosition)

	if Settings.Mode == "Legit" then
		-- Exponential smoothing: frame-rate independent, stronger = snappier.
		local rate = Settings.Smoothness * 1.8
		local alpha = 1 - math.exp(-rate * dt)
		Camera.CFrame = currentCF:Lerp(goalCF, alpha)
	else
		-- Instant & Lock: hard servo every frame.
		Camera.CFrame = goalCF
	end
end

--==============================================================================
-- GUI FACTORY HELPERS
--==============================================================================

local function baseInstance(class: string, props: { [string]: any }, parent: Instance?): Instance
	local inst = Instance.new(class)
	for key, value in props do
		(inst :: any)[key] = value
	end
	inst.Parent = parent
	return inst
end

local function makeSlider(
	parent: Instance,
	labelText: string,
	minValue: number,
	maxValue: number,
	default: number,
	onChanged: (number) -> ()
): Frame
	local container = baseInstance("Frame", {
		Name = labelText,
		Size = UDim2.new(1, 0, 0, 34),
		BackgroundTransparency = 1,
		Parent = parent,
	}) :: Frame

	baseInstance("TextLabel", {
		Size = UDim2.new(0, 110, 0, 14),
		BackgroundTransparency = 1,
		Font = Enum.Font.Gotham,
		TextSize = 12,
		TextColor3 = Color3.fromRGB(220, 220, 220),
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = labelText,
		Parent = container,
	})

	local valueLabel = baseInstance("TextLabel", {
		Size = UDim2.new(0, 60, 0, 14),
		Position = UDim2.new(1, -60, 0, 0),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		TextSize = 12,
		TextColor3 = Color3.fromRGB(255, 255, 255),
		TextXAlignment = Enum.TextXAlignment.Right,
		Text = tostring(default),
		Parent = container,
	}) :: TextLabel

	local sliderTrack = baseInstance("Frame", {
		Size = UDim2.new(1, 0, 0, 6),
		Position = UDim2.new(0, 0, 0, 22),
		BackgroundColor3 = Color3.fromRGB(50, 50, 55),
		BorderSizePixel = 0,
		Parent = container,
	}) :: Frame
	baseInstance("UICorner", { CornerRadius = UDim.new(1, 0), Parent = sliderTrack })

	local fill = baseInstance("Frame", {
		Size = UDim2.new((default - minValue) / (maxValue - minValue), 0, 1, 0),
		BackgroundColor3 = Color3.fromRGB(120, 170, 255),
		BorderSizePixel = 0,
		Parent = sliderTrack,
	}) :: Frame
	baseInstance("UICorner", { CornerRadius = UDim.new(1, 0), Parent = fill })

	local knob = baseInstance("Frame", {
		Size = UDim2.new(0, 12, 0, 12),
		Position = UDim2.new((default - minValue) / (maxValue - minValue), -6, 0.5, -6),
		BackgroundColor3 = Color3.fromRGB(255, 255, 255),
		BorderSizePixel = 0,
		Parent = sliderTrack,
	}) :: Frame
	baseInstance("UICorner", { CornerRadius = UDim.new(1, 0), Parent = knob })

	local function setValueFromX(x: number)
		local rel = (x - sliderTrack.AbsolutePosition.X) / math.max(sliderTrack.AbsoluteSize.X, 1)
		rel = math.clamp(rel, 0, 1)
		local value = minValue + rel * (maxValue - minValue)
		value = math.floor(value * 10 + 0.5) / 10 -- 0.1 granularity
		valueLabel.Text = tostring(value)
		fill.Size = UDim2.new(rel, 0, 1, 0)
		knob.Position = UDim2.new(rel, -6, 0.5, -6)
		onChanged(value)
	end

	local dragging = false
	track(sliderTrack.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			setValueFromX(input.Position.X)
		end
	end))
	track(sliderTrack.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end))
	track(UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			setValueFromX(input.Position.X)
		end
	end))

	return container
end

local function makeToggle(parent: Instance, labelText: string, default: boolean, onChanged: (boolean) -> ())
	local button = baseInstance("TextButton", {
		Size = UDim2.new(1, 0, 0, 26),
		BackgroundColor3 = Color3.fromRGB(40, 40, 45),
		BorderSizePixel = 0,
		Font = Enum.Font.Gotham,
		TextSize = 13,
		TextColor3 = Color3.fromRGB(220, 220, 220),
		Text = labelText,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = parent,
	}) :: TextButton
	baseInstance("UIPadding", { PaddingLeft = UDim.new(0, 8), Parent = button })

	local indicator = baseInstance("Frame", {
		Size = UDim2.new(0, 34, 0, 14),
		Position = UDim2.new(1, -42, 0.5, -7),
		BackgroundColor3 = default and Color3.fromRGB(90, 200, 120) or Color3.fromRGB(70, 70, 75),
		BorderSizePixel = 0,
		Parent = button,
	}) :: Frame
	baseInstance("UICorner", { CornerRadius = UDim.new(1, 0), Parent = indicator })

	local state = default
	track(button.Activated:Connect(function()
		state = not state
		indicator.BackgroundColor3 = state and Color3.fromRGB(90, 200, 120) or Color3.fromRGB(70, 70, 75)
		onChanged(state)
	end))
end

local function makeModeCycle(parent: Instance, onModeChanged: (AimMode) -> ())
	local button = baseInstance("TextButton", {
		Size = UDim2.new(1, 0, 0, 26),
		BackgroundColor3 = Color3.fromRGB(40, 40, 45),
		BorderSizePixel = 0,
		Font = Enum.Font.GothamBold,
		TextSize = 13,
		TextColor3 = Color3.fromRGB(255, 255, 255),
		Text = "Mode: Legit",
		Parent = parent,
	}) :: TextButton

	local index = 1
	track(button.Activated:Connect(function()
		index = index % #MODE_ORDER + 1
		local mode = MODE_ORDER[index]
		button.Text = "Mode: " .. mode
		onModeChanged(mode)
	end))
end

local function makeHueSlider(parent: Instance, defaultColor: Color3, onChanged: (Color3) -> ())
	local container = baseInstance("Frame", {
		Name = "FovColor",
		Size = UDim2.new(1, 0, 0, 34),
		BackgroundTransparency = 1,
		Parent = parent,
	}) :: Frame

	baseInstance("TextLabel", {
		Size = UDim2.new(0, 110, 0, 14),
		BackgroundTransparency = 1,
		Font = Enum.Font.Gotham,
		TextSize = 12,
		TextColor3 = Color3.fromRGB(220, 220, 220),
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "FOV Color",
		Parent = container,
	})

	local preview = baseInstance("Frame", {
		Size = UDim2.new(0, 46, 0, 14),
		Position = UDim2.new(1, -52, 0, 0),
		BackgroundColor3 = defaultColor,
		BorderSizePixel = 0,
		Parent = container,
	}) :: Frame
	baseInstance("UICorner", { CornerRadius = UDim.new(0, 4), Parent = preview })

	local hueTrack = baseInstance("Frame", {
		Size = UDim2.new(1, 0, 0, 6),
		Position = UDim2.new(0, 0, 0, 22),
		BackgroundColor3 = Color3.fromRGB(255, 255, 255),
		BorderSizePixel = 0,
		Parent = container,
	}) :: Frame
	baseInstance("UICorner", { CornerRadius = UDim.new(1, 0), Parent = hueTrack })

	-- Rainbow gradient = full hue sweep, saturated & bright.
	baseInstance("UIGradient", {
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 0, 0)),
			ColorSequenceKeypoint.new(0.17, Color3.fromRGB(255, 255, 0)),
			ColorSequenceKeypoint.new(0.33, Color3.fromRGB(0, 255, 0)),
			ColorSequenceKeypoint.new(0.5, Color3.fromRGB(0, 255, 255)),
			ColorSequenceKeypoint.new(0.67, Color3.fromRGB(0, 0, 255)),
			ColorSequenceKeypoint.new(0.83, Color3.fromRGB(255, 0, 255)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 0, 0)),
		}),
		Parent = hueTrack,
	})

	local knob = baseInstance("Frame", {
		Size = UDim2.new(0, 4, 0, 14),
		Position = UDim2.new(0, -2, 0.5, -7),
		BackgroundColor3 = Color3.fromRGB(255, 255, 255),
		BorderSizePixel = 0,
		Parent = hueTrack,
	}) :: Frame

	local function setHueFromX(x: number)
		local rel = math.clamp((x - hueTrack.AbsolutePosition.X) / math.max(hueTrack.AbsoluteSize.X, 1), 0, 1)
		knob.Position = UDim2.new(rel, -2, 0.5, -7)
		local color = Color3.fromHSV(rel, 1, 1)
		preview.BackgroundColor3 = color
		onChanged(color)
	end

	local dragging = false
	track(hueTrack.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			setHueFromX(input.Position.X)
		end
	end))
	track(hueTrack.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end))
	track(UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			setHueFromX(input.Position.X)
		end
	end))
end

--==============================================================================
-- GUI CONSTRUCTION
--==============================================================================

-- FOV circle lives in its own ScreenGui with IgnoreGuiInset so that its
-- coordinate space matches UserInputService:GetMouseLocation() and
-- Camera:WorldToViewportPoint() exactly (viewport space, inset ignored).
local fovGui = baseInstance("ScreenGui", {
	Name = "AimAssistFovGui",
	ResetOnSpawn = false,
	IgnoreGuiInset = true,
	DisplayOrder = 5,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
})

local fovCircle = baseInstance("Frame", {
	Name = "FovCircle",
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromOffset(0, 0),
	Size = UDim2.fromOffset(Settings.FovRadius * 2, Settings.FovRadius * 2),
	BackgroundTransparency = 1,
	Visible = false,
	Parent = fovGui,
}) :: Frame
baseInstance("UICorner", { CornerRadius = UDim.new(1, 0), Parent = fovCircle })
baseInstance("UIStroke", {
	Color = Settings.FovColor,
	Thickness = 2,
	Transparency = 0.2,
	ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	Parent = fovCircle,
})

local gui = baseInstance("ScreenGui", {
	Name = "AimAssistGui",
	ResetOnSpawn = false,
	DisplayOrder = 10,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
})

local window = baseInstance("Frame", {
	Name = "Window",
	Size = UDim2.fromOffset(230, 320),
	Position = UDim2.fromOffset(24, 24),
	BackgroundColor3 = Color3.fromRGB(28, 28, 32),
	BorderSizePixel = 0,
	Active = true,
	Parent = gui,
}) :: Frame
baseInstance("UICorner", { CornerRadius = UDim.new(0, 6), Parent = window })

local titleBar = baseInstance("Frame", {
	Name = "TitleBar",
	Size = UDim2.new(1, 0, 0, 28),
	BackgroundColor3 = Color3.fromRGB(22, 22, 26),
	BorderSizePixel = 0,
	Parent = window,
}) :: Frame
baseInstance("UICorner", { CornerRadius = UDim.new(0, 6), Parent = titleBar })

baseInstance("TextLabel", {
	Size = UDim2.new(1, -16, 1, 0),
	Position = UDim2.fromOffset(10, 0),
	BackgroundTransparency = 1,
	Font = Enum.Font.GothamBold,
	TextSize = 13,
	TextColor3 = Color3.fromRGB(255, 255, 255),
	TextXAlignment = Enum.TextXAlignment.Left,
	Text = "Aim Assist",
	Parent = titleBar,
})

local content = baseInstance("Frame", {
	Name = "Content",
	Size = UDim2.new(1, -16, 1, -28),
	Position = UDim2.fromOffset(8, 32),
	BackgroundTransparency = 1,
	Parent = window,
}) :: Frame

baseInstance("UIListLayout", {
	Padding = UDim.new(0, 4),
	SortOrder = Enum.SortOrder.LayoutOrder,
	Parent = content,
})

-- --- Controls wiring -------------------------------------------------------

local statusLabel = baseInstance("TextLabel", {
	Size = UDim2.new(1, 0, 0, 16),
	BackgroundTransparency = 1,
	Font = Enum.Font.Gotham,
	TextSize = 12,
	TextColor3 = Color3.fromRGB(140, 200, 140),
	TextXAlignment = Enum.TextXAlignment.Left,
	Text = "Idle — hold RMB to aim",
	Parent = content,
}) :: TextLabel

makeSlider(content, "Aimbot FOV", 20, 500, Settings.FovRadius, function(value)
	Settings.FovRadius = value
	fovCircle.Size = UDim2.fromOffset(value * 2, value * 2)
end).LayoutOrder = 1

makeSlider(content, "Speed (smoothness)", 1, 10, Settings.Smoothness, function(value)
	Settings.Smoothness = value
end).LayoutOrder = 2

makeToggle(content, "No FOV (anywhere)", Settings.NoFov, function(state)
	Settings.NoFov = state
	fovCircle.Visible = Settings.Enabled and not state
end).LayoutOrder = 3

makeModeCycle(content, function(mode)
	Settings.Mode = mode
	Runtime.lockedTarget = nil
end).LayoutOrder = 4

makeHueSlider(content, Settings.FovColor, function(color)
	Settings.FovColor = color
	(fovCircle:FindFirstChildOfClass("UIStroke") :: UIStroke).Color = color
end).LayoutOrder = 5

makeToggle(content, "Enabled", Settings.Enabled, function(state)
	Settings.Enabled = state
	Runtime.lockedTarget = nil
	fovCircle.Visible = state and not Settings.NoFov
end).LayoutOrder = 6

--==============================================================================
-- INPUT
--==============================================================================

track(UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then
		return
	end
	if input.UserInputType == Enum.UserInputType.MouseButton2 then
		Runtime.aimHeld = true
		Runtime.lastStep = os.clock()
	elseif input.KeyCode == Enum.KeyCode.RightShift then
		Runtime.windowVisible = not Runtime.windowVisible
		window.Visible = Runtime.windowVisible
	end
end))

track(UserInputService.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton2 then
		Runtime.aimHeld = false
		Runtime.lockedTarget = nil
	end
end))

-- Window dragging (title bar grip).
do
	local dragActive = false
	local dragStart: Vector3? = nil
	local startPos: UDim2? = nil

	track(titleBar.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragActive = true
			dragStart = input.Position
			startPos = window.Position
		end
	end))
	track(titleBar.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragActive = false
		end
	end))
	track(UserInputService.InputChanged:Connect(function(input)
		if not dragActive or not dragStart or not startPos then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
			local delta = input.Position - dragStart
			window.Position = UDim2.new(
				startPos.X.Scale,
				startPos.X.Offset + delta.X,
				startPos.Y.Scale,
				startPos.Y.Offset + delta.Y
			)
		end
	end))
end

--==============================================================================
-- LIFECYCLE
--==============================================================================

track(workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
	local nextCamera = workspace.CurrentCamera
	if nextCamera then
		Camera = nextCamera
	end
end))

track(Players.PlayerRemoving:Connect(function(player)
	if Runtime.lockedTarget == player then
		Runtime.lockedTarget = nil
	end
end))

track(fovGui.Destroying:Connect(cleanup))
track(gui.Destroying:Connect(cleanup))
track(LocalPlayer.CharacterRemoving:Connect(function()
	Runtime.lockedTarget = nil
end))

RunService:BindToRenderStep("AimAssistStep", Enum.RenderPriority.Camera.Value + 1, onStep)

-- FOV circle follows cursor; render after camera step so it never trails.
RunService:BindToRenderStep("AimAssistFovDraw", Enum.RenderPriority.Camera.Value + 2, function()
	local mouse = UserInputService:GetMouseLocation()
	fovCircle.Position = UDim2.fromOffset(mouse.X, mouse.Y)
	fovCircle.Visible = Settings.Enabled and not Settings.NoFov
end)
