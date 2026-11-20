"""Импорт пропов из JSON, созданного скриптом props_blender_to_json.py.

В Object Mode выделите коллекцию шаблонов в Outliner (режим View Layer).
Откройте этот скрипт в Text Editor, нажмите Run Script и выберите JSON.
Коллекция с копиями появится в корне сцены под именем файла без .json.
"""

import json
import math
import re
from pathlib import Path

import bpy
from bpy.props import StringProperty
from bpy_extras.io_utils import ImportHelper


# Значение должно совпадать с настройкой экспортёра.
STUDS_PER_BLENDER_UNIT = 1.0
BLENDER_DUPLICATE_SUFFIX = re.compile(r"(?<=.)\.[0-9]{3,}\Z")
HEX_COLOR = re.compile(r"#[0-9a-fA-F]{6}\Z")
WHITE_RGB = (1.0, 1.0, 1.0)


def get_selected_collection(context):
    selected_collections = set()
    for area in context.screen.areas:
        if area.type != "OUTLINER" or area.spaces.active.display_mode != "VIEW_LAYER":
            continue
        region = next(region for region in area.regions if region.type == "WINDOW")
        with context.temp_override(area=area, region=region):
            selected_collections.update(
                item for item in context.selected_ids
                if isinstance(item, bpy.types.Collection)
            )

    if len(selected_collections) != 1:
        raise ValueError("Выделите одну коллекцию в Outliner в режиме View Layer.")
    return selected_collections.pop()


def read_axes(data, axes, label):
    values = []
    for axis in axes:
        value = data.get(axis) if isinstance(data, dict) else None
        if type(value) not in (int, float) or not -3.4028235e38 <= value <= 3.4028235e38:
            raise ValueError(f"{label}.{axis} должно быть конечным числом Blender.")
        values.append(float(value))
    return tuple(values)


def read_colors(data):
    if not isinstance(data, dict):
        raise ValueError("Поле color должно содержать имена и цвета в формате #RRGGBB.")

    colors = {}
    for target_name, hex_color in data.items():
        if not isinstance(hex_color, str) or not HEX_COLOR.fullmatch(hex_color):
            raise ValueError(f"Цвет «{target_name}» должен иметь формат #RRGGBB.")
        colors[target_name] = tuple(
            int(hex_color[start:start + 2], 16) / 255 for start in (1, 3, 5)
        )
    return colors


def get_mesh_color_targets(template, template_name, colors):
    """Находит грани по тому же правилу, что и экспортёр."""
    mesh = template.data
    if not template.vertex_groups:
        if colors.keys() != {template_name}:
            raise ValueError(f"В поле color ожидается цвет «{template_name}».")
        return {polygon.index: colors[template_name] for polygon in mesh.polygons}

    group_names = {}
    for group in template.vertex_groups:
        group_name = BLENDER_DUPLICATE_SUFFIX.sub("", group.name)
        if group_name in group_names:
            raise ValueError(f"Несколько групп вершин имеют одинаковое имя «{group_name}».")
        group_names[group_name] = group.index

    unknown_names = colors.keys() - group_names.keys()
    if unknown_names:
        raise ValueError(f"Нет групп вершин: {', '.join(sorted(unknown_names))}.")

    colors_by_group = {group_names[name]: color for name, color in colors.items()}
    memberships = [
        {entry.group for entry in vertex.groups
         if entry.weight > 0.0 and entry.group in colors_by_group}
        for vertex in mesh.vertices
    ]
    face_colors = {}
    matched_groups = set()
    for polygon in mesh.polygons:
        groups = set.intersection(*(memberships[index] for index in polygon.vertices))
        if not groups:
            continue
        assigned_colors = {colors_by_group[group_index] for group_index in groups}
        if len(assigned_colors) > 1:
            raise ValueError(f"Грань {polygon.index} входит в группы с разными цветами.")
        face_colors[polygon.index] = assigned_colors.pop()
        matched_groups.update(groups)

    for group_name, color in colors.items():
        if color != WHITE_RGB and group_names[group_name] not in matched_groups:
            raise ValueError(f"В группе «{group_name}» нет целых граней для окраски.")
    return face_colors


def prepare_placements(file_path, source_collection):
    with file_path.open(encoding="utf-8-sig") as json_file:
        records = json.load(json_file)
    if not isinstance(records, list):
        raise ValueError("В JSON ожидается список пропов.")

    exact_names = {}
    normalized_names = {}
    for template in source_collection.all_objects:
        exact_names[template.name] = template
        normalized_name = BLENDER_DUPLICATE_SUFFIX.sub("", template.name)
        normalized_names.setdefault(normalized_name, []).append(template)

    placements = []
    for record_number, record in enumerate(records, start=1):
        name = record.get("name") if isinstance(record, dict) else None
        if not isinstance(name, str) or not name:
            raise ValueError(f"Запись {record_number}: укажите имя ассета в поле name.")

        try:
            template = exact_names.get(name)
            if template is None:
                candidates = normalized_names.get(name, [])
                if not candidates:
                    raise ValueError("В выбранной коллекции нет такого шаблона.")
                if len(candidates) > 1:
                    raise ValueError("Подходит несколько шаблонов. Оставьте одно точное имя.")
                template = candidates[0]

            position_x, position_y, position_z = read_axes(record.get("position"), "xyz", "position")
            position = tuple(
                axis / STUDS_PER_BLENDER_UNIT for axis in (-position_x, position_z, position_y)
            )

            rotation = (1.0, 0.0, 0.0, 0.0)
            if "rotation" in record:
                x, y, z, w = read_axes(record["rotation"], "xyzw", "rotation")
                length = math.hypot(x, y, z, w)
                if length == 0:
                    raise ValueError("В поле rotation задан нулевой кватернион.")
                rotation = (w / length, -x / length, z / length, y / length)

            scale = (1.0, 1.0, 1.0)
            if "size" in record:
                x, y, z = read_axes(record["size"], "xyz", "size")
                scale = (x, z, y)

            face_colors = {}
            object_color = None
            if "color" in record:
                colors = read_colors(record["color"])
                if colors and template.type == "MESH":
                    face_colors = get_mesh_color_targets(template, name, colors)
                elif colors:
                    if colors.keys() != {name}:
                        raise ValueError(f"В поле color ожидается цвет «{name}».")
                    object_color = colors[name]
        except ValueError as error:
            raise ValueError(f"Запись {record_number} («{name}»): {error}") from error

        placements.append((template, name, position, rotation, scale, face_colors, object_color))
    return placements


def get_corner_render_color(mesh):
    attributes = mesh.color_attributes
    render_index = attributes.render_color_index
    if 0 <= render_index < len(attributes):
        render_color = attributes[render_index]
        if render_color.domain == "CORNER":
            return render_color

        # Сохраняем имя атрибута, чтобы его мог читать существующий материал.
        name = render_color.name
        data_type = render_color.data_type
        vertex_colors = [tuple(value.color_srgb) for value in render_color.data]
        attributes.remove(render_color)
        render_color = attributes.new(name=name, type=data_type, domain="CORNER")
        for loop in mesh.loops:
            render_color.data[loop.index].color_srgb = vertex_colors[loop.vertex_index]
    else:
        render_color = attributes.new(name="Color", type="BYTE_COLOR", domain="CORNER")
        for color_value in render_color.data:
            color_value.color_srgb = (*WHITE_RGB, 1.0)

    attributes.render_color_index = attributes.find(render_color.name)
    return render_color


def apply_mesh_colors(mesh, face_colors):
    if not face_colors:
        return
    render_color = get_corner_render_color(mesh)
    for polygon_index, rgb in face_colors.items():
        for loop_index in mesh.polygons[polygon_index].loop_indices:
            color_value = render_color.data[loop_index]
            color_value.color_srgb = (*rgb, color_value.color_srgb[3])
    mesh.update()


def srgb_to_linear(channel):
    if channel <= 0.04045:
        return channel / 12.92
    return ((channel + 0.055) / 1.055) ** 2.4


def create_collection(scene, collection_name, placements):
    collection = bpy.data.collections.new(collection_name)
    copies = []
    copied_data = []

    try:
        for template, name, position, rotation, scale, face_colors, object_color in placements:
            asset_copy = template.copy()
            copies.append(asset_copy)
            asset_copy.name = name
            if template.data is not None:
                data_copy = template.data.copy()
                copied_data.append(data_copy)
                asset_copy.data = data_copy

            # В JSON записаны мировые координаты статичного объекта.
            asset_copy.parent = None
            asset_copy.constraints.clear()
            asset_copy.animation_data_clear()
            asset_copy.delta_location = (0.0, 0.0, 0.0)
            asset_copy.delta_rotation_quaternion = (1.0, 0.0, 0.0, 0.0)
            asset_copy.delta_scale = (1.0, 1.0, 1.0)
            asset_copy.rotation_mode = "QUATERNION"
            asset_copy.location = position
            asset_copy.rotation_quaternion = rotation
            asset_copy.scale = scale

            if asset_copy.type == "MESH":
                apply_mesh_colors(asset_copy.data, face_colors)
            elif object_color is not None:
                asset_copy.color = (*map(srgb_to_linear, object_color), asset_copy.color[3])
            collection.objects.link(asset_copy)

        scene.collection.children.link(collection)
    except Exception:
        # При ошибке удаляем только данные, созданные текущим импортом.
        for asset_copy in copies:
            bpy.data.objects.remove(asset_copy, do_unlink=True)
        if copied_data:
            bpy.data.batch_remove(ids=copied_data)
        bpy.data.collections.remove(collection, do_unlink=True)
        raise

    return collection


class IMPORT_SCENE_OT_roblox_asset_positions(bpy.types.Operator, ImportHelper):
    bl_idname = "import_scene.roblox_asset_positions"
    bl_label = "Импортировать пропы из JSON"
    bl_options = {"UNDO"}

    filename_ext = ".json"
    filter_glob: StringProperty(default="*.json", options={"HIDDEN"})

    def invoke(self, context, event):
        try:
            if context.mode != "OBJECT":
                raise ValueError("Переключитесь в Object Mode перед импортом.")
            self.source_collection = get_selected_collection(context)
            self.target_scene = context.scene
        except ValueError as error:
            self.report({"WARNING"}, str(error))
            return {"CANCELLED"}
        return ImportHelper.invoke(self, context, event)

    def execute(self, context):
        if not hasattr(self, "source_collection"):
            self.report({"WARNING"}, "Запустите импорт кнопкой Run Script в Text Editor.")
            return {"CANCELLED"}

        file_path = Path(self.filepath)
        try:
            if context.mode != "OBJECT":
                raise ValueError("Переключитесь в Object Mode перед импортом.")
            placements = prepare_placements(file_path, self.source_collection)
            collection = create_collection(self.target_scene, file_path.stem, placements)
        except json.JSONDecodeError as error:
            self.report({"ERROR"}, f"Некорректный JSON. Строка {error.lineno}, столбец {error.colno}.")
            return {"CANCELLED"}
        except (OSError, ValueError, RuntimeError, ReferenceError) as error:
            self.report({"ERROR"}, str(error))
            return {"CANCELLED"}

        self.report({"INFO"}, f"Коллекция «{collection.name}». Создано копий: {len(placements)}.")
        return {"FINISHED"}


if __name__ == "__main__":
    previous_operator = getattr(bpy.types, "IMPORT_SCENE_OT_roblox_asset_positions", None)
    if previous_operator is not None:
        bpy.utils.unregister_class(previous_operator)
    bpy.utils.register_class(IMPORT_SCENE_OT_roblox_asset_positions)
    bpy.ops.import_scene.roblox_asset_positions("INVOKE_DEFAULT")
