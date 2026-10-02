extends Node
## Real two-process regression test, only loaded with --lan-test.
var game: Node
var session: Node
var failures := 0
var finished := false

func _ready() -> void:
	game = get_parent()
	session = game.lan
	if "--lan-test-mismatch" in OS.get_cmdline_user_args() and not session.hosting:
		session.signature = "different-build"
	call_deferred("run")
	get_tree().create_timer(25.0).timeout.connect(func():
		if not finished:
			push_error("LAN TEST timed out")
			get_tree().quit(1)
	)

func expect(ok: bool, description: String) -> void:
	if ok: print("LAN PASS: ",description)
	else:
		failures += 1
		push_error("LAN FAIL: "+description)

func until(condition: Callable, timeout := 8.0) -> bool:
	var deadline := Time.get_ticks_msec()+int(timeout*1000)
	while not condition.call():
		if Time.get_ticks_msec() > deadline:
			expect(false,"timed out waiting for state")
			return false
		await get_tree().process_frame
	return true

func run() -> void:
	if "--lan-test-mismatch" in OS.get_cmdline_user_args():
		if session.hosting:
			await until(func(): return session.rejected_builds > 0)
			expect(not session.active and session.guest_id == 0,"host rejects mismatched build before game starts")
			await get_tree().create_timer(0.4).timeout
		else:
			await until(func(): return session.ready_message.contains("版本或模型不同"))
			expect(not session.active and session.role.is_empty(),"client sees version mismatch and returns to lobby")
		finish()
		return
	if "--lan-test-failure" in OS.get_cmdline_user_args():
		await until(func(): return session.ready_message.begins_with("连接失败"),12.0)
		expect(not session.active and game.lobby.visible and not game.host_button.disabled,"failed connection returns to usable lobby")
		finish()
		return
	if not await until(func(): return session.active): return
	session.bot_input = true
	game.mouse_role = session.role
	game.mouse_orbit = true
	var motion := InputEventMouseMotion.new()
	motion.relative = Vector2(100,40)
	game._input(motion)
	game.mouse_orbit = false
	game.mouse_role = ""
	expect(session.role in ["Kate","Sarah"],"role assigned and both players ready")
	expect(not game.lobby.visible,"lobby closes after both ready")
	if session.hosting: await run_host()
	else: await run_client()
	finish()

func finish() -> void:
	finished = true
	print("LAN RESULT: ","HOST" if "--host" in OS.get_cmdline_user_args() else "CLIENT"," ",failures," failures")
	get_tree().quit(1 if failures else 0)

func run_host() -> void:
	var start: Vector2 = game.start_uv
	var packet := var_to_bytes(game.make_snapshot()).compress(FileAccess.COMPRESSION_DEFLATE)
	expect(packet.size() < 1200,"compressed world snapshot fits one UDP packet")
	session.execute_command("Sarah","turn",[0,1,1],false)
	expect(not game.rotating,"Sarah cannot rotate the cube")
	session.execute_command("Kate","well",[],false)
	expect(not game.entering,"Kate cannot enter the well for Sarah")
	if session.role == "Kate":
		await get_tree().create_timer(0.25).timeout
		expect(game.turns == 0 and not game.rotating,"client's unauthorized turn RPC is rejected")
		session.bot_move = Vector2.RIGHT
		await get_tree().create_timer(0.3).timeout
		session.bot_move = Vector2.ZERO
		session.command("turn",[0,1,1])
	else:
		session.bot_move = Vector2.UP
		await get_tree().create_timer(0.7).timeout
		session.bot_move = Vector2.ZERO
	if not await until(func(): return game.turns == 1): return
	await get_tree().create_timer(0.5).timeout
	expect(absf(game.kate_camera_yaw+0.4) < 0.02 and absf(game.camera_yaw+0.4) < 0.02,"both players mouse-controlled views synchronize without auto-alignment")
	expect(game.kate.position.x > 0.3,"Kate moves with her own player's input")
	expect(game.uv.distance_to(start) > 0.06,"Sarah moves with her own player's input")
	var restored := true
	for block in game.blocks:
		restored = restored and block.transform.is_equal_approx(block.get_meta("initial"))
	expect(restored,"accepted turn restores exact block state")
	# Let the guest observe the completed turn even on the impaired link.
	await get_tree().create_timer(0.6).timeout
	# Place Sarah at the well to exercise the network transition, not the
	# already-covered six-face traversal. This fixture never runs in normal play.
	game.current_tile = game.well_tile
	game.uv = game.well_uv
	game.update_sarah()
	if session.role == "Sarah": session.command("well")
	if not await until(func(): return game.inside and not game.entering): return
	expect(game.sarah.get_parent() == game.room,"server transitions Sarah into kernel")
	game.kate.position = Vector3(2.5,0,2.1)
	if not await until(func(): return game.won): return
	await get_tree().create_timer(0.5).timeout
	session.command("reset")
	await get_tree().create_timer(0.5).timeout
	expect(not game.won and not game.inside and game.current_tile == game.start_tile,"host reset restores starting world")
	# Allow disconnect notification to be processed before the host exits.
	if session.role == "Kate":
		var click := InputEventMouseButton.new()
		click.button_index = MOUSE_BUTTON_LEFT
		click.position = game.exit_button.get_global_rect().get_center()
		click.global_position = click.position
		click.pressed = true
		click.button_mask = MOUSE_BUTTON_MASK_LEFT
		get_viewport().push_input(click,true)
		click = click.duplicate()
		click.pressed = false
		click.button_mask = 0
		get_viewport().push_input(click,true)
		expect(not session.active and not session.hosting and session.role.is_empty(),"actual exit button click leaves active room")
	else:
		game.multiplayer.multiplayer_peer.disconnect_peer(session.guest_id)
	await get_tree().create_timer(0.5).timeout
	expect(not session.active and game.lobby.visible,"guest disconnect stops host game and returns to lobby")
	session.leave()

func test_local_prediction() -> void:
	# Withhold all incoming snapshots while local input and rendering continue.
	get_tree().multiplayer_poll = false
	session.capture_input()
	var before: Vector2 = Vector2(game.kate.position.x,game.kate.position.z) if session.role == "Kate" else game.uv
	var first_id: int = session.input_sequence
	var started := Time.get_ticks_msec()
	await get_tree().create_timer(0.2).timeout
	var after: Vector2 = Vector2(game.kate.position.x,game.kate.position.z) if session.role == "Kate" else game.uv
	var ticks: int = session.input_sequence-first_id
	var speed: float = 2.0 if session.role == "Kate" else 1.5*game.SARAH_SCALE
	expect(ticks > 0 and absf(after.distance_to(before)-ticks*speed*session.INPUT_STEP) < 0.002,"guest moves at full speed without incoming snapshots")
	var elapsed := (Time.get_ticks_msec()-started)/1000.0
	expect(absf(ticks*session.INPUT_STEP-elapsed) < 0.075,"guest movement time remains independent of render frame rate")
	get_tree().multiplayer_poll = true

func run_client() -> void:
	if session.role == "Kate":
		session.bot_move = Vector2.RIGHT
		await test_local_prediction()
		await get_tree().create_timer(0.1).timeout
		session.bot_move = Vector2.ZERO
		session.command("turn",[0,1,1])
	else:
		session.command("turn",[0,1,1])
		session.bot_move = Vector2.UP
		await test_local_prediction()
		await get_tree().create_timer(0.5).timeout
		session.bot_move = Vector2.ZERO
	if not await until(func(): return game.turns == 1): return
	await get_tree().create_timer(0.3).timeout
	expect(absf(game.kate_camera_yaw+0.4) < 0.02 and absf(game.camera_yaw+0.4) < 0.02,"both players mouse-controlled views synchronize without auto-alignment")
	expect(game.kate.position.x > 0.3,"client receives Kate position")
	expect(game.uv.distance_to(game.start_uv) > 0.06,"client receives Sarah position")
	var restored := true
	for block in game.blocks:
		restored = restored and block.transform.is_equal_approx(block.get_meta("initial"))
	expect(restored,"client receives exact finished turn state")
	if not await until(func(): return game.current_tile == game.well_tile): return
	if session.role == "Sarah": session.command("well")
	if not await until(func(): return game.inside): return
	expect(game.sarah.get_parent() == game.room,"client transitions Sarah into kernel")
	if not await until(func(): return game.won): return
	expect(game.won,"client receives shared win state")
	if not await until(func(): return not game.won and not game.inside): return
	expect(game.current_tile == game.start_tile,"client receives host reset")
	if not await until(func(): return not session.active): return
	expect(game.lobby.visible,"host disconnect returns client to lobby")
