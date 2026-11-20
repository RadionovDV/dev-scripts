""" Blender 5.2 

- Exports object placements from the selected Blender collection to JSON for Roblox Studio.
- Records template names, positions, rotations, scale, and colors from the Render Color attribute.
- Select one collection in the Outliner, then click Run Script in the Text Editor.
"""

import json
import math
import re
from collections import Counter
from pathlib import Path
from tempfile import NamedTemporaryFile

import bmesh
import bpy
from bpy.props import StringProperty
from bpy_extras.io_utils import ExportHelper


# Сколько studs в Roblox соответствует одной единице Blender.
STUDS_PER_BLENDER_UNIT = 1.0
BLENDER_DUPLICATE_SUFFIX = re.compile(r"(?<=.)\.[0-9]{3,}\Z")
DEFAULT_COLOR = "#FFFFFF"


def color_to_hex(color_srgb):
    """RGB в sRGB; прозрачность не экспортируется. Сравнение — с точностью HEX."""
    channels = []
    for channel in color_srgb[:3]:
        if not math.isfinite(channel):
            raise ValueError("Color Attribute содержит некорректный цвет.")
        channels.append(round(max(0.0, min(1.0, channel)) * 255))
    return "#{:02X}{:02X}{:02X}".format(*channels)


def get_face_color(polygon, color_attribute):
    """Разноцветная грань входит в общее число, но не голосует за цвет."""
    face_color = None
    for loop_index in polygon.loop_indices:
        corner_color = color_to_hex(color_attribute.data[loop_index].color_srgb)
        if face_color is None:
            face_color = corner_color
        elif corner_color != face_color:
            return None
    return face_color


def get_majority_color(color_counts, face_count):
    if color_counts:
        majority_color, majority_count = color_counts.most_common(1)[0]
        if majority_count * 2 > face_count:
            return majority_color
    return DEFAULT_COLOR


def get_asset_colors(asset_object):
    """Цвета исходного меша: Render Color, один голос на целую грань."""
    object_name = BLENDER_DUPLICATE_SUFFIX.sub("", asset_object.name)
    if asset_object.type != "MESH":
        return {object_name: DEFAULT_COLOR}

    mesh = asset_object.data
    if asset_object.mode != "EDIT":
        return get_mesh_colors(asset_object, mesh)

    # В Edit Mode обычный доступ к цветам недоступен. Читаем текущие правки
    # через временную копию, сохраняя режим, исходный меш и Render Color.
    temporary_mesh = mesh.copy()
    try:
        bmesh.from_edit_mesh(mesh).to_mesh(temporary_mesh)
        render_name = mesh.color_attributes.default_color_name
        temporary_mesh.color_attributes.render_color_index = (
            temporary_mesh.color_attributes.find(render_name)
        )
        return get_mesh_colors(asset_object, temporary_mesh)
    finally:
        bpy.data.meshes.remove(temporary_mesh)


def get_mesh_colors(asset_object, mesh):
    object_name = BLENDER_DUPLICATE_SUFFIX.sub("", asset_object.name)
    group_names = {}
    original_names = {}
    for vertex_group in asset_object.vertex_groups:
        group_name = BLENDER_DUPLICATE_SUFFIX.sub("", vertex_group.name)
        if group_name in original_names:
            raise ValueError(
                f"Объект «{asset_object.name}»: группы "
                f"«{original_names[group_name]}» и «{vertex_group.name}» "
                f"после удаления суффиксов имеют одинаковое имя «{group_name}»."
            )
        original_names[group_name] = vertex_group.name
        group_names[vertex_group.index] = group_name

    colors = {name: DEFAULT_COLOR for name in group_names.values()}
    if not group_names:
        colors = {object_name: DEFAULT_COLOR}

    color_attributes = mesh.color_attributes
    if not color_attributes:
        return colors

    # Render Color (значок камеры), а не выделенный в списке атрибут.
    render_index = color_attributes.render_color_index
    if not 0 <= render_index < len(color_attributes):
        raise ValueError(f"Объект «{asset_object.name}»: не задан Render Color.")
    color_attribute = color_attributes[render_index]
    if color_attribute.domain != "CORNER":
        raise ValueError(
            f"Объект «{asset_object.name}»: Render Color «{color_attribute.name}» "
            "должен хранить цвета по граням (Face Corner)."
        )

    if not group_names:
        color_counts = Counter()
        for polygon in mesh.polygons:
            face_color = get_face_color(polygon, color_attribute)
            if face_color is not None:
                color_counts[face_color] += 1
        return {object_name: get_majority_color(color_counts, len(mesh.polygons))}

    vertex_groups = [
        {membership.group for membership in vertex.groups if membership.weight > 0.0}
        for vertex in mesh.vertices
    ]
    group_face_counts = Counter()
    group_color_counts = {group_index: Counter() for group_index in group_names}
    for polygon in mesh.polygons:
        # Грань относится к группе, только если в неё входят все её вершины.
        common_groups = set(group_names)
        for vertex_index in polygon.vertices:
            common_groups.intersection_update(vertex_groups[vertex_index])
            if not common_groups:
                break
        if not common_groups:
            continue
        face_color = get_face_color(polygon, color_attribute)
        for group_index in common_groups:
            group_face_counts[group_index] += 1
            if face_color is not None:
                group_color_counts[group_index][face_color] += 1

    return {
        group_name: get_majority_color(
            group_color_counts[group_index], group_face_counts[group_index]
        )
        for group_index, group_name in group_names.items()
    }


def get_selected_collection(context):
    selected_collections = set()
    for area in context.screen.areas:
        if area.type != "OUTLINER" or area.spaces.active.display_mode != "VIEW_LAYER":
            continue

        window_region = next(region for region in area.regions if region.type == "WINDOW")
        with context.temp_override(area=area, region=window_region):
            selected_collections.update(
                selected_item
                for selected_item in context.selected_ids
                if isinstance(selected_item, bpy.types.Collection)
            )

    if len(selected_collections) != 1:
        raise ValueError("Выделите ровно одну коллекцию в Outliner в режиме View Layer.")

    return selected_collections.pop()


def get_asset_placements(context, collection):
    dependency_graph = context.evaluated_depsgraph_get()
    placements = []

    for asset_object in sorted(collection.all_objects, key=lambda asset_object: asset_object.name):
        evaluated_object = asset_object.evaluated_get(dependency_graph)
        if not evaluated_object.is_evaluated:
            raise ValueError(
                f"Blender не вычислил позицию объекта «{asset_object.name}». "
                "Включите его коллекцию в текущем слое и повторите экспорт."
            )

        position, rotation, scale = evaluated_object.matrix_world.decompose()

        # Roblox (X, Y, Z) = Blender (-X, Z, Y). Масштаб — множитель вдоль оси.
        placements.append({
            "name": BLENDER_DUPLICATE_SUFFIX.sub("", asset_object.name),
            "color": get_asset_colors(asset_object),
            "position": {
                "x": -position.x * STUDS_PER_BLENDER_UNIT,
                "y": position.z * STUDS_PER_BLENDER_UNIT,
                "z": position.y * STUDS_PER_BLENDER_UNIT,
            },
            "rotation": {
                "x": -rotation.x,
                "y": rotation.z,
                "z": rotation.y,
                "w": rotation.w,
            },
            "size": {
                "x": scale.x,
                "y": scale.z,
                "z": scale.y,
            },
        })

    return placements


def save_json(file_path: Path, json_text: str):
    # Заменяем файл только после того, как JSON записан целиком.
    temporary_file = NamedTemporaryFile(
        mode="w", encoding="utf-8", dir=file_path.parent, delete=False
    )
    temporary_path = Path(temporary_file.name)
    try:
        with temporary_file:
            temporary_file.write(json_text + "\n")
        temporary_path.replace(file_path)
    finally:
        temporary_path.unlink(missing_ok=True)


class EXPORT_SCENE_OT_roblox_asset_positions(bpy.types.Operator, ExportHelper):
    bl_idname = "export_scene.roblox_asset_positions"
    bl_label = "Сохранить JSON для Roblox"

    filename_ext = ".json"
    filter_glob: StringProperty(default="*.json", options={"HIDDEN"})

    def invoke(self, context, event):
        try:
            collection = get_selected_collection(context)
            placements = get_asset_placements(context, collection)
        except ValueError as error:
            self.report({"WARNING"}, str(error))
            return {"CANCELLED"}

        try:
            self.json_text = json.dumps(placements, ensure_ascii=False, allow_nan=False, indent=2)
        except ValueError:
            self.report({"WARNING"}, "Координаты, поворот и масштаб должны быть конечными числами.")
            return {"CANCELLED"}

        self.placement_count = len(placements)
        return ExportHelper.invoke(self, context, event)

    def execute(self, context):
        if not hasattr(self, "json_text"):
            self.report({"WARNING"}, "Запустите экспорт через Run Script в Text Editor.")
            return {"CANCELLED"}

        try:
            save_json(Path(self.filepath), self.json_text)
        except OSError as error:
            self.report({"ERROR"}, f"Не удалось сохранить JSON: {error}")
            return {"CANCELLED"}

        self.report({"INFO"}, f"Записей в JSON: {self.placement_count}")
        return {"FINISHED"}


if __name__ == "__main__":
    existing_operator = getattr(bpy.types, "EXPORT_SCENE_OT_roblox_asset_positions", None)
    if existing_operator is not None:
        bpy.utils.unregister_class(existing_operator)
    bpy.utils.register_class(EXPORT_SCENE_OT_roblox_asset_positions)
    bpy.ops.export_scene.roblox_asset_positions("INVOKE_DEFAULT")
