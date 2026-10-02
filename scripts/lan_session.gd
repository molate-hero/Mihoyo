extends Node
## Two-player LAN session. The host simulates the world; clients send inputs.
const INPUT_STEP := 1.0/30.0
const MAX_PENDING := 64
const PORT := 24567
const PROTOCOL := "shell-kernel-lan-v2"
var game: Node
var role := ""
var guest_id := 0
var rejected_builds := 0
var host_role := "Kate"
var active := false
var hosting := false
var joining := false
var local_ready := false
var guest_ready := false
var snapshot_clock := 0.0
var input_clock := 0.0
var sequence := 0
var last_sequence := -1
var local_move := Vector2.ZERO
var bot_input := false
var bot_move := Vector2.ZERO
var pending_inputs: Array[Dictionary] = []
var remote_inputs: Array[Dictionary] = []
var input_sequence := 0
var remote_ack := 0
var remote_queued := 0
var signature := ""
var ready_message := "选择创建房间，或输入主机局域网 IP 加入。"
signal changed

func _ready() -> void:
	game = get_parent()
	for path in ["res://scripts/demo.gd","res://scripts/lan_session.gd","res://assets/lands_navigation.json","res://assets/lands.glb","res://assets/characters/kate.glb","res://assets/characters/sarah.glb"]:
		signature += FileAccess.get_sha256(path)
	signature = signature.sha256_text()
	multiplayer.peer_disconnected.connect(_peer_left)
	multiplayer.connected_to_server.connect(_connected)
	multiplayer.connection_failed.connect(_connection_failed)
	multiplayer.server_disconnected.connect(_server_left)

func host(chosen_role: String, port: int = PORT) -> void:
	leave(false)
	var peer := ENetMultiplayerPeer.new()
	var error := peer.create_server(port,1)
	if error != OK:
		ready_message = "创建失败：端口 %d 可能已被占用（%s）。" % [port,error_string(error)]
		changed.emit()
		return
	multiplayer.multiplayer_peer = peer
	hosting = true
	host_role = chosen_role
	role = chosen_role
	ready_message = "房间已创建 · UDP %d · 你是 %s，等待另一位玩家。" % [port,role]
	changed.emit()

func join(address: String, port: int = PORT) -> void:
	if address.strip_edges().is_empty():
		ready_message = "请先输入主机的局域网 IP。"
		changed.emit()
		return
	leave(false)
	var peer := ENetMultiplayerPeer.new()
	peer.set_bind_ip("*")
	var error := peer.create_client(address.strip_edges(),port)
	if error != OK:
		ready_message = "加入失败：%s" % error_string(error)
		changed.emit()
		return
	multiplayer.multiplayer_peer = peer
	joining = true
	ready_message = "正在连接 %s:%d…" % [address.strip_edges(),port]
	changed.emit()
	var connect_peer := peer
	get_tree().create_timer(8.0).timeout.connect(func():
		if joining and multiplayer.multiplayer_peer == connect_peer:
			_connection_failed()
	)

func _connected() -> void:
	hello.rpc_id(1,PROTOCOL,signature)

@rpc("any_peer","call_remote","reliable")
func hello(protocol: String, build: String) -> void:
	if not hosting or guest_id != 0: return
	var sender := multiplayer.get_remote_sender_id()
	if protocol != PROTOCOL or build != signature:
		rejected_builds += 1
		rejected.rpc_id(sender,"双方游戏版本或模型不同，请使用同一份项目。")
		return
	guest_id = sender
	guest_ready = false
	assign_role.rpc_id(sender,"Sarah" if host_role == "Kate" else "Kate")
	ready_message = "两位玩家已连接 · 你是 %s，请双方点击准备。" % role
	changed.emit()

@rpc("authority","call_remote","reliable")
func rejected(reason: String) -> void:
	leave(false)
	ready_message = reason
	changed.emit()

@rpc("authority","call_remote","reliable")
func assign_role(assigned: String) -> void:
	joining = false
	role = assigned
	ready_message = "已加入房间 · 你是 %s，请双方点击准备。" % role
	changed.emit()

func ready_up() -> void:
	if role.is_empty() or local_ready: return
	local_ready = true
	ready_message = "已准备，等待另一位玩家。"
	if hosting:
		_try_start()
	else:
		client_ready.rpc_id(1)
	changed.emit()

@rpc("any_peer","call_remote","reliable")
func client_ready() -> void:
	if not hosting or multiplayer.get_remote_sender_id() != guest_id: return
	guest_ready = true
	_try_start()

func _try_start() -> void:
	if guest_id == 0 or not local_ready or not guest_ready: return
	game.abort_network_game()
	remote_inputs.clear()
	remote_ack = 0
	remote_queued = 0
	local_move = Vector2.ZERO
	active = true
	start_game.rpc_id(guest_id,game.make_snapshot())
	ready_message = "局域网联机中 · 你是 %s" % role
	changed.emit()

@rpc("authority","call_remote","reliable")
func start_game(state: Dictionary) -> void:
	pending_inputs.clear()
	input_sequence = 0
	input_clock = 0.0
	active = true
	last_sequence = -1
	game.receive_snapshot(state,true)
	ready_message = "局域网联机中 · 你是 %s" % role
	changed.emit()

func capture_input() -> void:
	if not active: return
	var raw := Vector2.ZERO
	if bot_input:
		raw = bot_move
	else:
		raw = Vector2(float(Input.is_physical_key_pressed(KEY_D))-float(Input.is_physical_key_pressed(KEY_A)),float(Input.is_physical_key_pressed(KEY_S))-float(Input.is_physical_key_pressed(KEY_W)))
		if role == "Kate":
			raw += Vector2(float(Input.is_physical_key_pressed(KEY_RIGHT))-float(Input.is_physical_key_pressed(KEY_LEFT)),float(Input.is_physical_key_pressed(KEY_DOWN))-float(Input.is_physical_key_pressed(KEY_UP)))
	local_move = game.camera_relative_move(raw.limit_length(),role)

func movement(for_role: String) -> Vector2:
	if role == for_role: return local_move
	# Guest movement is simulated once per numbered command, never per render frame.
	return Vector2.ZERO

func _process(delta: float) -> void:
	if not active: return
	if hosting:
		for command_data in remote_inputs:
			remote_ack = command_data.id
			if command_data.reset != game.reset_serial: continue
			var guest_role := "Sarah" if role == "Kate" else "Kate"
			if guest_role == "Sarah" and not game.inside and command_data.tile != game.current_tile: continue
			if guest_role == "Kate":
				game.kate_camera_yaw = command_data.yaw
				game.kate_camera_pitch = command_data.pitch
			else:
				game.camera_yaw = command_data.yaw
				game.camera_pitch = command_data.pitch
			game.simulate_network_player(guest_role,command_data.move,INPUT_STEP)
		remote_inputs.clear()
		snapshot_clock += delta
		if snapshot_clock >= 0.05:
			snapshot_clock = 0.0
			sequence += 1
			var state: Dictionary = game.make_snapshot()
			state["sequence"] = sequence
			state["input_ack"] = remote_ack
			var packet := var_to_bytes(state).compress(FileAccess.COMPRESSION_DEFLATE)
			if guest_id in multiplayer.get_peers() and multiplayer.multiplayer_peer.get_peer(guest_id).get_state() == ENetPacketPeer.STATE_CONNECTED:
				state_update.rpc_id(guest_id,packet)
	else:
		input_clock += minf(delta,0.25)
		var sent := false
		var resend := input_clock >= INPUT_STEP
		while input_clock >= INPUT_STEP:
			input_clock -= INPUT_STEP
			if pending_inputs.size() >= MAX_PENDING:
				input_clock = 0.0
				break
			input_sequence += 1
			var yaw: float = game.kate_camera_yaw if role == "Kate" else game.camera_yaw
			var pitch: float = game.kate_camera_pitch if role == "Kate" else game.camera_pitch
			var entry := {"id":input_sequence,"move":local_move,"tile":game.current_tile,
				"yaw":yaw,"pitch":pitch,"reset":game.remote_reset_serial}
			pending_inputs.append(entry)
			game.simulate_network_player(role,local_move,INPUT_STEP)
			sent = true
		if (sent or resend) and not pending_inputs.is_empty():
			# Repeat unacknowledged commands so a lost datagram cannot slow movement.
			input_update.rpc_id(1,var_to_bytes(pending_inputs).compress(FileAccess.COMPRESSION_DEFLATE))

func acknowledge_inputs(ack: int, resetting: bool) -> void:
	if resetting: pending_inputs.clear()
	else:
		while not pending_inputs.is_empty() and pending_inputs[0].id <= ack:
			pending_inputs.pop_front()

@rpc("any_peer","call_remote","unreliable_ordered",1)
func input_update(packet: PackedByteArray) -> void:
	if not hosting or not active or multiplayer.get_remote_sender_id() != guest_id: return
	var decoded: Variant = bytes_to_var(packet.decompress_dynamic(65536,FileAccess.COMPRESSION_DEFLATE))
	if not decoded is Array: return
	var entries: Array = decoded
	if entries.size() > MAX_PENDING: return
	for entry in entries:
		if not entry is Dictionary: return
		if not entry.has_all(["id","move","tile","yaw","pitch","reset"]): return
		if typeof(entry.id) != TYPE_INT or typeof(entry.tile) != TYPE_INT or typeof(entry.reset) != TYPE_INT: return
		if typeof(entry.move) != TYPE_VECTOR2 or not entry.move.is_finite(): return
		if typeof(entry.yaw) != TYPE_FLOAT or typeof(entry.pitch) != TYPE_FLOAT: return
		if not is_finite(entry.yaw) or not is_finite(entry.pitch): return
		if entry.id <= remote_queued: continue
		var accepted: Dictionary = entry.duplicate()
		accepted.move = entry.move.limit_length()
		accepted.pitch = clampf(entry.pitch,0.15,1.05)
		remote_inputs.append(accepted)
		remote_queued = entry.id

@rpc("authority","call_remote","unreliable_ordered",2)
func state_update(packet: PackedByteArray) -> void:
	if not active: return
	var data := packet.decompress_dynamic(65536,FileAccess.COMPRESSION_DEFLATE)
	var decoded: Variant = bytes_to_var(data)
	if not decoded is Dictionary: return
	var state: Dictionary = decoded
	var received: int = state.get("sequence",-1)
	if received <= last_sequence: return
	last_sequence = received
	game.receive_snapshot(state)

func command(action: String, values: Array = []) -> void:
	if not active: return
	if hosting:
		execute_command(role,action,values,true)
	else:
		client_command.rpc_id(1,action,values)

@rpc("any_peer","call_remote","reliable",0)
func client_command(action: String, values: Array) -> void:
	if not hosting or not active or multiplayer.get_remote_sender_id() != guest_id: return
	execute_command("Sarah" if host_role == "Kate" else "Kate",action,values,false)

func execute_command(sender_role: String, action: String, values: Array, is_host: bool) -> void:
	match action:
		"select", "turn":
			if sender_role != "Kate" or values.size() < 2: return
			if typeof(values[0]) != TYPE_INT or typeof(values[1]) != TYPE_INT: return
			if values[0] < 0 or values[0] > 2 or values[1] < -1 or values[1] > 1: return
			game.selected_axis = values[0]
			game.selected_layer = values[1]
			game.update_selector()
			if action == "turn" and values.size() == 3 and typeof(values[2]) == TYPE_INT and abs(values[2]) == 1:
				game.request_turn(values[2])
		"well":
			if sender_role == "Sarah": game.enter_well()
		"reset":
			if is_host:
				game.reset_demo()
				local_move = Vector2.ZERO

func leave(notify: bool = true) -> void:
	if multiplayer.multiplayer_peer is ENetMultiplayerPeer:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	active = false
	hosting = false
	joining = false
	role = ""
	guest_id = 0
	local_ready = false
	guest_ready = false
	local_move = Vector2.ZERO
	last_sequence = -1
	pending_inputs.clear()
	remote_inputs.clear()
	input_sequence = 0
	remote_ack = 0
	remote_queued = 0
	input_clock = 0.0
	if is_instance_valid(game): game.abort_network_game()
	ready_message = "已离开房间。可以重新创建或加入。"
	if notify: changed.emit()

func _peer_left(id: int) -> void:
	if not hosting or id != guest_id: return
	guest_id = 0
	guest_ready = false
	local_ready = false
	active = false
	game.abort_network_game()
	ready_message = "另一位玩家已断开，游戏已停止。等待重新加入并准备。"
	changed.emit()

func _server_left() -> void:
	leave(false)
	ready_message = "主机已断开，游戏已停止。请重新加入。"
	changed.emit()

func _connection_failed() -> void:
	leave(false)
	ready_message = "连接失败：检查 IP、同一局域网及防火墙 UDP 端口。"
	changed.emit()
