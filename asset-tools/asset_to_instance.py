"""Blender 5.2

- Prepares static assets in Blender by merging two or more mesh children of each Empty into one mesh.
- Creates a vertex group named after each original part so it can still be selected or painted separately.
- Select a collection or objects in Object Mode, then click Run Script in the Text Editor.
"""

import bpy
from mathutils import Matrix


def active_collection_is_selected(context):
    """Активная коллекция сама по себе ещё не означает её выделение."""
    active_collection = context.view_layer.active_layer_collection.collection
    if context.area and context.area.type == 'OUTLINER':
        return active_collection in getattr(context, 'selected_ids', ())

    # При Run Script текущая область — Text Editor. Проверяем выделение
    # в Outliner этого же окна, не переключая интерфейс и не меняя выделение.
    if context.window and context.screen:
        for area in context.screen.areas:
            if area.type != 'OUTLINER':
                continue
            region = next((region for region in area.regions
                           if region.type == 'WINDOW'), None)
            if region is None:
                continue
            with context.temp_override(window=context.window, area=area, region=region):
                if active_collection in getattr(context, 'selected_ids', ()):
                    return True
    return False


def detect_source(context):
    return 'COLLECTION' if active_collection_is_selected(context) else 'SELECTED'


def collect_candidates(context, source):
    """Коллекция включает подколлекции; выбранный Empty — прямых детей."""
    if source == 'COLLECTION':
        scope = set(context.view_layer.active_layer_collection.collection.all_objects)
        selected_roots = set()
    else:
        scope = set(context.selected_objects)
        selected_roots = {obj for obj in scope if obj.type == 'EMPTY'}
        for root in selected_roots:
            scope.update(root.children)
        scope.update(obj.parent for obj in list(scope)
                     if obj.type == 'MESH' and obj.parent
                     and obj.parent.type == 'EMPTY')

    roots = {obj for obj in scope if obj.type == 'EMPTY'}
    roots.update(obj.parent for obj in scope
                 if obj.type == 'MESH' and obj.parent
                 and obj.parent.type == 'EMPTY')
    return scope, sorted(roots, key=lambda obj: obj.name)


def check_asset(context, root, scope, user_map):
    """Возвращает (список Mesh, причина пропуска или пустая строка)."""
    meshes = sorted(root.children, key=lambda obj: obj.name)
    if not meshes:
        return [], 'Empty без потомков'
    if any(obj.type != 'MESH' for obj in meshes):
        return [], 'внутри есть вложенный Empty или объект другого типа'
    if len(meshes) == 1:
        return [], 'один Mesh — оставлен без изменений, включая его parent'
    if root not in scope:
        return [], 'Empty находится за пределами выбранной коллекции'
    if root.parent is not None:
        return [], 'Empty сам имеет parent: нужна отдельная обработка иерархии'
    if any(obj not in scope for obj in meshes):
        return [], 'выделены не все Mesh одного Empty'
    if any(obj.children for obj in meshes):
        return [], 'у Mesh есть собственные потомки'

    members = {root, *meshes}
    part_names = {obj.name for obj in meshes}
    collection_set = set(root.users_collection)
    if not collection_set:
        return [], 'Empty не привязан к коллекции'

    for obj in [root, *meshes]:
        if obj.library or obj.override_library or not obj.is_editable:
            return [], f'{obj.name}: linked-данные или library override'
        if len(obj.users_scene) != 1:
            return [], f'{obj.name}: объект используется в нескольких сценах'
        if set(obj.users_collection) != collection_set:
            return [], 'Empty и Mesh находятся в разных наборах коллекций'
        if context.view_layer.objects.get(obj.name) != obj:
            return [], f'{obj.name}: недоступен в текущем View Layer'
        if not obj.visible_get(view_layer=context.view_layer) or obj.hide_select:
            return [], f'{obj.name}: скрыт или запрещено выделение'
        if obj.animation_data or obj.constraints:
            return [], f'{obj.name}: есть анимация, драйверы или constraints'
        if obj.instance_type != 'NONE':
            return [], f'{obj.name}: используется инстансинг'
        if obj.rigid_body or obj.rigid_body_constraint:
            return [], f'{obj.name}: есть физика rigid body'
        external_users = [user for user in user_map.get(obj, set())
                          if user not in members
                          and not isinstance(user, (bpy.types.Collection,
                                                    bpy.types.Scene))]
        if external_users:
            return [], f'{obj.name}: на объект ссылается {external_users[0].name}'

    if abs(root.matrix_world.determinant()) < 1e-12:
        return [], 'нулевой или почти нулевой масштаб Empty'

    for mesh_object in meshes:
        if mesh_object.parent_type != 'OBJECT':
            return [], f'{mesh_object.name}: нестандартный тип parent'
        if mesh_object.data.shape_keys:
            return [], f'{mesh_object.name}: есть Shape Keys'
        if mesh_object.data.animation_data:
            return [], f'{mesh_object.name}: анимация Mesh-данных'
        if not mesh_object.data.vertices:
            return [], f'{mesh_object.name}: Mesh без вершин'
        if abs(mesh_object.matrix_world.determinant()) < 1e-12:
            return [], f'{mesh_object.name}: нулевой или почти нулевой масштаб'
        if mesh_object.hide_render != meshes[0].hide_render:
            return [], 'у частей разные настройки видимости при рендере'
        if any(group.name in part_names for group in mesh_object.vertex_groups):
            return [], 'существующая Vertex Group совпадает с именем одной из частей'

    return meshes, ''


def apply_modifiers(context, mesh_object, original_name, temporary_meshes):
    """Применяет стек сверху вниз, пока копия ещё в исходной системе координат."""
    with context.temp_override(
        object=mesh_object,
        active_object=mesh_object,
        selected_objects=[mesh_object],
        selected_editable_objects=[mesh_object],
    ):
        for modifier_name in [modifier.name for modifier in mesh_object.modifiers]:
            modifier = mesh_object.modifiers.get(modifier_name)
            if modifier is None:
                raise RuntimeError(f'{original_name}: исчез модификатор {modifier_name}')
            # Пользователь просит применить весь стек, включая выключенные
            # во viewport модификаторы. Переключаем только временную копию.
            modifier.show_viewport = True
            context.view_layer.update()
            try:
                outcome = bpy.ops.object.modifier_apply(modifier=modifier_name)
                if 'FINISHED' not in outcome or mesh_object.modifiers.get(modifier_name):
                    raise RuntimeError('Blender не подтвердил применение')
            except Exception as error:
                raise RuntimeError(
                    f'{original_name}: не удалось применить {modifier_name}: {error}'
                ) from error
            finally:
                # Некоторые модификаторы заменяют сам Mesh datablock.
                temporary_meshes.append(mesh_object.data)
            print(f'[Locations 14] МОДИФИКАТОР {original_name}: {modifier_name} применён')


def merge_asset(context, root, meshes):
    """Сначала объединяет временные копии; затем заменяет оригиналы."""
    root_name = root.name
    root_matrix = root.matrix_world.copy()
    inverse_root = root_matrix.inverted()
    destination_collections = list(root.users_collection)
    temporary_objects = []
    temporary_meshes = []
    staging_collection = None
    committed = False

    try:
        # Копии не добавляются в исходные коллекции: это важно для Boolean
        # и других модификаторов, использующих коллекцию как входные данные.
        staging_collection = bpy.data.collections.new('__Locations14_Work')
        context.scene.collection.children.link(staging_collection)
        for original in meshes:
            duplicate = original.copy()
            temporary_objects.append(duplicate)
            duplicate.data = original.data.copy()
            temporary_meshes.append(duplicate.data)
            staging_collection.objects.link(duplicate)
            context.view_layer.update()
            apply_modifiers(context, duplicate, original.name, temporary_meshes)
            duplicate.parent = None
            duplicate.matrix_parent_inverse = Matrix.Identity(4)
            duplicate.matrix_basis = Matrix.Identity(4)
            duplicate.delta_location = (0, 0, 0)
            duplicate.delta_rotation_euler = (0, 0, 0)
            duplicate.delta_rotation_quaternion = (1, 0, 0, 0)
            duplicate.delta_scale = (1, 1, 1)
            duplicate.matrix_world = root_matrix

            # Переносим геометрию в систему координат Empty. Сохраняем
            # мировое положение, в том числе при неравномерном масштабе.
            relative_matrix = inverse_root @ original.matrix_world
            duplicate.data.transform(relative_matrix)
            if relative_matrix.determinant() < 0:
                duplicate.data.flip_normals()
            duplicate.data.update()

            part_group = duplicate.vertex_groups.new(name=original.name)
            if part_group.name != original.name:
                raise RuntimeError('Blender изменил имя Vertex Group: ' + original.name)
            vertex_count = len(duplicate.data.vertices)
            for start in range(0, vertex_count, 65536):
                indices = list(range(start, min(start + 65536, vertex_count)))
                part_group.add(indices, 1.0, 'REPLACE')

        context.view_layer.update()
        expected_vertex_count = sum(len(obj.data.vertices) for obj in temporary_objects)
        joined = temporary_objects[0]
        with context.temp_override(
            object=joined,
            active_object=joined,
            selected_objects=temporary_objects,
            selected_editable_objects=temporary_objects,
        ):
            if not bpy.ops.object.join.poll():
                raise RuntimeError('Join недоступен в текущем контексте')
            outcome = bpy.ops.object.join()
            if 'FINISHED' not in outcome:
                raise RuntimeError('Join не завершён')

        if len(joined.data.vertices) != expected_vertex_count:
            raise RuntimeError('Не совпало количество вершин после Join')
        for original in meshes:
            if joined.vertex_groups.get(original.name) is None:
                raise RuntimeError('Не найдена группа: ' + original.name)

        # Все проверки и Join выполнены до удаления исходных объектов.
        for collection in destination_collections:
            collection.objects.link(joined)
        original_meshes = {obj.data for obj in meshes}
        for original in meshes:
            bpy.data.objects.remove(original, do_unlink=True)
        bpy.data.objects.remove(root, do_unlink=True)
        joined.name = root_name
        committed = True
        for mesh_data in original_meshes:
            if mesh_data.users == 0 and not mesh_data.use_fake_user:
                bpy.data.meshes.remove(mesh_data)
        return joined
    finally:
        # Join уже удалил часть временных объектов. Проверяем живые ссылки.
        if not committed:
            for duplicate in temporary_objects:
                try:
                    if duplicate.name in bpy.data.objects:
                        bpy.data.objects.remove(duplicate, do_unlink=True)
                except ReferenceError:
                    pass
        for mesh_data in temporary_meshes:
            try:
                if mesh_data.users == 0:
                    bpy.data.meshes.remove(mesh_data)
            except ReferenceError:
                pass
        if staging_collection is not None:
            bpy.data.collections.remove(staging_collection)


class OBJECT_OT_locations14_prepare_assets(bpy.types.Operator):
    bl_idname = 'object.locations14_prepare_assets'
    bl_label = 'Locations 14: Prepare Assets'
    bl_description = 'Объединить Mesh одного Empty с группой вершин для каждой части'
    bl_options = {'REGISTER', 'UNDO'}

    source: bpy.props.EnumProperty(
        name='Источник',
        items=[
            ('AUTO', 'Автоматически', 'Выделенная активная коллекция или выделенные объекты'),
            ('SELECTED', 'Выделенные объекты', 'Выбранный Empty включает его прямых детей'),
            ('COLLECTION', 'Активная коллекция', 'Включая все вложенные коллекции'),
        ],
        default='AUTO',
        options={'HIDDEN', 'SKIP_SAVE'},
    )
    preview_only: bpy.props.BoolProperty(
        name='Только проверка',
        description='Показать план в системной консоли без изменения объектов',
        default=False,
        options={'HIDDEN', 'SKIP_SAVE'},
    )

    @classmethod
    def poll(cls, context):
        return context.mode == 'OBJECT'

    def invoke(self, context, event):
        return self.execute(context)

    def execute(self, context):
        source = detect_source(context) if self.source == 'AUTO' else self.source
        scope, roots = collect_candidates(context, source)
        if not scope:
            self.report({'WARNING'}, 'Нет выделенных объектов или объектов в выбранной коллекции')
            return {'CANCELLED'}
        if source == 'COLLECTION':
            collection_name = context.view_layer.active_layer_collection.collection.name
            print(f'[Locations 14] ИСТОЧНИК: коллекция {collection_name} и её подколлекции')
        else:
            print('[Locations 14] ИСТОЧНИК: выделенные объекты')

        # Проверяем всю партию до первого изменения сцены.
        relevant_objects = list({obj for root in roots
                                 for obj in [root, *root.children]})
        user_map = bpy.data.user_map(subset=relevant_objects) if relevant_objects else {}
        plan = []
        for root in roots:
            meshes, reason = check_asset(context, root, scope, user_map)
            if reason:
                print(f'[Locations 14] ПРОПУСК {root.name}: {reason}')
            else:
                plan.append((root, meshes))
                names = ', '.join(obj.name for obj in meshes)
                print(f'[Locations 14] ПЛАН {root.name}: {names}')

        for obj in sorted(scope, key=lambda item: item.name):
            if obj.type == 'MESH' and (obj.parent is None or obj.parent.type != 'EMPTY'):
                print(f'[Locations 14] БЕЗ ИЗМЕНЕНИЙ {obj.name}: нет общего Empty')
            elif obj.type not in {'MESH', 'EMPTY'}:
                print(f'[Locations 14] ПРОПУСК {obj.name}: тип {obj.type}')

        if self.preview_only:
            self.report({'INFO'}, f'Проверка: готово к объединению {len(plan)}. Детали в консоли')
            return {'FINISHED'}

        saved_selection = [obj.name for obj in context.selected_objects]
        saved_active = context.view_layer.objects.active
        saved_active_name = saved_active.name if saved_active else None
        converted = {}
        completed = 0
        failed = False
        for root, meshes in plan:
            asset_name = root.name
            member_names = [root.name, *(obj.name for obj in meshes)]
            try:
                joined = merge_asset(context, root, meshes)
                converted.update({name: joined for name in member_names})
                completed += 1
                print(f'[Locations 14] ГОТОВО {asset_name}')
            except Exception as error:
                # Сохраняем возможность Undo для уже выполненной части партии.
                print(f'[Locations 14] ОШИБКА {asset_name}: {error}')
                failed = True
                break

        for obj in list(context.selected_objects):
            obj.select_set(False)
        for name in saved_selection:
            obj = converted.get(name) or context.view_layer.objects.get(name)
            if obj is not None:
                obj.select_set(True)
        active = (converted.get(saved_active_name)
                  or context.view_layer.objects.get(saved_active_name or ''))
        context.view_layer.objects.active = active
        context.view_layer.update()
        level = {'WARNING'} if failed else {'INFO'}
        self.report(level, f'Объединено: {completed}. Детали в системной консоли')
        return {'FINISHED'}


def register():
    previous = getattr(bpy.types, OBJECT_OT_locations14_prepare_assets.__name__, None)
    if previous is not None:
        bpy.utils.unregister_class(previous)
    bpy.utils.register_class(OBJECT_OT_locations14_prepare_assets)


if __name__ == '__main__':
    register()
    bpy.ops.object.locations14_prepare_assets('INVOKE_DEFAULT')
