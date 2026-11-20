-- Imports object placements from JSON. Clones templates from ServerStorage.Assets
-- into Workspace.Props and applies position, rotation, scale, and part colors.
-- Run this script from the Roblox Studio Command Bar in Edit mode.

type Axes = { x: number, y: number, z: number }
type Quaternion = { x: number, y: number, z: number, w: number }
type MeshColors = { [string]: string }

type AssetPlacement = {
	name: string,
	position: Axes,
	rotation: Quaternion?,
	size: Axes?,
	color: MeshColors?,
}

local studioService = game:GetService("StudioService")
local httpService = game:GetService("HttpService")
local serverStorage = game:GetService("ServerStorage")
local workspace = game:GetService("Workspace")

local ASSET_FOLDER = "Assets"
local INSTANCE_FOLDER = "Props"
local SCALE_TOLERANCE = 1e-6

local function applyAssetColors(asset: Model | BasePart, meshColors: MeshColors?)
	-- Старые JSON без color сохраняют цвета шаблона.
	if meshColors == nil then
		return
	end
	assert(typeof(meshColors) == "table", "Поле color ассета «" .. asset.Name .. "» должно содержать имена мешей и HEX-цвета.")

	local colorsByMeshName: { [string]: Color3 } = {}
	for meshName, hexColor in pairs(meshColors) do
		assert(typeof(meshName) == "string", "Ключи color ассета «" .. asset.Name .. "» должны быть именами мешей.")
		assert(
			typeof(hexColor) == "string" and string.match(hexColor, "^#%x%x%x%x%x%x$") ~= nil,
			"Цвет меша «" .. meshName .. "» в ассете «" .. asset.Name .. "» должен иметь формат #RRGGBB."
		)
		colorsByMeshName[meshName] = Color3.fromRGB(
			tonumber(string.sub(hexColor, 2, 3), 16) :: number,
			tonumber(string.sub(hexColor, 4, 5), 16) :: number,
			tonumber(string.sub(hexColor, 6, 7), 16) :: number
		)
	end

	local matchedMeshNames: { [string]: boolean } = {}
	local function applyPartColor(part: BasePart)
		local meshColor = colorsByMeshName[part.Name]
		if meshColor then
			part.Color = meshColor
			matchedMeshNames[part.Name] = true
		end
	end

	if asset:IsA("BasePart") then
		applyPartColor(asset)
	end
	for _, descendant in ipairs(asset:GetDescendants()) do
		if descendant:IsA("BasePart") then
			applyPartColor(descendant)
		end
	end

	for meshName in pairs(colorsByMeshName) do
		assert(matchedMeshNames[meshName], "В ассете «" .. asset.Name .. "» не найден меш «" .. meshName .. "» из поля color.")
	end
end

local function scalePart(part: BasePart, scale: Vector3, assetOrigin: Vector3, assetName: string)
	local partFrame = part.CFrame
	local scaledRight = partFrame.RightVector * scale
	local scaledUp = partFrame.UpVector * scale
	local scaledBack = partFrame.ZVector * scale
	local right, up, back = scaledRight.Unit, scaledUp.Unit, scaledBack.Unit
	assert(
		math.abs(right:Dot(up)) < SCALE_TOLERANCE
			and math.abs(right:Dot(back)) < SCALE_TOLERANCE
			and math.abs(up:Dot(back)) < SCALE_TOLERANCE,
		"Разный масштаб по осям деформирует наклонённую деталь «" .. part.Name .. "» в ассете «" .. assetName .. "»."
	)

	local partScale = Vector3.new(scaledRight.Magnitude, scaledUp.Magnitude, scaledBack.Magnitude)
	local pivotOffset = part.PivotOffset
	part.Size *= partScale
	part.PivotOffset = CFrame.new(pivotOffset.Position * partScale) * pivotOffset.Rotation
	part.CFrame = CFrame.new(assetOrigin + (partFrame.Position - assetOrigin) * scale) * partFrame.Rotation
end

local function scaleAsset(asset: Model | BasePart, scale: Vector3, assetOrigin: Vector3)
	if scale == Vector3.one then
		return
	end

	local smallest = math.min(scale.X, scale.Y, scale.Z)
	local largest = math.max(scale.X, scale.Y, scale.Z)
	assert(smallest > 0 and largest < math.huge, "Масштаб ассета «" .. asset.Name .. "» должен быть положительным и конечным.")

	if asset:IsA("BasePart") then
		scalePart(asset, scale, assetOrigin, asset.Name)
		return
	end

	if largest - smallest <= largest * SCALE_TOLERANCE then
		asset:ScaleTo(asset:GetScale() * scale.X)
		return
	end

	local descendants = asset:GetDescendants()
	if not asset.PrimaryPart then
		asset.WorldPivot = asset:GetPivot()
	end
	for _, descendant in ipairs(descendants) do
		if descendant:IsA("Model") and not descendant.PrimaryPart then
			local pivot = descendant:GetPivot()
			descendant.WorldPivot = CFrame.new(assetOrigin + (pivot.Position - assetOrigin) * scale) * pivot.Rotation
		end
	end
	for _, descendant in ipairs(descendants) do
		if descendant:IsA("BasePart") then
			scalePart(descendant, scale, assetOrigin, asset.Name)
		end
	end
end

assert(not game:GetService("RunService"):IsRunning(), "Остановите Play перед импортом.")

local templatesFolder = serverStorage:FindFirstChild(ASSET_FOLDER, true)
assert(templatesFolder and templatesFolder:IsA("Folder"), `Создайте папку ServerStorage.{ASSET_FOLDER} с шаблонами.`)
assert(not workspace:FindFirstChild(INSTANCE_FOLDER), `Папка Workspace.{INSTANCE_FOLDER} уже существует.`)

local placementFile = studioService:PromptImportFileAsync({ "json" })
if not placementFile then
	return
end

local placements: { AssetPlacement } = httpService:JSONDecode(placementFile:GetBinaryContents())

local templatesByName: { [string]: Model | BasePart } = {}
for _, placement in ipairs(placements) do
	local template = templatesFolder:FindFirstChild(placement.name, true)
	assert(template, `В {ASSET_FOLDER} нет шаблона « {placement.name} ».`)
	assert(template:IsA("Model") or template:IsA("BasePart"), "Шаблон «" .. placement.name .. "» должен быть Model или BasePart.")
	assert(template.Archivable, "Включите Archivable у шаблона «" .. placement.name .. "».")
	templatesByName[placement.name] = template
end

local placedAssets = Instance.new("Folder")
placedAssets.Name = INSTANCE_FOLDER

for _, placement in ipairs(placements) do
	local template = templatesByName[placement.name]
	local assetCopy = template:Clone()
	local position = placement.position
	local rotation = placement.rotation
	local size = placement.size
	local originalPivot = assetCopy:GetPivot()

	applyAssetColors(assetCopy, placement.color)

	if size then
		scaleAsset(assetCopy, Vector3.new(size.x, size.y, size.z), originalPivot.Position)
	end

	local placementFrame = if rotation
		then CFrame.new(position.x, position.y, position.z, rotation.x, rotation.y, rotation.z, rotation.w)
		else CFrame.new(position.x, position.y, position.z)
	-- Шаблоны уже ориентированы в Roblox. Применяем поворот к их исходной ориентации.
	assetCopy:PivotTo(placementFrame * originalPivot.Rotation)
	assetCopy.Parent = placedAssets
end

placedAssets.Parent = workspace
print("Размещено объектов: " .. #placements)
