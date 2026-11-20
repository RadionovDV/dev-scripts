-- Paste this entire file into Roblox Studio Command Bar in Edit mode.
-- First start props_roblox_to_json_start.cmd (helper.ps1). Select one Folder or Model.
-- Compatible with props_json_to_roblox.lua; only direct children become records.
-- Scene objects and selection are never changed.

type Axes = { x: number, y: number, z: number }
type Quaternion = { x: number, y: number, z: number, w: number }
type Asset = Model | BasePart
type ModelPart = { instance: BasePart, relativeFrame: CFrame }
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

local function withoutNumericSuffix(objectName: string): string
	return (objectName:gsub("%.[0-9][0-9][0-9]$", ""))
end

local function axes(vector: Vector3): Axes
	return { x = vector.X, y = vector.Y, z = vector.Z }
end

local function quaternion(rotation: CFrame): Quaternion
	local axis, angle = rotation:ToAxisAngle()
	local sine = math.sin(angle / 2)
	return { x = axis.X * sine, y = axis.Y * sine, z = axis.Z * sine, w = math.cos(angle / 2) }
end

local function colors(asset: Asset): { [string]: string }?
	local result: { [string]: string } = {}
	local firstParts: { [string]: BasePart } = {}
	local function addPart(part: BasePart)
		local colorName = withoutNumericSuffix(part.Name)
		local firstPart = firstParts[colorName]
		if firstPart then
			-- Check names only. Equal colors on different parts are allowed.
			-- Pass Instances separately so Output keeps clickable object links.
			warn("Повтор имени детали «" .. colorName .. "» в пропе; для color оставлено первое вхождение:", asset, firstPart, part)
			return
		end
		firstParts[colorName] = part
		result[colorName] = "#" .. string.upper(part.Color:ToHex())
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

local function snapScale(value: number): number
	assert(value > 0 and value < math.huge, "Не удалось определить положительный масштаб.")
	return if math.abs(value - 1) < SCALE_TOLERANCE then 1 else value
end

local function partScaleForImport(asset: BasePart, template: BasePart): Vector3
	local ratio = asset.Size / template.Size
	local localScale = Vector3.new(snapScale(ratio.X), snapScale(ratio.Y), snapScale(ratio.Z))
	if localScale.X == localScale.Y and localScale.Y == localScale.Z then
		return localScale
	end

	-- Size uses the part's local axes. The importer scales in the template's
	-- world axes before placement, so map the three multipliers to those axes.
	local frame = template.CFrame
	local worldScale = Vector3.new(
		snapScale((frame:VectorToObjectSpace(Vector3.xAxis) * localScale).Magnitude),
		snapScale((frame:VectorToObjectSpace(Vector3.yAxis) * localScale).Magnitude),
		snapScale((frame:VectorToObjectSpace(Vector3.zAxis) * localScale).Magnitude)
	)
	local right = frame.RightVector * worldScale
	local up = frame.UpVector * worldScale
	local back = frame.ZVector * worldScale
	if math.abs(right.Unit:Dot(up.Unit)) >= SCALE_TOLERANCE
		or math.abs(right.Unit:Dot(back.Unit)) >= SCALE_TOLERANCE
		or math.abs(up.Unit:Dot(back.Unit)) >= SCALE_TOLERANCE then
		warn("Импортёр не поддерживает такой разный масштаб для наклонённого шаблона. Сохранён средний масштаб:", asset, template)
		return Vector3.one * snapScale((localScale.X + localScale.Y + localScale.Z) / 3)
	end
	local reproducedScale = Vector3.new(right.Magnitude, up.Magnitude, back.Magnitude)
	if (reproducedScale - localScale).Magnitude > 1e-5 * math.max(1, localScale.Magnitude) then
		warn("Импортёр не поддерживает такой разный масштаб для наклонённого шаблона. Сохранено приближение:", asset, template)
	end
	return worldScale
end

local function modelParts(model: Model): { ModelPart }
	local pivot = model:GetPivot()
	local parts: { ModelPart } = {}
	for index, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") then
			local offset = pivot:VectorToObjectSpace(descendant.Position - pivot.Position)
			local rotation = pivot.Rotation:ToObjectSpace(descendant.CFrame.Rotation)
			table.insert(parts, { instance = descendant, relativeFrame = CFrame.new(offset) * rotation })
		end
		if index % 1000 == 0 then task.wait() end
	end
	return parts
end

local function sameGeometry(expected: ModelPart, actual: ModelPart): boolean
	local expectedFrame, actualFrame = expected.relativeFrame, actual.relativeFrame
	local sizeTolerance = 1e-4 * math.max(1, expected.instance.Size.Magnitude)
	local positionTolerance = sizeTolerance + 1e-6 * math.max(expected.instance.Position.Magnitude, actual.instance.Position.Magnitude)
	return (expected.instance.Size - actual.instance.Size).Magnitude <= sizeTolerance
		and (expectedFrame.Position - actualFrame.Position).Magnitude <= positionTolerance
		and (expectedFrame.RightVector - actualFrame.RightVector).Magnitude < 5e-4
		and (expectedFrame.UpVector - actualFrame.UpVector).Magnitude < 5e-4
		and (expectedFrame.ZVector - actualFrame.ZVector).Magnitude < 5e-4
end

local function compareModelParts(asset: Model, expectedModel: Model)
	local actualParts, expectedParts = modelParts(asset), modelParts(expectedModel)
	local matched: { [BasePart]: boolean } = {}
	local function matchByName(nameKey: (string) -> string)
		local expectedByName: { [string]: { ModelPart } } = {}
		for _, expected in ipairs(expectedParts) do
			if not matched[expected.instance] then
				local key = expected.instance.ClassName .. ":" .. nameKey(expected.instance.Name)
				local bucket = expectedByName[key] or {}
				table.insert(bucket, expected)
				expectedByName[key] = bucket
			end
		end

		-- With repeated names, pair the unchanged parts before reporting any edits.
		for _, requireSameGeometry in ipairs({ true, false }) do
			for index, actual in ipairs(actualParts) do
				local part = actual.instance
				if not matched[part] then
					local bucket = expectedByName[part.ClassName .. ":" .. nameKey(part.Name)]
					if bucket then
						for candidateIndex, expected in ipairs(bucket) do
							if not requireSameGeometry or sameGeometry(expected, actual) then
								matched[part] = true
								matched[expected.instance] = true
								table.remove(bucket, candidateIndex)
								if not requireSameGeometry then
									warn("Размер, положение или поворот детали отличаются от шаблона с учётом масштаба модели:", asset, part)
								end
								break
							end
						end
					end
				end
				if index % 1000 == 0 then task.wait() end
			end
		end
	end
	matchByName(function(partName: string): string return partName end)
	matchByName(withoutNumericSuffix)

	for _, actual in ipairs(actualParts) do
		if not matched[actual.instance] then
			warn("Для детали модели не найдено соответствие в шаблоне:", asset, actual.instance)
		end
	end
	for _, expected in ipairs(expectedParts) do
		if not matched[expected.instance] then
			warn("В модели не найдена деталь шаблона «" .. expected.instance.Name .. "»:", asset)
		end
	end
end

local function checkModelGeometry(asset: Model, template: Model, scale: number)
	local copy = template:Clone()
	if not copy then
		warn("Не удалось скопировать шаблон для проверки геометрии модели:", asset, template)
		return
	end
	local success, problem = pcall(function()
		if scale ~= 1 then
			copy:ScaleTo(template:GetScale() * scale)
		end
		compareModelParts(asset, copy)
	end)
	copy:Destroy()
	if not success then
		warn("Не удалось проверить геометрию модели: " .. tostring(problem), asset)
	end
end

local function exportPlacement(asset: Asset, template: Asset): Placement
	local pivot = asset:GetPivot()
	local placementRotation = pivot.Rotation * template:GetPivot().Rotation:Inverse()
	local scale: Vector3
	if asset:IsA("Model") and template:IsA("Model") then
		local modelScale = snapScale(asset:GetScale() / template:GetScale())
		scale = Vector3.one * modelScale
		checkModelGeometry(asset, template, modelScale)
	else
		assert(asset:IsA("BasePart") and template:IsA("BasePart"), "Тип пропа отличается от шаблона.")
		scale = partScaleForImport(asset, template)
	end
	return {
		name = template.Name,
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
			local templateName = withoutNumericSuffix(child.Name)
			local template = templatesFolder:FindFirstChild(templateName, true)
			assert(template and (template:IsA("Model") or template:IsA("BasePart")),
				"Не найден шаблон «" .. templateName .. "» для пропа «" .. child.Name .. "».")
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
