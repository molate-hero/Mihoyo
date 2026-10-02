extends Node

const LAN_SESSION = preload("res://scripts/lan_session.gd")
const SARAH_SCALE := 0.2
const SARAH_RADIUS := 0.12 * SARAH_SCALE
const SEAM_LIMIT := 1.0 - 0.28 * SARAH_SCALE
const ROAD_CLEARANCE := 0.17 - SARAH_RADIUS

const KATE_SCENE = preload("res://assets/characters/kate.glb")
const SARAH_SCENE = preload("res://assets/characters/sarah.glb")
const LAND_SCENE = preload("res://assets/lands.glb")
const SHELL_HEIGHT := 0.29

const COLORS = [Color("e4b46c"), Color("7cc9b0"), Color("9aa9e8"), Color("df9196"), Color("82b9dc"), Color("c0a4da")]
const NORMALS = [Vector3.UP, Vector3.DOWN, Vector3.RIGHT, Vector3.LEFT, Vector3.FORWARD, Vector3.BACK]
const ARMS = [Vector2.RIGHT, Vector2.LEFT, Vector2.DOWN, Vector2.UP]
var blocks: Array[Node3D] = []
var tiles: Array[Dictionary] = []
var world: Node3D
var room: Node3D
var mini: Node3D
var mini_blocks: Array[Node3D] = []
var sarah: Node3D
var kate: Node3D
var camera: Camera3D
var left_camera: Camera3D
var current_tile := 0
var uv := Vector2.ZERO
var rotating := false
var entering := false
var inside := false
var won := false
var selected_axis := 0
var selected_layer := 1
var status: Label
var selector: Label
var fade: ColorRect
var turns := 0
var well_tile := 0
var start_tile := 0
var start_uv := Vector2.ZERO
var well_uv := Vector2.ZERO
var authored_route: Array = []
var turn_tween: Tween
var tests_failed := 0
var sarah_visual: Node3D
var kate_visual: Node3D
var sarah_animation: AnimationPlayer
var kate_animation: AnimationPlayer
var sarah_walking := false
var kate_walking := false
var camera_yaw := 0.0
var camera_pitch := 0.5
var heading_yaw := 0.0
var mouse_orbit := false
var mouse_role := ""
var kate_camera_yaw := 0.0
var kate_camera_pitch := 0.32
var shared_world := World3D.new()
var split_views: Array[SubViewport] = []
var lan: Node
var offline_mode := false
var lobby: Control
var lobby_message: Label
var lobby_role: OptionButton
var lobby_address: LineEdit
var lobby_port: SpinBox
var host_button: Button
var join_button: Button
var ready_button: Button
var leave_button: Button
var exit_button: Button
var network_badge: Label
var game_buttons: Array[Button] = []
var well_tween: Tween
var remote_state: Dictionary = {}
var reset_serial := 0
var remote_reset_serial := -1


func material(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = 0.85
	return m

func box(parent: Node3D, size: Vector3, position: Vector3, color: Color) -> MeshInstance3D:
	var mesh := MeshInstance3D.new()
	var shape := BoxMesh.new()
	shape.size = size
	mesh.mesh = shape
	mesh.material_override = material(color)
	parent.add_child(mesh)
	mesh.position = position
	return mesh

func setup_view(container: Control, scene: Node3D) -> SubViewport:
	var view := SubViewport.new()
	view.world_3d = shared_world
	view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	container.add_child(view)
	view.add_child(scene)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45, -30, 0)
	light.light_energy = 0.7
	light.shadow_enabled = true
	scene.add_child(light)
	var env := WorldEnvironment.new()
	var settings := Environment.new()
	settings.background_mode = Environment.BG_COLOR
	settings.background_color = Color("182332")
	settings.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	settings.ambient_light_color = Color("bccbe0")
	settings.ambient_light_energy = 0.35
	env.environment = settings
	scene.add_child(env)
	return view

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	offline_mode = "--self-test" in args or "--capture" in args or "--offline" in args
	var canvas := Control.new()
	canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(canvas)
	var split := Control.new()
	split.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	split.offset_top = 105
	split.offset_bottom = -145
	canvas.add_child(split)
	world = Node3D.new()
	room = Node3D.new()
	for i in range(2):
		var scene: Node3D = [room,world][i]
		var container := SubViewportContainer.new()
		container.stretch = true
		container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		container.size_flags_vertical = Control.SIZE_EXPAND_FILL
		split.add_child(container)
		container.anchor_left = i*0.5
		container.anchor_right = (i+1)*0.5
		container.anchor_bottom = 1.0
		container.size_flags_horizontal = Control.SIZE_FILL
		split_views.append(setup_view(container, scene))
	build_cube()
	build_room()
	room.position = Vector3(30,0,0)
	sarah = Node3D.new()
	world.add_child(sarah)
	sarah_visual = Node3D.new()
	sarah.add_child(sarah_visual)
	sarah_visual.scale = Vector3.ONE*SARAH_SCALE
	sarah_visual.add_child(SARAH_SCENE.instantiate())
	sarah_animation = setup_character_animation(sarah_visual)
	camera = Camera3D.new()
	camera.current = true
	camera.fov = 64
	camera.far = 20
	world.add_child(camera)
	build_ui(canvas)
	reset_demo()
	if not offline_mode:
		lan = LAN_SESSION.new()
		lan.name = "LAN"
		add_child(lan)
		build_lobby(canvas)
		lan.changed.connect(refresh_lobby)
		refresh_lobby()
		start_cli_session(args)
		if "--lan-test" in args:
			var test_node := Node.new()
			test_node.set_script(load("res://scripts/lan_smoke_test.gd"))
			add_child(test_node)
		if "--capture-lobby" in args:
			call_deferred("capture","res://lan-preview.png")
	if "--self-test" in OS.get_cmdline_user_args():
		call_deferred("self_test")
	if "--capture" in OS.get_cmdline_user_args():
		call_deferred("capture")

func build_cube() -> void:
	var imported := LAND_SCENE.instantiate() as Node3D
	world.add_child(imported)
	var block_map := {}
	for child in imported.get_children():
		var block := child as Node3D
		block.reparent(world)
		block.set_meta("initial",block.transform)
		blocks.append(block)
		block_map[String(block.name)] = block
		# Internal solid core, hidden behind the model's six surface plates.
		box(block,Vector3.ONE*1.96,Vector3.ZERO,Color("343a41"))
	imported.queue_free()
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://assets/lands_navigation.json"))
	authored_route = data.route
	for record in data.tiles:
		var id: Array = record.block
		var block: Node3D = block_map["Block_%d_%d_%d" % [id[0],id[1],id[2]]]
		var n: Vector3 = NORMALS[int(record.face)]
		var u := Vector3.RIGHT if abs(n.x) < 0.5 else Vector3.BACK
		var v := u.cross(n)
		var tile := Node3D.new()
		block.add_child(tile)
		tile.transform = Transform3D(Basis(u,n,v),n)
		var rects: Array[Rect2] = []
		for r in record.rects:
			rects.append(Rect2(Vector2(r[0],r[1]),Vector2(r[2]-r[0],r[3]-r[1])))
		var ports := road_ports(rects)
		if record.markers.has("Node 0"):
			start_tile = tiles.size()
			var point: Array = record.markers["Node 0"]
			start_uv = Vector2(point[0],point[1])
		if record.markers.has("Node X"):
			well_tile = tiles.size()
			var point: Array = record.markers["Node X"]
			well_uv = Vector2(point[0],point[1])
		tiles.append({"node":tile,"arms":range(ports.size()),"ports":ports,"rects":rects,"block":block,"face":int(record.face)})
	var well: Node3D = tiles[well_tile].node
	box(well,Vector3(0.38,0.06,0.38),Vector3(well_uv.x,0.29,well_uv.y),Color("152333"))
	for x in [-0.23,0.23]:
		box(well,Vector3(0.04,0.35,0.45),Vector3(well_uv.x+x,0.4,well_uv.y),Color("7ce0c1"))

func road_ports(rects: Array[Rect2]) -> Array[Dictionary]:
	var ports: Array[Dictionary] = []
	for arm in range(4):
		var intervals: Array[Vector2] = []
		for r in rects:
			var reaches := (r.end.x >= 0.999 if arm == 0 else (r.position.x <= -0.999 if arm == 1 else (r.end.y >= 0.999 if arm == 2 else r.position.y <= -0.999)))
			if reaches:
				intervals.append(Vector2(r.position.y,r.end.y) if arm < 2 else Vector2(r.position.x,r.end.x))
		intervals.sort_custom(func(a,b): return a.x < b.x)
		var merged: Array[Vector2] = []
		for interval in intervals:
			if not merged.is_empty() and interval.x <= merged[-1].y+0.001:
				merged[-1].y = maxf(merged[-1].y,interval.y)
			else:
				merged.append(interval)
		for interval in merged:
			if interval.y-interval.x > 0.01:
				var d: Vector2 = ARMS[arm]
				var tangent := Vector2(0,1) if arm < 2 else Vector2(1,0)
				ports.append({"arm":arm,"uv":d+tangent*(interval.x+interval.y)*0.5,"width":interval.y-interval.x})
	return ports

func build_room() -> void:
	box(room, Vector3(10,0.2,10), Vector3(0,-0.1,0), Color("9faaba"))
	box(room, Vector3(10,4,0.2), Vector3(0,2,-5), Color("718196"))
	box(room, Vector3(0.2,4,10), Vector3(-5,2,0), Color("7d8da0"))
	box(room, Vector3(0.2,4,10), Vector3(5,2,0), Color("7d8da0"))
	box(room, Vector3(10,4,0.2), Vector3(0,2,5), Color("718196"))
	box(room, Vector3(3,0.18,2), Vector3(0,1.15,0), Color("c0a88a"))
	for x in [-1.2,1.2]:
		for z in [-0.7,0.7]:
			box(room, Vector3(0.12,1.1,0.12), Vector3(x,0.55,z), Color("8b7762"))
	mini = Node3D.new()
	room.add_child(mini)
	mini.position = Vector3(0,2.05,0)
	mini.scale = Vector3.ONE*0.23
	for block in blocks:
		var copy := block.duplicate() as Node3D
		mini.add_child(copy)
		mini_blocks.append(copy)
	kate = Node3D.new()
	room.add_child(kate)
	kate.position = Vector3(0,0,2.1)
	kate_visual = Node3D.new()
	kate.add_child(kate_visual)
	kate_visual.add_child(KATE_SCENE.instantiate())
	kate_animation = setup_character_animation(kate_visual)
	left_camera = Camera3D.new()
	room.add_child(left_camera)
	left_camera.fov = 70
	update_kate_camera()
	left_camera.current = true
	left_camera.far = 20
	box(room, Vector3(1,0.04,1), Vector3(3,0.03,2.1), Color("7ce0c1"))

func label_at(parent: Control, text: String, pos: Vector2, font_size: int) -> Label:
	var label := Label.new()
	label.text = text
	label.position = pos
	label.add_theme_font_size_override("font_size", font_size)
	parent.add_child(label)
	return label

func build_ui(canvas: Control) -> void:
	label_at(canvas,"SHELL / KERNEL    |    双人联机实验",Vector2(24,14),28)
	label_at(canvas,"KATE · 内核 / 桌上魔方",Vector2(24,65),18)
	var right_title := label_at(canvas,"SARAH · 外壳 / 道路",Vector2.ZERO,18)
	right_title.anchor_left = 0.5
	right_title.anchor_right = 0.5
	right_title.offset_left = 24
	right_title.offset_top = 65
	var panel := VBoxContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	panel.offset_top = -133
	panel.offset_left = 24
	panel.offset_right = -24
	canvas.add_child(panel)
	selector = Label.new()
	panel.add_child(selector)
	var row := HBoxContainer.new()
	panel.add_child(row)
	for axis in range(3):
		var b := Button.new()
		b.text = ["X轴 [1]","Y轴 [2]","Z轴 [3]"][axis]
		b.pressed.connect(func(): choose_axis(axis))
		row.add_child(b)
	for layer in range(3):
		var b := Button.new()
		b.text = "层 %d [%d]" % [layer,layer+7]
		b.pressed.connect(func(): choose_layer(layer-1))
		row.add_child(b)
	for direction in [-1,1]:
		var b := Button.new()
		b.text = "-90° [Q]" if direction == -1 else "+90° [E]"
		b.pressed.connect(func(): player_turn(direction))
		row.add_child(b)
	var reset := Button.new()
	reset.text = "重置 [R]"
	reset.pressed.connect(player_reset)
	row.add_child(reset)
	for button in row.get_children():
		button.focus_mode = Control.FOCUS_NONE
		game_buttons.append(button)
	status = Label.new()
	panel.add_child(status)
	var help := Label.new()
	help.text = "WASD 移动 · 在自己的画面按住左键转动视角 | Kate：Q/E 转魔方 | Sarah：空格入井 | 松开左键 / Esc 停止转动"
	panel.add_child(help)
	fade = ColorRect.new()
	fade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	fade.color = Color(0,0,0,0)
	fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	canvas.add_child(fade)

func update_selector() -> void:
	selector.text = "Kate 选择：%s轴 / 层%d（负侧0 · 中间1 · 正侧2）    转动次数：%d" % [["X","Y","Z"][selected_axis],selected_layer+1,turns]

func reset_demo() -> void:
	if entering:
		return
	if turn_tween and turn_tween.is_running():
		turn_tween.kill()
	reset_serial += 1
	rotating = false
	inside = false
	camera_yaw = 0.0
	camera_pitch = 0.5
	kate_camera_yaw = 0.0
	kate_camera_pitch = 0.32
	mouse_role = ""
	heading_yaw = 0.0
	mouse_orbit = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	won = false
	turns = 0
	kate.position = Vector3(0,0,2.1)
	kate_visual.rotation.y = 0.0
	play_character_animation(kate_animation,false)
	play_character_animation(sarah_animation,false)
	update_kate_camera()
	for block in blocks:
		block.transform = block.get_meta("initial")
	# Fixed scramble: inverse of the hint. The start tile stays still.
	apply_turn(0,1,-1)
	current_tile = start_tile
	uv = start_uv
	selected_axis = 0
	selected_layer = 1
	if sarah.get_parent() != world:
		sarah.reparent(world)
	if camera.get_parent() != world:
		camera.reparent(world)
	status.text = "沿模型道路从 0 到 X。提示：Kate 按 E 撤销初始打乱，先接通六面路线。"
	update_selector()
	sync_mini()
	update_sarah()

func apply_turn(axis: int, layer: int, direction: int) -> void:
	var axis_vector := Vector3.ZERO
	axis_vector[axis] = 1
	var rotation := Basis(axis_vector,direction*PI/2)
	for block in blocks:
		if roundi(block.position[axis]/2) == layer:
			block.transform = Transform3D(rotation*block.basis,rotation*block.position)
			block.position = block.position.snapped(Vector3.ONE)

func request_turn(direction: int) -> void:
	if rotating or entering or won or inside:
		return
	if Vector2(kate.position.x,kate.position.z).length() > 2.7:
		status.text = "Kate 需要先走到桌边才能操作魔方。"
		return
	if max(abs(uv.x),abs(uv.y)) > SEAM_LIMIT:
		status.text = "Sarah 靠近接缝：请先退回面片内部，再转动。"
		return
	rotating = true
	var axis_vector := Vector3.ZERO
	axis_vector[selected_axis] = 1
	var selected: Array[Node3D] = []
	var originals: Array[Transform3D] = []
	for block in blocks:
		if roundi(block.position[selected_axis]/2) == selected_layer:
			selected.append(block)
			originals.append(block.transform)
	turn_tween = create_tween()
	turn_tween.tween_method(func(angle: float):
		var b := Basis(axis_vector,angle)
		for i in range(selected.size()):
			selected[i].transform = Transform3D(b*originals[i].basis,b*originals[i].origin)
	,0.0,direction*PI/2,0.65).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	turn_tween.tween_callback(func():
		for block in selected:
			block.position = block.position.snapped(Vector3.ONE)
			var b := block.basis
			block.basis = Basis(b.x.snapped(Vector3.ONE),b.y.snapped(Vector3.ONE),b.z.snapped(Vector3.ONE))
		rotating = false
		turns += 1
		update_selector()
		status.text = "转动完成，可跨越已连接的道路。"
	)

func sync_mini() -> void:
	for i in range(blocks.size()):
		mini_blocks[i].transform = blocks[i].transform

func road_contains(point: Vector2, tile_id: int) -> bool:
	# Imported road rectangles, with body clearance; do not erode tile edges.
	for r: Rect2 in tiles[tile_id].rects:
		var lo := r.position+Vector2.ONE*SARAH_RADIUS
		var hi := r.end-Vector2.ONE*SARAH_RADIUS
		if r.position.x <= -0.999: lo.x = -1.01
		if r.position.y <= -0.999: lo.y = -1.01
		if r.end.x >= 0.999: hi.x = 1.01
		if r.end.y >= 0.999: hi.y = 1.01
		if point.x >= lo.x and point.y >= lo.y and point.x <= hi.x and point.y <= hi.y:
			return true
	return false

func connection(tile_id: int, port_id: int) -> Vector2i:
	var tile: Node3D = tiles[tile_id].node
	var port: Dictionary = tiles[tile_id].ports[port_id]
	var d: Vector2 = port.uv
	var endpoint := tile.to_global(Vector3(d.x,0,d.y))
	for other in range(tiles.size()):
		if other == tile_id: continue
		var node: Node3D = tiles[other].node
		for a in range(tiles[other].ports.size()):
			var next: Dictionary = tiles[other].ports[a]
			var e: Vector2 = next.uv
			if absf(port.width-next.width) < 0.003 and endpoint.distance_to(node.to_global(Vector3(e.x,0,e.y))) < 0.003:
				return Vector2i(other,a)
	return Vector2i(-1,-1)

func move_shell(delta: float, test_input := Vector2.INF) -> void:
	var input := Vector2(float(Input.is_physical_key_pressed(KEY_D))-float(Input.is_physical_key_pressed(KEY_A)),float(Input.is_physical_key_pressed(KEY_S))-float(Input.is_physical_key_pressed(KEY_W)))
	if test_input != Vector2.INF:
		input = test_input
	elif not offline_mode:
		input = lan.movement("Sarah")
	else:
		input = camera_relative_move(input)
	if input == Vector2.ZERO:
		return
	var next := uv+input.normalized()*delta*1.5*SARAH_SCALE
	if not road_contains(next.clamp(Vector2.ONE*-1,Vector2.ONE),current_tile):
		return
	var limit := SEAM_LIMIT if rotating else 1.0
	if max(abs(next.x),abs(next.y)) > limit:
		if rotating:
			return
		var arm := 0 if next.x > 1 else (1 if next.x < -1 else (2 if next.y > 1 else 3))
		var link := Vector2i(-1,-1)
		for port_id in tiles[current_tile].arms:
			var port: Dictionary = tiles[current_tile].ports[port_id]
			var center: float = port.uv.y if arm < 2 else port.uv.x
			var tangent: float = next.y if arm < 2 else next.x
			var lo: float = center-port.width*0.5
			var hi: float = center+port.width*0.5
			var safe_lo: float = lo if lo <= -0.999 else lo+SARAH_RADIUS
			var safe_hi: float = hi if hi >= 0.999 else hi-SARAH_RADIUS
			if port.arm == arm and tangent >= safe_lo and tangent <= safe_hi:
				link = connection(current_tile,port_id)
				if link.x >= 0: break
		if link.x < 0:
			status.text = "道路未连接：请让 Kate 调整魔方。"
			return
		var boundary := next.clamp(Vector2.ONE*-1,Vector2.ONE)
		var old_node: Node3D = tiles[current_tile].node
		var new_node: Node3D = tiles[link.x].node
		var crossing := new_node.to_local(old_node.to_global(Vector3(boundary.x,0,boundary.y)))
		var incoming: Dictionary = tiles[link.x].ports[link.y]
		var landing: Vector2 = Vector2(crossing.x,crossing.z)-ARMS[incoming.arm]*0.02
		if not road_contains(landing,link.x): return
		heading_yaw = atan2(-input.x,-input.y)
		rebase_camera(current_tile,link.x)
		current_tile = link.x
		uv = landing
		sarah_walking = true
		status.text = "已跨过道路接缝。"
	else:
		uv = next
		sarah_walking = true
		heading_yaw = atan2(-input.x,-input.y)

func update_sarah() -> void:
	var tile: Node3D = tiles[current_tile].node
	sarah.global_transform = Transform3D(tile.global_basis,tile.to_global(Vector3(uv.x,SHELL_HEIGHT,uv.y)))
	var normal := tile.global_basis.y
	var pos := sarah.global_position
	sarah_visual.rotation.y = heading_yaw
	place_sarah_camera(pos,tile.global_basis,normal)

func _process(delta: float) -> void:
	if not is_instance_valid(sarah):
		return
	if not offline_mode:
		if not is_instance_valid(lan) or not lan.active: return
		lan.capture_input()
		if not lan.hosting:
			render_client(delta)
			return
	sarah_walking = false
	kate_walking = false
	sync_mini()
	move_kate(delta)
	update_kate_camera()
	play_character_animation(kate_animation,kate_walking)
	step_sarah(delta,lan.movement("Sarah") if not offline_mode else camera_relative_move(Vector2(float(Input.is_physical_key_pressed(KEY_D))-float(Input.is_physical_key_pressed(KEY_A)),float(Input.is_physical_key_pressed(KEY_S))-float(Input.is_physical_key_pressed(KEY_W)))))

func simulate_network_player(role: String, move: Vector2, delta: float) -> void:
	if role == "Kate":
		kate_walking = false
		move_kate(delta,move)
		update_kate_camera()
		play_character_animation(kate_animation,kate_walking)
	else:
		sarah_walking = false
		step_sarah(delta,move)

func step_sarah(delta: float, input: Vector2) -> void:
	if entering or won:
		play_character_animation(sarah_animation,false)
		return
	if inside:
		var d := Vector3(input.x,0,input.y)
		if d.length() > 0.01:
			heading_yaw = atan2(-d.x,-d.z)
			sarah_visual.rotation.y = heading_yaw
		var before_position := sarah.position
		sarah.position += d.normalized()*delta*2*SARAH_SCALE
		sarah.position.x = clampf(sarah.position.x,-4,4)
		sarah.position.z = clampf(sarah.position.z,1.6,4)
		sarah_walking = sarah.position.distance_to(before_position) > 0.00001
		play_character_animation(sarah_animation,sarah_walking)
		update_room_sarah_camera()
		if (offline_mode or lan.hosting) and sarah.position.distance_to(kate.position) < 0.45+0.35*SARAH_SCALE:
			won = true
			status.text = "汇合成功！Sarah 已找到 Kate。按 R 重新开始。"
		return
	move_shell(delta,input)
	play_character_animation(sarah_animation,sarah_walking)
	update_sarah()

func enter_well() -> void:
	if current_tile != well_tile or uv.distance_to(well_uv) > 0.4*SARAH_SCALE or rotating or entering or inside:
		status.text = "请在转动结束后，站到青绿色井口中央按空格。"
		return
	entering = true
	var tween := create_tween()
	well_tween = tween
	tween.tween_property(fade,"color",Color.BLACK,0.45)
	tween.tween_callback(func():
		inside = true
		sarah.reparent(room)
		sarah.transform = Transform3D(Basis.IDENTITY,Vector3(3,0,2.1))
		camera_yaw = 0.0
		heading_yaw = 0.0
		update_room_sarah_camera()
		status.text = "已进入内核：用 WASD 走近蓝色 Kate。"
	)
	tween.tween_property(fade,"color",Color(0,0,0,0),0.45)
	tween.tween_callback(func(): entering = false)

func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo: return
	if not offline_mode and not lan.active: return
	var controls_kate: bool = offline_mode or lan.role == "Kate"
	match event.physical_keycode:
		KEY_1,KEY_2,KEY_3:
			if controls_kate: choose_axis(event.physical_keycode-KEY_1)
		KEY_7,KEY_8,KEY_9:
			if controls_kate: choose_layer(event.physical_keycode-KEY_7-1)
		KEY_Q:
			if controls_kate: player_turn(-1)
		KEY_E:
			if controls_kate: player_turn(1)
		KEY_R: player_reset()
		KEY_SPACE:
			if offline_mode: enter_well()
			elif lan.role == "Sarah": lan.command("well")

func check(condition: bool, description: String) -> void:
	if not condition:
		tests_failed += 1
		push_error(description)
	else:
		print("PASS: ",description)

func reachable(start: int, goal: int) -> bool:
	var seen := {start:true}
	var queue: Array[int] = [start]
	while not queue.is_empty():
		var id: int = queue.pop_front()
		if id == goal:
			return true
		for a in tiles[id].arms:
			var link := connection(id,a)
			if link.x >= 0 and not seen.has(link.x):
				seen[link.x] = true
				queue.append(link.x)
	return false

func self_test() -> void:
	await get_tree().process_frame
	check(split_views[0].size == split_views[1].size,"split viewports have equal dimensions")
	check(left_camera.global_position.distance_to(kate.global_position) < 3.2,"Kate camera follows from inside room")
	check(camera.global_position.distance_to(sarah.global_position) < 3.2,"Sarah camera follows at third-person distance")
	check(sarah_animation.has_animation("walk") and kate_animation.has_animation("idle"),"both character models have skeletal idle/walk animations")
	play_character_animation(sarah_animation,true)
	check(sarah_animation.current_animation == "walk","walking switches to skeletal walk clip")
	play_character_animation(sarah_animation,false)
	check(sarah_animation.current_animation == "idle","stopping switches to idle clip")
	check(blocks.size() == 26 and tiles.size() == 54,"26 shell blocks / 54 tiles")
	check(is_equal_approx(SEAM_LIMIT,0.944) and is_equal_approx(SARAH_RADIUS,0.024),"scaled seam margin and body clearance")
	check(not reachable(start_tile,well_tile),"scramble blocks the initial route")
	var original: Array[Transform3D] = []
	for block in blocks:
		original.append(block.transform)
	for axis in range(3):
		for layer in range(-1,2):
			for i in range(4):
				apply_turn(axis,layer,1)
			var restored := true
			for i in range(blocks.size()):
				restored = restored and blocks[i].transform.is_equal_approx(original[i])
			check(restored,"four quarter turns restore axis %d layer %d" % [axis,layer])
	apply_turn(0,1,1)
	check(reachable(start_tile,well_tile),"hint connects start to well")
	for i in range(tiles.size()):
		for a in tiles[i].arms:
			var link := connection(i,a)
			if link.x >= 0:
				check(connection(link.x,link.y).x == i,"connection symmetry %d" % i)
	check(validate_authored_route(),"all imported route segments lie on walkable roads")
	check(walk_authored_route(),"Sarah traverses all six imported faces from 0 to X")
	current_tile = start_tile
	uv = start_uv
	var before := uv
	move_shell(0.05,Vector2.UP)
	check(uv != before,"Sarah moves along imported starting road")
	current_tile = well_tile
	uv = well_uv
	uv = Vector2((1.0+SEAM_LIMIT)*0.5,0)
	request_turn(1)
	check(not rotating,"seam position prevents starting a turn")
	uv = well_uv
	request_turn(1)
	await get_tree().create_timer(0.3).timeout
	var tile: Node3D = tiles[current_tile].node
	check(sarah.global_position.distance_to(tile.to_global(Vector3(well_uv.x,SHELL_HEIGHT,well_uv.y))) < 0.01,"Sarah follows animated block")
	check(sarah.global_basis.y.is_equal_approx(tile.global_basis.y),"gravity frame follows animated tile normal")
	await get_tree().create_timer(0.5).timeout
	check(not rotating,"quarter-turn animation completes")
	enter_well()
	await get_tree().create_timer(1.1).timeout
	check(inside and sarah.get_parent() == room,"well transition enters fixed kernel")
	sarah.position = kate.position+Vector3(0.5,0,0)
	await get_tree().process_frame
	await get_tree().process_frame
	check(won,"meeting Kate wins")
	reset_demo()
	check(not won and not inside and current_tile == start_tile,"reset restores shell state")
	camera_yaw = PI/2
	var direction := camera_relative_move(Vector2.UP)
	check(direction.is_equal_approx(Vector2.LEFT),"Sarah W moves along manual camera forward")
	camera_yaw = 0.0
	check(camera_relative_move(Vector2.UP).is_equal_approx(Vector2.UP),"held movement immediately uses changed manual camera")
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.position = get_viewport().get_visible_rect().size*Vector2(0.75,0.5)
	click.pressed = true
	_input(click)
	check(mouse_orbit and mouse_role == "Sarah","left drag selects Sarah viewport")
	check(Input.mouse_mode == Input.MOUSE_MODE_VISIBLE,"left drag keeps pointer visible without capture")
	click.pressed = false
	_input(click)
	check(not mouse_orbit and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE,"left release stops orbit and restores cursor")
	click.position = Vector2(20,20)
	click.pressed = true
	_input(click)
	check(not mouse_orbit,"UI clicks do not capture camera")
	mouse_orbit = true
	mouse_role = "Sarah"
	var motion := InputEventMouseMotion.new()
	motion.relative = Vector2(100,1000)
	_input(motion)
	check(is_equal_approx(camera_yaw,-0.4) and is_equal_approx(camera_pitch,1.05),"Sarah mouse orbit changes yaw and clamps pitch")
	mouse_role = "Kate"
	motion.relative = Vector2(100,40)
	_input(motion)
	check(is_equal_approx(kate_camera_yaw,-0.4) and is_equal_approx(kate_camera_pitch,0.48),"Kate mouse orbit changes yaw and pitch")
	check(is_equal_approx(camera_yaw,-0.4),"Kate mouse control leaves Sarah camera unchanged")
	kate_camera_yaw = PI/2
	check(camera_relative_move(Vector2.UP,"Kate").is_equal_approx(Vector2.LEFT),"Kate W moves along manual camera forward")
	mouse_orbit = false
	mouse_role = ""
	camera_yaw = 0.6
	heading_yaw = -1.2
	await get_tree().create_timer(0.2).timeout
	check(is_equal_approx(camera_yaw,0.6),"Sarah camera never auto-aligns to character heading")
	reset_demo()
	print("SELF TEST: ",tests_failed," failures")
	get_tree().quit(1 if tests_failed else 0)

func capture(path := "res://demo-preview.png") -> void:
	await get_tree().create_timer(1.0).timeout
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)
	get_tree().quit()

func update_kate_camera() -> void:
	var target := kate.global_position+Vector3.UP*1.05
	var forward := Basis(Vector3.UP,kate_camera_yaw)*Vector3.FORWARD
	var position := target-forward*cos(kate_camera_pitch)*2.5+Vector3.UP*sin(kate_camera_pitch)*2.5
	var local := room.to_local(position)
	local.x = clampf(local.x,-4.7,4.7)
	local.y = clampf(local.y,0.3,3.7)
	local.z = clampf(local.z,-4.7,4.7)
	left_camera.global_position = room.to_global(local)
	left_camera.look_at(target,Vector3.UP)

func update_room_sarah_camera() -> void:
	place_sarah_camera(sarah.global_position,Basis.IDENTITY,Vector3.UP)
	var local := room.to_local(camera.global_position)
	local.x = clampf(local.x,-4.75,4.75)
	local.z = clampf(local.z,-4.75,4.75)
	camera.global_position = room.to_global(local)
	camera.look_at(sarah.global_position+Vector3.UP*0.55*SARAH_SCALE,Vector3.UP)

func move_kate(delta: float, test_input := Vector2.INF) -> void:
	if entering or won:
		return
	var move: Vector2 = lan.movement("Kate") if not offline_mode else Vector2(float(Input.is_physical_key_pressed(KEY_RIGHT))-float(Input.is_physical_key_pressed(KEY_LEFT)),float(Input.is_physical_key_pressed(KEY_DOWN))-float(Input.is_physical_key_pressed(KEY_UP)))
	if test_input != Vector2.INF: move = test_input
	elif offline_mode: move = camera_relative_move(move,"Kate")
	var d := Vector3(move.x,0,move.y)
	var next := kate.position+d.normalized()*delta*2.0
	next.x = clampf(next.x,-4.3,4.3)
	next.z = clampf(next.z,-4.3,4.3)
	if abs(next.x) < 1.75 and abs(next.z) < 1.35:
		return
	kate_walking = kate.position.distance_to(next) > 0.00001
	if kate_walking:
		kate_visual.rotation.y = atan2(-d.x,-d.z)
	kate.position = next

func camera_relative_move(raw: Vector2, role := "Sarah") -> Vector2:
	var yaw := kate_camera_yaw if role == "Kate" else camera_yaw
	var movement := Basis(Vector3.UP,yaw)*Vector3(raw.x,0,raw.y)
	return Vector2(movement.x,movement.z).limit_length()

func place_sarah_camera(pos: Vector3, frame: Basis, normal: Vector3) -> void:
	var forward := frame*(Basis(Vector3.UP,camera_yaw)*Vector3.FORWARD)
	var target := pos+normal*0.55*SARAH_SCALE
	var distance := 2.9*SARAH_SCALE
	camera.global_position = target-forward*cos(camera_pitch)*distance+normal*sin(camera_pitch)*distance
	camera.look_at(target,normal)

func rebase_camera(old_id: int, new_id: int) -> void:
	var old_frame: Basis = tiles[old_id].node.global_basis
	var new_frame: Basis = tiles[new_id].node.global_basis
	var transport := Basis(Quaternion(old_frame.y,new_frame.y))
	var angles := [camera_yaw,heading_yaw]
	for i in range(angles.size()):
		var direction := new_frame.inverse()*transport*old_frame*(Basis(Vector3.UP,angles[i])*Vector3.FORWARD)
		angles[i] = atan2(-direction.x,-direction.z)
	camera_yaw = angles[0]
	heading_yaw = angles[1]

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		mouse_orbit = false
		mouse_role = ""
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _input(event: InputEvent) -> void:
	if not offline_mode and (not is_instance_valid(lan) or not lan.active): return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			var size := get_viewport().get_visible_rect().size
			if event.position.y < 105 or event.position.y > size.y-145: return
			var hovered_role := "Kate" if event.position.x < size.x*0.5 else "Sarah"
			if not offline_mode and hovered_role != lan.role: return
			mouse_role = hovered_role
			mouse_orbit = true
			# Ordinary drag keeps the pointer at the click position.
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		else:
			# GUI buttons must receive releases when no camera drag began.
			if not mouse_orbit: return
			mouse_orbit = false
			mouse_role = ""
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and mouse_orbit:
		if mouse_role == "Kate":
			kate_camera_yaw -= event.relative.x*0.004
			kate_camera_pitch = clampf(kate_camera_pitch+event.relative.y*0.004,0.15,1.05)
		elif mouse_role == "Sarah":
			camera_yaw -= event.relative.x*0.004
			camera_pitch = clampf(camera_pitch+event.relative.y*0.004,0.15,1.05)
		get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.pressed and event.physical_keycode == KEY_ESCAPE:
		mouse_orbit = false
		mouse_role = ""
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func validate_authored_route() -> bool:
	for section in authored_route:
		var points: Array = section.points
		for index in range(points.size()-1):
			var a := Vector3(points[index][0],points[index][1],points[index][2])
			var b := Vector3(points[index+1][0],points[index+1][1],points[index+1][2])
			for step in range(101):
				var point := a.lerp(b,step/100.0)
				var on_road := false
				for id in range(tiles.size()):
					var node: Node3D = tiles[id].node
					var local := node.to_local(point)
					if absf(local.y) < 0.001 and maxf(absf(local.x),absf(local.z)) <= 1.001 and road_contains(Vector2(local.x,local.z),id):
						on_road = true
						break
				if not on_road:
					push_error("Missing imported road at %s (%s)" % [point,section.theme])
					return false
	return true

func route_point(value: Array) -> Vector3:
	return Vector3(value[0],value[1],value[2])

func walk_authored_route() -> bool:
	current_tile = start_tile
	uv = start_uv
	for section_id in range(authored_route.size()):
		var points: Array = authored_route[section_id].points
		for waypoint in range(1,points.size()):
			var target := route_point(points[waypoint])
			var reached := false
			for step in range(ceili(1500.0 / SARAH_SCALE)):
				var tile: Node3D = tiles[current_tile].node
				var current := tile.to_global(Vector3(uv.x,0,uv.y))
				if current.distance_to(target) < 0.025:
					reached = true
					break
				var local := tile.global_basis.inverse()*(target-current)
				move_shell(0.01,Vector2(local.x,local.z).normalized())
			if not reached:
				push_error("Route walk stuck in %s at waypoint %d tile %d uv %s" % [authored_route[section_id].theme,waypoint,current_tile,uv])
				return false
		if section_id < authored_route.size()-1:
			var original_face: int = tiles[current_tile].face
			var outward := (route_point(points[-1])-route_point(points[-2])).normalized()
			for step in range(ceili(10.0 / SARAH_SCALE)):
				var tile: Node3D = tiles[current_tile].node
				var local := tile.global_basis.inverse()*outward
				move_shell(0.01,Vector2(local.x,local.z).normalized())
				if tiles[current_tile].face != original_face: break
			if tiles[current_tile].face == original_face:
				push_error("Cannot cross face edge after %s" % authored_route[section_id].theme)
				return false
	return current_tile == well_tile and uv.distance_to(well_uv) < 0.04

func setup_character_animation(visual: Node3D) -> AnimationPlayer:
	var player := visual.find_child("AnimationPlayer",true,false) as AnimationPlayer
	for name in ["idle","walk"]:
		player.get_animation(name).loop_mode = Animation.LOOP_LINEAR
	player.play("idle")
	return player

func play_character_animation(player: AnimationPlayer, walking: bool) -> void:
	if not is_instance_valid(player): return
	var clip := "walk" if walking else "idle"
	if player.current_animation != clip:
		player.play(clip,0.15)
	player.speed_scale = 1.15 if walking else 1.0

func choose_axis(axis: int) -> void:
	if not offline_mode and (not lan.active or lan.role != "Kate"): return
	selected_axis = axis
	update_selector()
	if not offline_mode: lan.command("select",[selected_axis,selected_layer])

func choose_layer(layer: int) -> void:
	if not offline_mode and (not lan.active or lan.role != "Kate"): return
	selected_layer = layer
	update_selector()
	if not offline_mode: lan.command("select",[selected_axis,selected_layer])

func player_turn(direction: int) -> void:
	if offline_mode: request_turn(direction)
	elif lan.active and lan.role == "Kate": lan.command("turn",[selected_axis,selected_layer,direction])

func player_reset() -> void:
	if offline_mode: reset_demo()
	elif lan.active and lan.hosting: lan.command("reset")

func abort_network_game() -> void:
	if turn_tween and turn_tween.is_running(): turn_tween.kill()
	if well_tween and well_tween.is_running(): well_tween.kill()
	entering = false
	fade.color.a = 0.0
	remote_state.clear()
	reset_demo()

func make_snapshot() -> Dictionary:
	var transforms: Array[Transform3D] = []
	for block in blocks: transforms.append(block.transform)
	return {"blocks":transforms,"tile":current_tile,"uv":uv,"kate":kate.position,"kate_yaw":kate_visual.rotation.y,
		"kate_camera_yaw":kate_camera_yaw,"kate_camera_pitch":kate_camera_pitch,
		"sarah":sarah.position,"heading":heading_yaw,"yaw":camera_yaw,"pitch":camera_pitch,
		"rotating":rotating,"entering":entering,"inside":inside,"won":won,"turns":turns,
		"axis":selected_axis,"layer":selected_layer,"status":status.text,"fade":fade.color.a,
		"sarah_walk":sarah_walking,"kate_walk":kate_walking,"reset":reset_serial}

func receive_snapshot(state: Dictionary, initial := false) -> void:
	if state.blocks.size() != blocks.size(): return
	var resetting: bool = initial or remote_reset_serial != state.reset
	var next_tile: int = state.tile
	if not resetting and next_tile != current_tile and not inside and not state.inside:
		rebase_camera(current_tile,next_tile)
	if resetting:
		camera_yaw = state.yaw
		camera_pitch = state.pitch
		kate_camera_yaw = state.kate_camera_yaw
		kate_camera_pitch = state.kate_camera_pitch
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		mouse_orbit = false
	remote_reset_serial = state.reset
	if resetting or next_tile != current_tile: uv = state.uv
	current_tile = next_tile
	if inside != state.inside or resetting:
		var parent := room if state.inside else world
		if sarah.get_parent() != parent: sarah.reparent(parent)
		sarah.basis = Basis.IDENTITY
		sarah.position = state.sarah
		if state.inside:
			camera_yaw = 0.0
	inside = state.inside
	rotating = state.rotating
	entering = state.entering
	won = state.won
	turns = state.turns
	heading_yaw = state.heading
	if lan.role != "Kate" or initial:
		selected_axis = state.axis
		selected_layer = state.layer
	status.text = state.status
	remote_state = state
	lan.acknowledge_inputs(state.get("input_ack",0),resetting)
	for i in range(blocks.size()): blocks[i].transform = state.blocks[i]
	if lan.role == "Kate":
		kate.position = state.kate
		kate_visual.rotation.y = state.kate_yaw
	else:
		uv = state.uv
		sarah.position = state.sarah
	for command in lan.pending_inputs:
		if command.reset == remote_reset_serial and (lan.role != "Sarah" or inside or command.tile == current_tile):
			simulate_network_player(lan.role,command.move,LAN_SESSION.INPUT_STEP)
	update_selector()
	if resetting: render_client(1.0)

func render_client(delta: float) -> void:
	if remote_state.is_empty(): return
	var weight := 1.0-exp(-delta*25.0)
	for i in range(blocks.size()):
		blocks[i].transform = blocks[i].transform.interpolate_with(remote_state.blocks[i],weight) if rotating else remote_state.blocks[i]
	if lan.role != "Kate":
		kate.position = kate.position.lerp(remote_state.kate,weight)
		kate_visual.rotation.y = lerp_angle(kate_visual.rotation.y,remote_state.kate_yaw,weight)
	if lan.role != "Sarah":
		uv = uv.lerp(remote_state.uv,weight)
		heading_yaw = remote_state.heading
	if lan.role != "Kate":
		kate_camera_yaw = lerp_angle(kate_camera_yaw,remote_state.kate_camera_yaw,weight)
		kate_camera_pitch = lerpf(kate_camera_pitch,remote_state.kate_camera_pitch,weight)
	if lan.role != "Sarah":
		camera_yaw = lerp_angle(camera_yaw,remote_state.yaw,weight)
		camera_pitch = lerpf(camera_pitch,remote_state.pitch,weight)
	fade.color.a = lerpf(fade.color.a,remote_state.fade,weight)
	if inside:
		if lan.role != "Sarah": sarah.position = sarah.position.lerp(remote_state.sarah,weight)
		sarah_visual.rotation.y = heading_yaw
		update_room_sarah_camera()
	else:
		update_sarah()
	update_kate_camera()
	sync_mini()
	play_character_animation(kate_animation,kate_walking if lan.role == "Kate" else remote_state.kate_walk)
	play_character_animation(sarah_animation,sarah_walking if lan.role == "Sarah" else remote_state.sarah_walk)

func build_lobby(canvas: Control) -> void:
	network_badge = label_at(canvas,"",Vector2(760,20),18)
	exit_button = Button.new()
	exit_button.text = "离开房间"
	exit_button.position = Vector2(1280,18)
	exit_button.pressed.connect(func(): lan.leave())
	exit_button.focus_mode = Control.FOCUS_NONE
	canvas.add_child(exit_button)
	lobby = Control.new()
	lobby.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	canvas.add_child(lobby)
	var backdrop := TextureRect.new()
	backdrop.texture = load("res://assets/ui/lobby-background.png")
	backdrop.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	backdrop.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lobby.add_child(backdrop)
	var brand := label_at(lobby,"S H E L L  /  K E R N E L",Vector2(60,50),28)
	brand.add_theme_color_override("font_color",Color("eee8d7"))
	brand.add_theme_color_override("font_shadow_color",Color(0,0,0,0.8))
	brand.add_theme_constant_override("shadow_offset_x",2)
	brand.add_theme_constant_override("shadow_offset_y",2)
	var subtitle := label_at(lobby,"两种尺度 · 同一个世界",Vector2(62,96),18)
	subtitle.add_theme_color_override("font_color",Color("a8c7bd"))
	var story := label_at(lobby,"一个人改变世界\n另一个人寻找归途",Vector2(62,740),28)
	story.add_theme_color_override("font_color",Color("eee8d7"))
	label_at(lobby,"KATE / 内核     ×     SARAH / 外壳",Vector2(64,830),15)
	var theme := Theme.new()
	theme.default_font_size = 18
	for kind in ["Label","Button","OptionButton","LineEdit"]:
		theme.set_color("font_color",kind,Color("e8eee6"))
	for kind in ["Button","OptionButton","LineEdit"]:
		for state in ["normal","hover","pressed","focus","disabled"]:
			var box := StyleBoxFlat.new()
			box.bg_color = Color("203c3b") if state == "hover" else Color("142b2c")
			if state == "disabled": box.bg_color = Color("102223")
			box.border_color = Color("6dbaa5") if state in ["hover","focus"] else Color("345451")
			box.set_border_width_all(1)
			box.set_corner_radius_all(9)
			box.content_margin_left = 16
			box.content_margin_right = 16
			box.content_margin_top = 12
			box.content_margin_bottom = 12
			theme.set_stylebox(state,kind,box)
		theme.set_color("font_disabled_color",kind,Color("617773"))
	lobby.theme = theme
	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER_RIGHT)
	panel.offset_left = -590
	panel.offset_right = -60
	panel.offset_top = -345
	panel.offset_bottom = 345
	var surface := StyleBoxFlat.new()
	surface.bg_color = Color(0.035,0.085,0.09,0.94)
	surface.border_color = Color("395753")
	surface.set_border_width_all(1)
	surface.set_corner_radius_all(20)
	surface.shadow_color = Color(0,0,0,0.3)
	surface.shadow_size = 18
	panel.add_theme_stylebox_override("panel",surface)
	lobby.add_child(panel)
	var margin := MarginContainer.new()
	for side in ["left","right","top","bottom"]: margin.add_theme_constant_override("margin_"+side,32)
	panel.add_child(margin)
	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation",16)
	margin.add_child(stack)
	var eyebrow := Label.new()
	eyebrow.text = "LOCAL CO-OP  /  局域网双人"
	eyebrow.add_theme_font_size_override("font_size",14)
	eyebrow.add_theme_color_override("font_color",Color("91cdb6"))
	stack.add_child(eyebrow)
	var title := Label.new()
	title.text = "一起进入这个世界"
	title.add_theme_font_size_override("font_size",30)
	stack.add_child(title)
	var hint := Label.new()
	hint.text = "两台电脑，同一局域网。分别扮演 Kate 与 Sarah。"
	hint.add_theme_font_size_override("font_size",16)
	hint.add_theme_color_override("font_color",Color("a4b8b1"))
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	stack.add_child(hint)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation",12)
	stack.add_child(row)
	lobby_role = OptionButton.new()
	lobby_role.add_item("我扮演 Kate · 内核")
	lobby_role.add_item("我扮演 Sarah · 外壳")
	lobby_role.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(lobby_role)
	lobby_port = SpinBox.new()
	lobby_port.min_value = 1024
	lobby_port.max_value = 65535
	lobby_port.value = LAN_SESSION.PORT
	lobby_port.tooltip_text = "连接端口，两台电脑需保持一致"
	row.add_child(lobby_port)
	host_button = Button.new()
	host_button.text = "创建房间"
	host_button.pressed.connect(func(): lan.host("Kate" if lobby_role.selected == 0 else "Sarah",int(lobby_port.value)))
	var primary := StyleBoxFlat.new()
	primary.bg_color = Color("9ed8bd")
	primary.set_corner_radius_all(9)
	primary.content_margin_top = 13
	primary.content_margin_bottom = 13
	host_button.add_theme_stylebox_override("normal",primary)
	host_button.add_theme_color_override("font_color",Color("102b28"))
	stack.add_child(host_button)
	var divider := Label.new()
	divider.text = "──────  或加入朋友的房间  ──────"
	divider.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	divider.add_theme_font_size_override("font_size",14)
	divider.add_theme_color_override("font_color",Color("809b93"))
	stack.add_child(divider)
	lobby_address = LineEdit.new()
	lobby_address.placeholder_text = "主机 IP，例如 192.168.1.20"
	stack.add_child(lobby_address)
	join_button = Button.new()
	join_button.text = "加入房间  →"
	join_button.pressed.connect(func(): lan.join(lobby_address.text,int(lobby_port.value)))
	stack.add_child(join_button)
	var addresses: Array[String] = []
	for interface in IP.get_local_interfaces():
		var interface_name: String = interface.name
		if interface_name.begins_with("lo") or interface_name.begins_with("docker") or interface_name.begins_with("br-") or interface_name.begins_with("veth") or interface_name.begins_with("virbr") or interface_name.begins_with("tun") or interface_name.begins_with("tailscale"): continue
		for address: String in interface.addresses:
			if address.contains(".") and not address.begins_with("127."): addresses.append(address)
	if addresses.is_empty():
		for address in IP.get_local_addresses():
			if address.contains(".") and not address.begins_with("127."): addresses.append(address)
	var ip_label := Label.new()
	ip_label.text = "本机 IPv4："+(", ".join(addresses) if not addresses.is_empty() else "未检测到，可用 ip addr 查看")
	ip_label.add_theme_font_size_override("font_size",14)
	ip_label.add_theme_color_override("font_color",Color("809b93"))
	ip_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	stack.add_child(ip_label)
	lobby_message = Label.new()
	lobby_message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lobby_message.custom_minimum_size.y = 55
	stack.add_child(lobby_message)
	var actions := HBoxContainer.new()
	stack.add_child(actions)
	ready_button = Button.new()
	ready_button.text = "准备开始"
	ready_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ready_button.pressed.connect(func(): lan.ready_up())
	actions.add_child(ready_button)
	leave_button = Button.new()
	leave_button.text = "离开"
	leave_button.pressed.connect(func(): lan.leave())
	actions.add_child(leave_button)
	for button in [host_button,join_button,ready_button,leave_button]: button.focus_mode = Control.FOCUS_NONE

func refresh_lobby() -> void:
	lobby.visible = not lan.active
	if lan.active: get_viewport().gui_release_focus()
	lobby_message.text = lan.ready_message
	network_badge.text = "你是 %s · %s" % [lan.role,"主机" if lan.hosting else "客户端"] if lan.active else "局域网联机"
	ready_button.disabled = lan.role.is_empty() or lan.local_ready
	host_button.disabled = lan.hosting or lan.joining or not lan.role.is_empty()
	join_button.disabled = host_button.disabled
	lobby_role.disabled = host_button.disabled
	lobby_address.editable = not host_button.disabled
	lobby_port.editable = not host_button.disabled
	for i in range(game_buttons.size()):
		game_buttons[i].disabled = not lan.active or (not lan.hosting if i == game_buttons.size()-1 else lan.role != "Kate")

func start_cli_session(args: PackedStringArray) -> void:
	var address := ""
	var role := "Kate"
	var port := LAN_SESSION.PORT
	for arg in args:
		if arg.begins_with("--join="): address = arg.trim_prefix("--join=")
		if arg.begins_with("--role="): role = "Sarah" if arg.trim_prefix("--role=").to_lower() == "sarah" else "Kate"
		if arg.begins_with("--port="): port = int(arg.trim_prefix("--port="))
	if "--host" in args: lan.host(role,port)
	elif not address.is_empty(): lan.join(address,port)
	if "--auto-ready" in args:
		lan.changed.connect(func():
			if not lan.role.is_empty() and not lan.local_ready: lan.ready_up()
		)
		if not lan.role.is_empty() and not lan.local_ready: lan.ready_up()
