-- Paste this entire file into Roblox Studio Command Bar in Edit mode.
-- First start props_roblox_to_json_start.cmd (helper.ps1). Select one Folder or Model.
-- Compatible with props_json_to_roblox.lua; only direct children become records.
-- Scene objects and selection are never changed.

type Axes = { x: number, y: number, z: number }
type Quaternion = { x: number, y: number, z: number, w: number }
type Asset = Model | BasePart
type Placement = {
	name: string,
	position: Axes,
	rotation: Quaternion,
	size: Axes,
	color: { [string]: string }?,
}

local HELPER_URL = "http://127.0.0.1:28743"
local SCALE_TOLERANCE = 1e-6
local httpService = game:GetService("HttpService")
local selectionService = game:GetService("Selection")
local serverStorage = game:GetService("ServerStorage")

local function axes(vector: Vector3): Axes
	return { x = vector.X, y = vector.Y, z = vector.Z }
end

local function quaternion(rotation: CFrame): Quaternion
	local axis, angle = rotation:ToAxisAngle()
	local sine = math.sin(angle / 2)
	return { x = axis.X * sine, y = axis.Y * sine, z = axis.Z * sine, w = math.cos(angle / 2) }
end

local function geometryParts(asset: Asset): { BasePart }
	-- The importer scales only the root of a standalone BasePart.
	if asset:IsA("BasePart") then
		return { asset }
	end
	local parts: { BasePart } = {}
	for _, descendant in ipairs(asset:GetDescendants()) do
		if descendant:IsA("BasePart") then
			table.insert(parts, descendant)
		end
	end
	return parts
end

local function colors(asset: Asset): { [string]: string }?
	local result: { [string]: string } = {}
	local firstParts: { [string]: BasePart } = {}
	local function addPart(part: BasePart)
		local firstPart = firstParts[part.Name]
		if firstPart then
			-- Check names only. Equal colors on different parts are allowed.
			-- Pass Instances separately so Output keeps clickable object links.
			warn("Повтор имени детали в пропе; для color оставлено первое вхождение:", asset, firstPart, part)
			return
		end
		firstParts[part.Name] = part
		result[part.Name] = "#" .. string.upper(part.Color:ToHex())
	end
	if asset:IsA("BasePart") then
		addPart(asset)
	end
	for index, descendant in ipairs(asset:GetDescendants()) do
		if descendant:IsA("BasePart") then
			addPart(descendant)
		end
		if index % 1000 == 0 then task.wait() end
	end
	return if next(result) then result else nil
end

local function absVector(vector: Vector3): Vector3
	return Vector3.new(math.abs(vector.X), math.abs(vector.Y), math.abs(vector.Z))
end

local function boundsSize(parts: { BasePart }, coordinateFrame: CFrame): Vector3
	local minimum = Vector3.new(math.huge, math.huge, math.huge)
	local maximum = Vector3.new(-math.huge, -math.huge, -math.huge)
	for index, part in ipairs(parts) do
		local frame = coordinateFrame:ToObjectSpace(part.CFrame)
		local halfSize = part.Size / 2
		local radius = absVector(frame.RightVector) * halfSize.X
			+ absVector(frame.UpVector) * halfSize.Y + absVector(frame.ZVector) * halfSize.Z
		minimum = minimum:Min(frame.Position - radius)
		maximum = maximum:Max(frame.Position + radius)
		if index % 1000 == 0 then task.wait() end
	end
	return maximum - minimum
end

local function snapScale(value: number): number
	assert(value > 0 and value < math.huge, "Не удалось определить положительный масштаб.")
	return if math.abs(value - 1) < SCALE_TOLERANCE then 1 else value
end

local function findScale(asset: Asset, template: Asset, placementRotation: CFrame): Vector3
	local assetParts, templateParts = geometryParts(asset), geometryParts(template)
	assert(#assetParts > 0, "В пропе «" .. asset.Name .. "» нет деталей BasePart.")
	assert(#assetParts == #templateParts, "Число деталей пропа «" .. asset.Name .. "» отличается от шаблона.")
	-- Undo placement rotation. The importer scales along the template's world axes.
	local assetBounds = boundsSize(assetParts, CFrame.new(asset:GetPivot().Position) * placementRotation)
	local templateBounds = boundsSize(templateParts, CFrame.new(template:GetPivot().Position))
	local ratio = assetBounds / templateBounds
	local scale = Vector3.new(snapScale(ratio.X), snapScale(ratio.Y), snapScale(ratio.Z))
	if asset:IsA("Model") and template:IsA("Model") then
		local uniform = asset:GetScale() / template:GetScale()
		if (scale - Vector3.one * uniform).Magnitude < math.max(1, uniform) * 1e-4 then
			scale = Vector3.one * snapScale(uniform)
		end
	end
	return scale
end

-- These operations deliberately mirror the supplied importer, including its
-- handling of PivotOffset and nonuniform scale before placement rotation.
local function scalePart(part: BasePart, scale: Vector3, origin: Vector3)
	local frame = part.CFrame
	local right = frame.RightVector * scale
	local up = frame.UpVector * scale
	local back = frame.ZVector * scale
	assert(math.abs(right.Unit:Dot(up.Unit)) < SCALE_TOLERANCE
		and math.abs(right.Unit:Dot(back.Unit)) < SCALE_TOLERANCE
		and math.abs(up.Unit:Dot(back.Unit)) < SCALE_TOLERANCE,
		"Импортёр не поддерживает такой разный масштаб по осям для наклонённой детали «" .. part.Name .. "».")
	local partScale = Vector3.new(right.Magnitude, up.Magnitude, back.Magnitude)
	local pivotOffset = part.PivotOffset
	part.Size *= partScale
	part.PivotOffset = CFrame.new(pivotOffset.Position * partScale) * pivotOffset.Rotation
	part.CFrame = CFrame.new(origin + (frame.Position - origin) * scale) * frame.Rotation
end

local function scaleAsset(asset: Asset, scale: Vector3, origin: Vector3)
	if scale == Vector3.one then return end
	if asset:IsA("BasePart") then
		scalePart(asset, scale, origin)
		return
	end
	local smallest = math.min(scale.X, scale.Y, scale.Z)
	local largest = math.max(scale.X, scale.Y, scale.Z)
	if largest - smallest <= largest * SCALE_TOLERANCE then
		asset:ScaleTo(asset:GetScale() * scale.X)
		return
	end
	if not asset.PrimaryPart then asset.WorldPivot = asset:GetPivot() end
	local descendants = asset:GetDescendants()
	for _, descendant in ipairs(descendants) do
		if descendant:IsA("Model") and not descendant.PrimaryPart then
			local pivot = descendant:GetPivot()
			descendant.WorldPivot = CFrame.new(origin + (pivot.Position - origin) * scale) * pivot.Rotation
		end
	end
	for index, descendant in ipairs(descendants) do
		if descendant:IsA("BasePart") then scalePart(descendant, scale, origin) end
		if index % 1000 == 0 then task.wait() end
	end
end

local function sameGeometry(expected: BasePart, actual: BasePart): boolean
	local sizeTolerance = 1e-4 * math.max(1, expected.Size.Magnitude)
	local positionTolerance = sizeTolerance + 1e-6 * expected.Position.Magnitude
	-- Imported CFrames may contain tiny nonorthogonal rounding errors. Comparing
	-- their relative axis-angle can report an angle even for IDENTICAL matrices.
	-- Compare the basis vectors directly instead.
	return (expected.Size - actual.Size).Magnitude <= sizeTolerance
		and (expected.Position - actual.Position).Magnitude <= positionTolerance
		and (expected.CFrame.RightVector - actual.CFrame.RightVector).Magnitude < 5e-4
		and (expected.CFrame.UpVector - actual.CFrame.UpVector).Magnitude < 5e-4
		and (expected.CFrame.ZVector - actual.CFrame.ZVector).Magnitude < 5e-4
end

local function validateReimport(asset: Asset, template: Asset, scale: Vector3, pivot: CFrame)
	assert(template.Archivable, "Включите Archivable у шаблона «" .. template.Name .. "».")
	local copy = template:Clone() :: Asset
	local success, problem = pcall(function()
		local originalPivot = copy:GetPivot()
		scaleAsset(copy, scale, originalPivot.Position)
		copy:PivotTo(pivot)
		local actualByName: { [string]: { BasePart } } = {}
		for _, part in ipairs(geometryParts(asset)) do
			local key = part.ClassName .. ":" .. part.Name
			actualByName[key] = actualByName[key] or {}
			table.insert(actualByName[key], part)
		end
		local expectedParts = geometryParts(copy)
		assert(#expectedParts == #geometryParts(asset), "Не все детали шаблона допускают клонирование (Archivable).")
		for index, expected in ipairs(expectedParts) do
			local bucket = actualByName[expected.ClassName .. ":" .. expected.Name]
			local matched: number? = nil
			if bucket then
				for candidateIndex, candidate in ipairs(bucket) do
					if sameGeometry(expected, candidate) then
						matched = candidateIndex
						break
					end
				end
			end
			assert(bucket and matched, "Геометрия пропа «" .. asset.Name
				.. "» отличается от масштабированного шаблона (деталь «" .. expected.Name
				.. "»). Этот JSON не сможет восстановить её точно.")
			table.remove(bucket :: { BasePart }, matched :: number)
			if index % 1000 == 0 then task.wait() end
		end
	end)
	copy:Destroy()
	assert(success, tostring(problem))
end

local function exportPlacement(asset: Asset, template: Asset): Placement
	local pivot = asset:GetPivot()
	local placementRotation = pivot.Rotation * template:GetPivot().Rotation:Inverse()
	local scale = findScale(asset, template, placementRotation)
	local exact, problem = pcall(validateReimport, asset, template, scale, pivot)
	if not exact then
		-- This file describes one transform per prop. It cannot preserve edits to
		-- individual parts. Keep exporting and explicitly report this limitation.
		warn("Проп экспортируется с масштабом по общим габаритам; шаблон не восстановит его геометрию точно:", asset)
		warn(tostring(problem))
	end
	return {
		name = asset.Name,
		position = axes(pivot.Position),
		rotation = quaternion(placementRotation),
		size = axes(scale),
		color = colors(asset),
	}
end

local function request(method: string, path: string, body: string?): any
	local options: any = {
		Url = HELPER_URL .. path,
		Method = method,
		Timeout = 10,
	}
	if body then
		options.Headers = { ["content-type"] = "application/json" }
		options.Body = body
	end
	local success, response = pcall(function() return httpService:RequestAsync(options) end)
	assert(success, "Нет связи с помощником. Запустите props_roblox_to_json_start.cmd и разрешите HTTP Requests. " .. tostring(response))
	local decoded = httpService:JSONDecode(response.Body)
	assert(response.Success, decoded.message or ("Помощник вернул HTTP " .. tostring(response.StatusCode)))
	return decoded
end

local function main()
	print("[Props JSON] Начало экспорта.")
	assert(not game:GetService("RunService"):IsRunning(), "Остановите Play перед экспортом.")
	local selected = selectionService:Get()
	assert(#selected == 1 and (selected[1]:IsA("Folder") or selected[1]:IsA("Model")),
		"Выделите ровно одну Folder или Model.")
	assert(httpService.HttpEnabled, "Включите Allow HTTP Requests в Experience Settings → Security.")
	print("[Props JSON] Проверка связи с помощником...")
	local health = request("GET", "/health", nil)
	assert(health.service == "props_roblox_to_json" and health.version == 1, "На порту помощника запущена другая программа.")
	local container = selected[1]
	local templatesFolder = serverStorage:FindFirstChild("Assets", true)
	assert(templatesFolder and templatesFolder:IsA("Folder"), "Не найдена папка ServerStorage.Assets с шаблонами.")
	local placements: { Placement } = {}
	print("[Props JSON] Чтение объектов из «" .. container.Name .. "»...")
	for index, child in ipairs(container:GetChildren()) do
		if child:IsA("Model") or child:IsA("BasePart") then
			local template = templatesFolder:FindFirstChild(child.Name, true)
			assert(template and (template:IsA("Model") or template:IsA("BasePart")), "Нет шаблона для пропа «" .. child.Name .. "».")
			assert(child:IsA("Model") == template:IsA("Model"), "Тип пропа «" .. child.Name .. "» отличается от шаблона.")
			local success, result = pcall(exportPlacement, child :: Asset, template :: Asset)
			if not success then
				warn("Не удалось экспортировать проп:", child)
				error(tostring(result), 0)
			end
			table.insert(placements, result :: Placement)
		else
			warn("Пропущен объект: нужен Model или BasePart.", child)
		end
		if index % 25 == 0 then
			print("[Props JSON] Обработано объектов: " .. index .. ". Пропов: " .. #placements)
			task.wait()
		end
	end
	-- JSONEncode({}) produces an object; the importer expects an array even when empty.
	local json = if #placements == 0 then "[]" else httpService:JSONEncode(placements)
	local exportId = httpService:GenerateGUID(false)
	print("[Props JSON] Собрано пропов: " .. #placements .. ". Передача данных помощнику...")
	request("POST", "/exports", httpService:JSONEncode({ id = exportId, name = container.Name, json = json }))
	print("Данные переданы помощнику. Выберите место сохранения JSON в окне Windows.")
	while true do
		task.wait(1)
		local status = request("GET", "/status/" .. exportId, nil)
		if status.state == "saved" then
			print("Экспортировано пропов: " .. #placements .. ". JSON сохранён: " .. status.path)
			return
		elseif status.state == "cancelled" then
			print("Сохранение JSON отменено.")
			return
		elseif status.state == "error" then
			error("Не удалось сохранить JSON: " .. tostring(status.message), 0)
		end
	end
end

-- Prevent accidental parallel runs while a Save As dialog is open.
local runningKey = "__props_roblox_to_json_running"
assert(not _G[runningKey], "Экспорт уже выполняется. Завершите предыдущее сохранение.")
_G[runningKey] = true
local success, problem = xpcall(main, debug.traceback)
_G[runningKey] = nil
if not success then error(tostring(problem), 0) end
