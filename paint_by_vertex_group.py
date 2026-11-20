"""Blender 5.2

- Adds a Fill by Group tool to Vertex Paint mode.
- Hover to preview a vertex group's outline, then left-click to fill its faces with the current paint color.
- If the mesh has no vertex groups, the tool fills the entire mesh.
- Run this script in the Text Editor, then choose Paint > Fill by group in Vertex Paint mode.
"""

import sys
import types

import blf
import bpy
import gpu
from array import array
from bpy.app.handlers import persistent
from bpy.props import FloatVectorProperty, StringProperty
from bpy_extras import view3d_utils
from gpu_extras.batch import batch_for_shader
from mathutils.bvhtree import BVHTree


def install_fill_by_group():
    module_key = "_fill_by_group_runtime"
    previous_runtime = sys.modules.get(module_key)
    if previous_runtime is not None:
        previous_runtime.shutdown()

    runtime = types.ModuleType(module_key)
    runtime.sessions = []
    runtime.registered_classes = []
    runtime.enabled = True
    runtime.version = "1.1.2"

    def make_outline_shader():
        interface = gpu.types.GPUStageInterfaceInfo("fbg_outline_interface")
        interface.smooth('VEC2', "texture_coordinate")
        info = gpu.types.GPUShaderCreateInfo()
        info.vertex_in(0, 'VEC2', "position")
        info.vertex_out(interface)
        info.sampler(0, 'FLOAT_2D', "object_mask")
        info.push_constant('VEC2', "pixel_size")
        info.push_constant('VEC4', "outline_color")
        info.fragment_out(0, 'VEC4', "fragment_color")
        info.vertex_source('''
            void main() {
                texture_coordinate = position * 0.5 + 0.5;
                gl_Position = vec4(position, 0.0, 1.0);
            }
        ''')
        info.fragment_source('''
            void main() {
                // Draw OUTSIDE the silhouette. Surface pixels are never tinted.
                if (texture(object_mask, texture_coordinate).r > 0.5) discard;
                float edge = 0.0;
                for (int x = -1; x <= 1; ++x) {
                    for (int y = -1; y <= 1; ++y) {
                        vec2 offset = vec2(float(x), float(y)) * pixel_size;
                        edge = max(edge, texture(object_mask, texture_coordinate + offset).r);
                    }
                }
                if (edge < 0.5) discard;
                fragment_color = outline_color;
            }
        ''')
        return gpu.shader.create_from_info(info)

    def current_color(context):
        paint = context.scene.tool_settings.vertex_paint
        # In 5.2 these settings belong to Paint, rather than ToolSettings.
        unified = getattr(paint, "unified_paint_settings", None)
        if unified is None:
            unified = getattr(context.scene.tool_settings, "unified_paint_settings", None)
        if unified is not None and unified.use_unified_color:
            return tuple(unified.color)
        if paint.brush is not None:
            return tuple(paint.brush.color)
        raise RuntimeError("Выберите кисть или включите общий цвет Vertex Paint")

    def common_groups(mesh, polygon):
        """Membership, including zero-weight assignments, on EVERY face vertex."""
        groups = None
        for vertex_index in polygon.vertices:
            vertex_groups = {assignment.group for assignment in mesh.vertices[vertex_index].groups}
            groups = vertex_groups if groups is None else groups.intersection(vertex_groups)
            if not groups:
                return set()
        return groups or set()

    def group_polygons(mesh, group_index):
        if group_index is None:
            return list(range(len(mesh.polygons)))
        membership = [
            any(assignment.group == group_index for assignment in vertex.groups)
            for vertex in mesh.vertices
        ]
        return [
            polygon.index for polygon in mesh.polygons
            if all(membership[index] for index in polygon.vertices)
        ]

    def ensure_corner_colors(mesh):
        """Preserve the active layer's name, colors, storage type and render role."""
        attributes = mesh.color_attributes
        attribute = attributes.active_color
        if attribute is None and len(attributes):
            attribute = attributes[0]
        if attribute is None:
            attribute = attributes.new(name="Color", type='FLOAT_COLOR', domain='CORNER')
            attribute.data.foreach_set("color", array('f', [1.0, 1.0, 1.0, 1.0]) * len(mesh.loops))
        elif attribute.domain == 'POINT':
            original_name = attribute.name
            render_name = attributes.default_color_name
            values = array('f', [0.0]) * (4 * len(attribute.data))
            attribute.data.foreach_get("color", values)
            corner_values = array('f', [0.0]) * (4 * len(mesh.loops))
            for loop in mesh.loops:
                source_offset = loop.vertex_index * 4
                target_offset = loop.index * 4
                corner_values[target_offset:target_offset + 4] = values[source_offset:source_offset + 4]
            converted = attributes.new(name=original_name + "_FBG", type=attribute.data_type, domain='CORNER')
            converted.data.foreach_set("color", corner_values)
            attributes.remove(attribute)
            converted.name = original_name
            attribute = converted
            if render_name:
                attributes.default_color_name = render_name
        attributes.active_color = attribute
        if not attributes.default_color_name:
            attributes.default_color_name = attribute.name
        return attribute

    def fill_mesh(mesh, face_indices, color):
        attribute = ensure_corner_colors(mesh)
        values = array('f', [0.0]) * (4 * len(attribute.data))
        attribute.data.foreach_get("color", values)
        rgba = array('f', (*color, 1.0))
        for face_index in face_indices:
            for loop_index in mesh.polygons[face_index].loop_indices:
                offset = loop_index * 4
                values[offset:offset + 4] = rgba
        # Brush/unified colors in Blender 5.2 are scene-linear, just like .color.
        attribute.data.foreach_set("color", values)
        mesh.update()

    def activate_for_paint(context, target):
        active = context.view_layer.objects.active
        if active is not None and active.mode != 'OBJECT':
            bpy.ops.object.mode_set(mode='OBJECT')
        for selected in list(context.selected_objects):
            selected.select_set(False)
        target.select_set(True)
        context.view_layer.objects.active = target

    class PAINT_OT_fill_by_group_apply(bpy.types.Operator):
        """One independent undo step for one complete fill."""
        bl_idname = "paint.fill_by_group_apply"
        bl_label = "Fill by group"
        bl_options = {'INTERNAL', 'UNDO'}

        object_name: StringProperty(options={'HIDDEN', 'SKIP_SAVE'})
        group_name: StringProperty(options={'HIDDEN', 'SKIP_SAVE'})
        paint_color: FloatVectorProperty(size=3, subtype='COLOR', min=0.0, max=1.0)

        def execute(self, context):
            target = context.view_layer.objects.get(self.object_name)
            if target is None or target.type != 'MESH' or not target.is_editable or target.hide_select:
                self.report({'WARNING'}, "Объект недоступен для покраски")
                return {'CANCELLED'}
            if self.group_name:
                group = target.vertex_groups.get(self.group_name)
                if group is None:
                    self.report({'WARNING'}, "Группа больше не существует")
                    return {'CANCELLED'}
                group_index = group.index
            elif len(target.vertex_groups):
                self.report({'WARNING'}, "У этой грани нет подходящей группы")
                return {'CANCELLED'}
            else:
                group_index = None
            face_indices = group_polygons(target.data, group_index)
            if not face_indices:
                self.report({'WARNING'}, "В группе нет целых граней для заливки")
                return {'CANCELLED'}

            old_active = context.view_layer.objects.active
            old_selected = [obj.name for obj in context.selected_objects]
            old_mode = old_active.mode if old_active else 'OBJECT'
            try:
                activate_for_paint(context, target)
                # Linked duplicates must not recolor their neighbours.
                if target.data.users > 1 or not target.data.is_editable:
                    target.data = target.data.copy()
                fill_mesh(target.data, face_indices, self.paint_color)
                bpy.ops.object.mode_set(mode='VERTEX_PAINT')
            except Exception as error:
                if context.object and context.object.mode != 'OBJECT':
                    bpy.ops.object.mode_set(mode='OBJECT')
                for selected in list(context.selected_objects):
                    selected.select_set(False)
                for name in old_selected:
                    obj = context.view_layer.objects.get(name)
                    if obj:
                        obj.select_set(True)
                if old_active and old_active.name in context.view_layer.objects:
                    context.view_layer.objects.active = old_active
                    if old_mode != 'OBJECT':
                        bpy.ops.object.mode_set(mode=old_mode)
                self.report({'ERROR'}, "Fill by group: " + str(error))
                return {'CANCELLED'}
            return {'FINISHED'}

    class FillSession:
        """Plain Python lifetime: draw callbacks never hold an invalid Blender operator."""

        def start(self, context, event, operator):
            for session in list(runtime.sessions):
                session.finish()
            self.stopped = False
            self.report = operator.report
            self.window = context.window
            self.area = context.area
            self.region = next(region for region in self.area.regions if region.type == 'WINDOW')
            self.space = context.space_data
            self.workspace = context.workspace
            self.sampling_was_active = False
            self.status_hint = "Fill by group  |  ЛКМ: залить  |  Shift+X: пипетка  |  Esc / ПКМ: выход"
            self.pointer = None
            self.hover = None
            self.geometry = None
            self.preview_key = None
            self.preview_batch = None
            self.preview_matrix = None
            self.outline_buffer = None
            self.outline_size = None
            self.shader = gpu.shader.from_builtin('UNIFORM_COLOR')
            self.outline_shader = make_outline_shader()
            self.outline_quad = batch_for_shader(self.outline_shader, 'TRI_STRIP', {
                "position": ((-1, -1), (1, -1), (-1, 1), (1, 1)),
            })
            self.handles = [
                bpy.types.SpaceView3D.draw_handler_add(self.draw_preview, (), 'WINDOW', 'POST_PIXEL'),
                bpy.types.SpaceView3D.draw_handler_add(self.draw_label, (), 'WINDOW', 'POST_PIXEL'),
            ]
            self.timer = context.window_manager.event_timer_add(0.12, window=self.window)
            self.previous_tool_header = self.space.show_region_tool_header
            self.space.show_region_tool_header = True
            self.workspace.status_text_set(self.status_hint)
            self.window.cursor_modal_set('CROSSHAIR')
            runtime.sessions.append(self)
            context.window_manager.modal_handler_add(operator)
            return {'RUNNING_MODAL'}

        def invalidate(self):
            self.geometry = None
            self.preview_key = None
            self.preview_batch = None
            self.hover = None

        def finish(self):
            if getattr(self, "stopped", True):
                return
            self.stopped = True
            for handle in self.handles:
                bpy.types.SpaceView3D.draw_handler_remove(handle, 'WINDOW')
            self.handles.clear()
            if self.outline_buffer is not None:
                try:
                    self.outline_buffer.free()
                except ReferenceError:
                    pass
                self.outline_buffer = None
            if self.timer:
                bpy.context.window_manager.event_timer_remove(self.timer)
                self.timer = None
            try:
                self.workspace.status_text_set(None)
                self.space.show_region_tool_header = self.previous_tool_header
                self.area.tag_redraw()
                self.window.cursor_modal_restore()
            except ReferenceError:
                pass
            self.invalidate()
            if self in runtime.sessions:
                runtime.sessions.remove(self)

        def pointer_inside(self, event):
            # WINDOW can cover the full editor, including overlapping headers,
            # toolbars, the sidebar and the asset shelf. Those regions own their
            # input even when their rectangles also lie inside WINDOW.
            x = event.mouse_x - self.region.x
            y = event.mouse_y - self.region.y
            if not (0 <= x < self.region.width and 0 <= y < self.region.height):
                return None
            visibility_flags = {
                'HEADER': 'show_region_header',
                'TOOL_HEADER': 'show_region_tool_header',
                'TOOLS': 'show_region_toolbar',
                'UI': 'show_region_ui',
                'HUD': 'show_region_hud',
                'ASSET_SHELF': 'show_region_asset_shelf',
                'ASSET_SHELF_HEADER': 'show_region_asset_shelf',
            }
            for region in self.area.regions:
                if region.type == 'WINDOW' or region.width <= 1 or region.height <= 1:
                    continue
                visibility_flag = visibility_flags.get(region.type)
                if visibility_flag and not getattr(self.space, visibility_flag, True):
                    continue
                if (region.x <= event.mouse_x < region.x + region.width
                        and region.y <= event.mouse_y < region.y + region.height):
                    return None
            return x, y

        def build_geometry(self, context, obj, depsgraph):
            evaluated = obj.evaluated_get(depsgraph)
            mesh = evaluated.data
            coordinates = [vertex.co.copy() for vertex in mesh.vertices]
            faces = [tuple(polygon.vertices) for polygon in mesh.polygons]
            vertex_groups = [{assignment.group for assignment in vertex.groups} for vertex in mesh.vertices]
            memberships = []
            for face in faces:
                groups = set(vertex_groups[face[0]]) if face else set()
                for vertex_index in face[1:]:
                    groups.intersection_update(vertex_groups[vertex_index])
                memberships.append(groups)
            mesh.calc_loop_triangles()
            self.geometry = {
                "object_name": obj.name,
                "object_pointer": obj.as_pointer(),
                "mesh_pointer": obj.data.as_pointer(),
                "bvh": BVHTree.FromPolygons(coordinates, faces),
                "coordinates": coordinates,
                "memberships": memberships,
                "triangles": [(triangle.polygon_index, tuple(triangle.vertices)) for triangle in mesh.loop_triangles],
            }

        def update_hover(self, context):
            self.hover = None
            if self.pointer is None:
                return
            direction = view3d_utils.region_2d_to_vector_3d(self.region, self.space.region_3d, self.pointer)
            origin = view3d_utils.region_2d_to_origin_3d(self.region, self.space.region_3d, self.pointer)
            depsgraph = context.evaluated_depsgraph_get()
            hit, location, normal, unused_index, evaluated_obj, matrix = context.scene.ray_cast(depsgraph, origin, direction)
            if not hit or evaluated_obj is None:
                return
            obj = evaluated_obj.original
            if (obj.type != 'MESH' or context.view_layer.objects.get(obj.name) != obj
                    or not obj.visible_get(view_layer=context.view_layer, viewport=self.space)):
                return
            if not obj.is_editable or obj.hide_select:
                self.hover = {"label": "Объект недоступен", "extras": "", "blocked": True}
                return
            # Instances cannot be recolored independently without realizing them.
            if any(abs(matrix[row][column] - obj.matrix_world[row][column]) > 1e-5
                   for row in range(4) for column in range(4)):
                self.hover = {"label": "Экземпляр объекта", "extras": "", "blocked": True}
                return
            if self.geometry is None or self.geometry["object_pointer"] != obj.as_pointer():
                self.build_geometry(context, obj, depsgraph)
                self.preview_key = None
            try:
                inverse = matrix.inverted()
            except ValueError:
                return
            local_direction = (inverse.to_3x3() @ direction).normalized()
            unused_location, unused_normal, face_index, unused_distance = self.geometry["bvh"].ray_cast(inverse @ origin, local_direction)
            if face_index is None:
                return
            if len(obj.vertex_groups):
                candidates = [group for group in obj.vertex_groups if group.index in self.geometry["memberships"][face_index]]
                if not candidates:
                    self.hover = {"label": "Нет группы", "extras": "", "blocked": True}
                    return
                group = candidates[0]
                label = group.name
                group_index = group.index
                group_name = group.name
                extras = " (" + ", ".join(group.name for group in candidates[1:]) + ")" if len(candidates) > 1 else ""
            else:
                label, extras, group_index, group_name = obj.name, "", None, ""
            self.hover = {"label": label, "extras": extras, "blocked": False,
                          "object_name": obj.name, "group_name": group_name}
            self.preview_matrix = matrix.copy()
            # Rebuild the silhouette when the hovered group changes, even on
            # the same object. Its mask contains only complete group faces.
            preview_key = (obj.as_pointer(), group_index)
            if preview_key != self.preview_key:
                geometry = self.geometry
                triangles = [indices for polygon_index, indices in geometry["triangles"]
                             if group_index is None or group_index in geometry["memberships"][polygon_index]]
                self.preview_batch = batch_for_shader(self.shader, 'TRIS', {"pos": geometry["coordinates"]}, indices=triangles) if triangles else None
                self.preview_key = preview_key

        def is_own_view(self):
            context = bpy.context
            sampling = self.sampling_active()
            return (not self.stopped and context.area == self.area and context.region == self.region
                    and context.window == self.window and self.pointer is not None
                    and not sampling)

        def sampling_active(self):
            # Native eyedroppers run their own modal operator. Yield the entire
            # interaction, including confirmation/cancellation, and hide our UI.
            active = any("eyedropper" in operator.bl_idname.lower()
                         or "sample_color" in operator.bl_idname.lower()
                         for operator in self.window.modal_operators)
            if active:
                self.sampling_was_active = True
            return active

        def draw_preview(self):
            if not self.is_own_view() or not self.hover or self.hover["blocked"] or self.preview_batch is None:
                return
            old_blend = gpu.state.blend_get()
            old_depth = gpu.state.depth_test_get()
            old_mask = gpu.state.depth_mask_get()
            old_viewport = gpu.state.viewport_get()
            try:
                size = (self.region.width, self.region.height)
                if self.outline_buffer is None or self.outline_size != size:
                    if self.outline_buffer is not None:
                        self.outline_buffer.free()
                    self.outline_buffer = gpu.types.GPUOffScreen(*size, format='RGBA8')
                    self.outline_size = size
                gpu.state.blend_set('NONE')
                gpu.state.depth_test_set('NONE')
                gpu.state.depth_mask_set(False)
                # A temporary GPU mask, never a Blender object or mesh duplicate.
                with self.outline_buffer.bind():
                    gpu.state.viewport_set(0, 0, *size)
                    gpu.state.active_framebuffer_get().clear(color=(0, 0, 0, 0))
                    with gpu.matrix.push_pop(), gpu.matrix.push_pop_projection():
                        gpu.matrix.load_matrix(self.space.region_3d.view_matrix @ self.preview_matrix)
                        gpu.matrix.load_projection_matrix(self.space.region_3d.window_matrix)
                        self.shader.bind()
                        self.shader.uniform_float("color", (1, 1, 1, 1))
                        self.preview_batch.draw(self.shader)
                gpu.state.viewport_set(*old_viewport)
                gpu.state.blend_set('ALPHA')
                self.outline_shader.bind()
                self.outline_shader.uniform_sampler("object_mask", self.outline_buffer.texture_color)
                thickness = 2.0 * bpy.context.preferences.system.ui_scale
                self.outline_shader.uniform_float("pixel_size", (thickness / size[0], thickness / size[1]))
                self.outline_shader.uniform_float("outline_color", (0.05, 0.9, 0.8, 1.0))
                self.outline_quad.draw(self.outline_shader)
            finally:
                gpu.state.viewport_set(*old_viewport)
                gpu.state.depth_mask_set(old_mask)
                gpu.state.depth_test_set(old_depth)
                gpu.state.blend_set(old_blend)

        def draw_label(self):
            if not self.is_own_view() or not self.hover:
                return
            scale = bpy.context.preferences.system.ui_scale
            font = 0
            blf.size(font, 14 * scale)
            label, extras = self.hover["label"], self.hover["extras"]
            total_width = blf.dimensions(font, label + extras)[0]
            x = max(6, min(self.pointer[0] + 18 * scale, self.region.width - total_width - 8))
            y = max(6, min(self.pointer[1] + 20 * scale, self.region.height - 22 * scale))
            blf.enable(font, blf.SHADOW)
            blf.shadow(font, 5, 0.0, 0.0, 0.0, 0.9)
            blf.shadow_offset(font, 1, -1)
            try:
                blf.position(font, x, y, 0)
                blf.color(font, *((1.0, 0.45, 0.35, 1.0) if self.hover["blocked"] else (1.0, 1.0, 1.0, 1.0)))
                blf.draw(font, label)
                if extras:
                    blf.position(font, x + blf.dimensions(font, label)[0], y, 0)
                    blf.color(font, 1.0, 0.15, 0.15, 1.0)
                    blf.draw(font, extras)
            finally:
                blf.disable(font, blf.SHADOW)

        def modal(self, context, event):
            if self.stopped or not runtime.enabled:
                self.finish()
                return {'FINISHED'}
            if (context.window != self.window or self.area.type != 'VIEW_3D'
                    or context.mode != 'PAINT_VERTEX'):
                self.finish()
                return {'FINISHED'}
            if self.sampling_active() or getattr(context, "region_popup", None) is not None:
                self.hover = None
                self.area.tag_redraw()
                return {'PASS_THROUGH'}
            if self.sampling_was_active:
                self.sampling_was_active = False
                self.workspace.status_text_set(self.status_hint)
                self.window.cursor_modal_set('CROSSHAIR')
            if event.type == 'ESC' and event.value == 'PRESS':
                self.finish()
                return {'FINISHED'}
            self.pointer = self.pointer_inside(event)
            if self.pointer is None:
                self.hover = None
                self.area.tag_redraw()
                return {'PASS_THROUGH'}
            if event.type == 'RIGHTMOUSE' and event.value == 'PRESS':
                self.finish()
                return {'FINISHED'}
            if event.type in {'MOUSEMOVE', 'INBETWEEN_MOUSEMOVE', 'TIMER', 'LEFTMOUSE'}:
                try:
                    self.update_hover(context)
                except (ReferenceError, RuntimeError, ValueError):
                    self.invalidate()
                self.area.tag_redraw()
            if event.type == 'LEFTMOUSE':
                if event.value == 'PRESS' and self.hover and not self.hover["blocked"]:
                    try:
                        color = current_color(context)
                        bpy.ops.paint.fill_by_group_apply('EXEC_DEFAULT', True,
                            object_name=self.hover["object_name"], group_name=self.hover["group_name"], paint_color=color)
                    except RuntimeError as error:
                        self.report({'WARNING'}, str(error))
                    self.invalidate()
                    self.area.tag_redraw()
                # Consume releases too: never let a click start a brush stroke.
                return {'RUNNING_MODAL'}
            if event.type in {'MOUSEMOVE', 'INBETWEEN_MOUSEMOVE', 'TIMER'}:
                return {'RUNNING_MODAL'}
            # View navigation, color sampling and Ctrl-Z stay available.
            return {'PASS_THROUGH'}

    class PAINT_OT_fill_by_group(bpy.types.Operator):
        bl_idname = "paint.fill_by_group"
        bl_label = "Fill by group"
        bl_description = "Заливка группы под курсором; без групп — заливка всего объекта. Esc / ПКМ — выход"
        # Deliberately no UNDO flag: each click uses the separate UNDO operator.
        bl_options = {'INTERNAL'}

        @classmethod
        def poll(cls, context):
            return (context.area is not None and context.area.type == 'VIEW_3D'
                    and context.mode == 'PAINT_VERTEX')

        def invoke(self, context, event):
            self.session = FillSession()
            return self.session.start(context, event, self)

        def modal(self, context, event):
            try:
                return self.session.modal(context, event)
            except Exception as error:
                self.session.finish()
                self.report({'ERROR'}, "Fill by group: " + str(error))
                import traceback
                traceback.print_exc()
                return {'CANCELLED'}

        def cancel(self, context):
            self.session.finish()

    def menu_entry(self, context):
        self.layout.operator(PAINT_OT_fill_by_group.bl_idname, text="Fill by group", icon='COLOR')

    @persistent
    def invalidate_after_undo(unused_scene):
        for session in list(runtime.sessions):
            session.invalidate()

    @persistent
    def invalidate_after_update(scene, depsgraph):
        for session in list(runtime.sessions):
            geometry = session.geometry
            if geometry is None:
                continue
            for update in depsgraph.updates:
                updated_id = update.id.original
                if update.is_updated_geometry and updated_id.as_pointer() in {
                    geometry["object_pointer"], geometry["mesh_pointer"]
                }:
                    session.invalidate()
                    break

    @persistent
    def stop_before_load(unused_file):
        for session in list(runtime.sessions):
            session.finish()

    handler_pairs = [
        (bpy.app.handlers.undo_post, invalidate_after_undo),
        (bpy.app.handlers.redo_post, invalidate_after_undo),
        (bpy.app.handlers.depsgraph_update_post, invalidate_after_update),
        (bpy.app.handlers.load_pre, stop_before_load),
    ]

    def shutdown():
        runtime.enabled = False
        for session in list(runtime.sessions):
            session.finish()
        if getattr(runtime, "menu_attached", False):
            bpy.types.VIEW3D_MT_paint_vertex.remove(menu_entry)
            runtime.menu_attached = False
        for handlers, callback in handler_pairs:
            if callback in handlers:
                handlers.remove(callback)
        for operator_class in reversed(runtime.registered_classes):
            bpy.utils.unregister_class(operator_class)
        runtime.registered_classes.clear()

    runtime.shutdown = shutdown
    runtime.common_groups = common_groups
    runtime.group_polygons = group_polygons
    runtime.current_color = current_color
    runtime.fill_mesh = fill_mesh
    runtime.ensure_corner_colors = ensure_corner_colors
    sys.modules[module_key] = runtime
    try:
        for operator_class in (PAINT_OT_fill_by_group_apply, PAINT_OT_fill_by_group):
            bpy.utils.register_class(operator_class)
            runtime.registered_classes.append(operator_class)
        bpy.types.VIEW3D_MT_paint_vertex.append(menu_entry)
        runtime.menu_attached = True
        for handlers, callback in handler_pairs:
            handlers.append(callback)
    except Exception:
        shutdown()
        raise
    print("Fill by group: ready — Vertex Paint > Paint > Fill by group")


if __name__ == "__main__":
    install_fill_by_group()
