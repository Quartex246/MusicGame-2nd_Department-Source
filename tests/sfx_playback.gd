extends SceneTree

var passed := 0
var failed := 0


func _initialize() -> void:
	call_deferred("_run")


func _check(condition: bool, label: String) -> void:
	if condition:
		passed += 1
	else:
		failed += 1
		push_error(label)


func _run() -> void:
	var app := root.get_node("App")
	app.hit_sfx_style = "default"
	# 本机保存过自定义开头音效时也要跑内置音，否则下面「Path 头与 Tap 同源」的断言会被带偏。
	app.hit_sfx_custom_head = ""
	app.path_sfx_custom = ""
	var editor = load("res://charter/main.tscn").instantiate()
	root.add_child(editor)
	editor.set_process(false)
	var capture := AudioEffectCapture.new()
	capture.buffer_length = 0.5
	var bus := AudioServer.get_bus_index("SFX")
	AudioServer.add_bus_effect(bus, capture)
	await create_timer(0.3).timeout
	for kind in HitSfx.PATHS:
		for player in editor._sfx._players:
			player.stop()
		await create_timer(0.05).timeout
		capture.clear_buffer()
		editor._sfx.play(kind)
		await create_timer(0.25).timeout
		var peak := 0.0
		for frame in capture.get_buffer(capture.get_frames_available()):
			peak = maxf(peak, maxf(absf(frame.x), absf(frame.y)))
		_check(peak > 0.001, "%s produces audio on SFX bus" % kind)
	# Both imported and native charts must retain crossed events after a slow frame.
	var fixture := "user://sfx_maidata.txt"
	var file := FileAccess.open(fixture, FileAccess.WRITE)
	file.store_string("&title=SFX\n&wholebpm=120\n&inote_1=(120){4}1,2h[4:1],3-5[4:1],E\n")
	file.close()
	var imported := SimaiIO.import_maidata(fixture, 1)
	_check(imported != null, "simai sound fixture imports")
	var custom := DemoChart.make_empty({"bpm": 120.0})
	custom.notes.clear()
	for i in 3:
		var note := Note.new("tap", 0.25 * float(i + 1), 90.0, 60.0)
		note.id = i + 1
		custom.notes.append(note)
	for chart in [custom, imported]:
		if chart == null:
			continue
		for player in editor._sfx._players:
			player.stop()
		await create_timer(0.05).timeout
		capture.clear_buffer()
		app.set_chart(chart, "", false)
		editor._build_sfx_events()
		editor._sfx_last_beat = 0.0
		editor._sfx_event_index = 0
		var expected := 0
		for event in editor._sfx_events:
			if float(event["beat"]) <= 1.0:
				expected += 1
		var before: int = editor._sfx._index
		editor._fire_editor_sfx(1.0)
		_check(expected > 0 and editor._sfx._index - before == expected, "slow frame plays all crossed chart events")
		_check(await _await_peak(capture) > 0.001, "editor chart events reach SFX bus")
		before = editor._sfx._index
		editor._fire_editor_sfx(1.0)
		_check(editor._sfx._index == before, "same beat never duplicates sounds")
		# 滑条尾现在落在第 4 拍（头拍 + 1 拍等待 + 滑动），跳转点放在它之前。
		editor._rebase_playback(3.0)
		before = editor._sfx._index
		editor._fire_editor_sfx(3.0)
		_check(editor._sfx._index == before, "explicit seek skips earlier sounds")
	app.hit_sfx_style = "mute"
	for player in editor._sfx._players:
		player.stop()
	var playtest := Playtest.new()
	root.add_child(playtest)
	playtest.set_process(false)
	app.hit_sfx_style = "mute"
	app.appearance_changed.emit()
	_check(playtest._sfx.style == "mute", "playtest applies live mute setting")
	app.hit_sfx_style = "default"
	app.appearance_changed.emit()
	_check(playtest._sfx.style == "default", "playtest applies live unmute setting")
	for chart in [custom, imported]:
		if chart == null:
			continue
		playtest.setup(chart, 0.0, "")
		playtest._preview.time_beat = 0.0
		await process_frame
		var note: Note = chart.notes[0]
		var stamp: float = chart.timing.beat_to_chart_ms(note.beat)
		playtest._preview.prepare_playtest_frame(note.beat, 0.016)
		var point := playtest._preview.note_head_screen(note, note.beat)
		playtest._key_presses.append({"time": stamp, "mouse": point, "angle": note.angle, "key": KEY_A})
		playtest._assign_presses(stamp, note.beat)
		var before: int = playtest._sfx._index
		capture.clear_buffer()
		playtest._judge_tap(note, stamp, note.beat)
		_check(playtest._hit_count == 1, "playtest accepts chart hit")
		_check(playtest._sfx._index == before + 1, "playtest chart hit triggers sound")
		_check(await _await_peak(capture) > 0.001, "playtest chart hit reaches SFX bus")
	# Head contact and slide start are separate audible events during the wait.
	for width in [60.0, 75.0]:
		var chart := DemoChart.make_empty({"bpm": 120.0})
		chart.notes.clear()
		var note := Note.new("path", 2.0, 0.0, width)
		note.end_beat = 6.0
		note.wait_beat = 1.0
		note.tail_angle = 180.0
		note.generate_path_shape()
		chart.notes.append(note)
		playtest.setup(chart, 0.0, "")
		playtest._preview.prepare_playtest_frame(2.0, 0.016)
		var point := playtest._preview.note_head_screen(note, 2.0)
		playtest._press_assignments[note.id] = {"time": 1000.0, "mouse": point}
		var before: int = playtest._sfx._index
		capture.clear_buffer()
		playtest._judge_path(note, 1000.0, 2.0, point)
		_check(playtest._sfx._index == before + 1, "Path head hit triggers exactly one sound")
		var player: AudioStreamPlayer = playtest._sfx._players[before % playtest._sfx._players.size()]
		_check(player.stream == playtest._sfx._streams[HitSfx.kind_for_note(note)], "Path head uses same sound as matching Tap")
		_check(await _await_peak(capture) > 0.001, "Path head hit reaches SFX bus")
		playtest._judge_path(note, 1010.0, 2.02, point)
		_check(playtest._sfx._index == before + 1, "judged Path head never repeats its sound")
		playtest._judge_path(note, 1500.0, 3.0, point)
		_check(playtest._sfx._index == before + 2 and bool(playtest._states[note.id]["slide_cued"]), "waiting still ends with a separate slide cue")
		app.set_chart(chart, "", false)
		editor._build_sfx_events()
		_check(editor._sfx_events[0]["kind"] == HitSfx.kind_for_note(note), "editor Path head matches Tap sound too")
	# 自定义「音符开头」音效：只换 tap/hold/path 头用的采样，其它 kind 和音量基准不动。
	var fixture_wav := _write_test_wav("user://sfx_custom_head_test.wav")
	_check(not fixture_wav.is_empty(), "custom hit wav fixture written")
	app.set_hit_sfx_custom_head(fixture_wav)
	var stored: String = app.hit_sfx_custom_head
	_check(stored.begins_with("user://sfx/") and FileAccess.file_exists(ProjectSettings.globalize_path(stored)), "custom hit copied into user sfx dir")
	_check(editor._sfx.has_custom_head() and playtest._sfx.has_custom_head(), "editor and playtest pick up custom hit")
	for player in editor._sfx._players:
		player.stop()
	editor._sfx.play("don")
	var head_player: AudioStreamPlayer = _last_player(editor._sfx)
	_check(head_player.stream == editor._sfx._custom_head, "custom hit replaces the don sample")
	_check(is_equal_approx(head_player.volume_db, HitSfx.VOLUME_DB), "custom hit uses one volume base instead of per-kind db")
	editor._sfx.play("anchor")
	var anchor_player: AudioStreamPlayer = _last_player(editor._sfx)
	_check(anchor_player.stream == editor._sfx._streams["anchor"], "custom hit leaves anchor on the builtin sample")
	_check(editor._sfx.stream_path_for("path") == stored, "custom hit is used for path heads")
	_check(editor._sfx.stream_path_for("tail") == String(HitSfx.PATHS["tail"]), "custom hit leaves path tails on the builtin sample")
	editor._sfx.set_style("crisp")
	editor._sfx.play("path")
	var crisp_player: AudioStreamPlayer = _last_player(editor._sfx)
	_check(is_equal_approx(crisp_player.volume_db, HitSfx.VOLUME_DB + float(HitSfx.STYLE_DB["crisp"])), "custom hit keeps the style volume offset")
	_check(is_equal_approx(crisp_player.pitch_scale, float(HitSfx.STYLE_PITCH["crisp"])), "custom hit keeps the style pitch offset")
	editor._sfx.set_style("default")
	_check(await _await_peak(capture) > 0.001, "custom hit reaches SFX bus")
	app.appearance_changed.emit()
	app.set_hit_sfx_custom_head("")
	_check(app.hit_sfx_custom_head.is_empty(), "restoring default clears the stored path")
	_check(not editor._sfx.has_custom_head() and not playtest._sfx.has_custom_head(), "restoring default drops the custom hit everywhere")
	_check(not FileAccess.file_exists(ProjectSettings.globalize_path(stored)), "restoring default removes the copied file")
	# 自定义「Path 启动音」（slide）：独立于开头音效，只换星星起划提示音。
	var slide_wav := _write_test_wav("user://sfx_custom_slide_test.wav")
	_check(not slide_wav.is_empty(), "custom slide wav fixture written")
	app.set_path_sfx_custom(slide_wav)
	var slide_stored: String = app.path_sfx_custom
	_check(slide_stored.begins_with("user://sfx/path-"), "custom slide copied into its own file")
	_check(editor._sfx.has_custom_slide() and playtest._sfx.has_custom_slide(), "editor and playtest pick up custom slide")
	_check(editor._sfx.stream_path_for("slide") == slide_stored, "custom slide is used for the slide cue")
	_check(editor._sfx.stream_path_for("don") == String(HitSfx.PATHS["don"]), "custom slide leaves note heads on the builtin sample")
	for player in editor._sfx._players:
		player.stop()
	editor._sfx.play("slide")
	var slide_player: AudioStreamPlayer = _last_player(editor._sfx)
	_check(slide_player.stream == editor._sfx._custom_slide, "custom slide replaces the slide sample")
	_check(is_equal_approx(slide_player.volume_db, float(HitSfx.KIND_DB["slide"])), "custom slide keeps the prompt loudness")
	_check(await _await_peak(capture) > 0.001, "custom slide reaches SFX bus")
	app.set_path_sfx_custom("")
	_check(app.path_sfx_custom.is_empty(), "restoring default clears the slide path")
	_check(not editor._sfx.has_custom_slide() and not playtest._sfx.has_custom_slide(), "restoring default drops the custom slide everywhere")
	_check(not FileAccess.file_exists(ProjectSettings.globalize_path(slide_stored)), "restoring default removes the copied slide file")
	# 「截停」：连续命中时上一声立即停；同一帧的合键保留叠加。
	for player in editor._sfx._players:
		player.stop()
	editor._sfx.play("don")
	var first_hit: AudioStreamPlayer = _last_player(editor._sfx)
	await create_timer(0.02).timeout
	editor._sfx.play("don")
	var second_hit: AudioStreamPlayer = _last_player(editor._sfx)
	_check(first_hit != second_hit and not first_hit.playing, "next hit cuts the previous head sfx")
	for player in editor._sfx._players:
		player.stop()
	editor._sfx.play("don")
	var chord_a: AudioStreamPlayer = _last_player(editor._sfx)
	editor._sfx.play("kat")
	var chord_b: AudioStreamPlayer = _last_player(editor._sfx)
	_check(chord_a != chord_b and chord_a.playing, "same-frame chord keeps both head sfx")
	# 尾音不参与截停：path 尾再响一次，前一声不该被停。
	for player in editor._sfx._players:
		player.stop()
	editor._sfx.play("tail")
	var tail_a: AudioStreamPlayer = _last_player(editor._sfx)
	await create_timer(0.02).timeout
	editor._sfx.play("tail")
	_check(tail_a.playing, "path tails are not cut by the next tail")
	# 设置窗口的「音频」页要同时列出两行（入口曾经只加在 Inspector 里，用户找不到）。
	editor._open_settings()
	_check(editor._sfx_head_label != null and editor._sfx_slide_label != null, "settings audio page lists both sfx rows")
	_check(editor._sfx_slide_label.text == "内置（slide）", "slide row shows the builtin label by default")
	AudioServer.remove_bus_effect(bus, 0)
	playtest.free()
	editor.free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(fixture))
	print("SFX playback: %d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)

## 无头/Dummy 音频按缓冲周期出帧，固定等 0.2s 会抖；等到真的出帧为止。
func _await_peak(capture: AudioEffectCapture, timeout_sec := 1.0) -> float:
	var waited := 0.0
	while waited < timeout_sec:
		await create_timer(0.05).timeout
		waited += 0.05
		var peak := _capture_peak(capture)
		if peak > 0.001:
			return peak
	return 0.0


## 池是轮转的，_index 会一直涨；不能用 _index - 1 直接当下标。
func _last_player(sfx: HitSfx) -> AudioStreamPlayer:
	return sfx._players[(sfx._index - 1) % sfx._players.size()]


func _capture_peak(capture: AudioEffectCapture) -> float:
	var peak := 0.0
	for frame in capture.get_buffer(capture.get_frames_available()):
		peak = maxf(peak, maxf(absf(frame.x), absf(frame.y)))
	return peak


## 生成一个 44.1k / 16 位单声道 wav，当作「用户自己选的音效」。
func _write_test_wav(path: String) -> String:
	var rate := 44100
	var count := 2205
	var data := PackedByteArray()
	data.resize(count * 2)
	for i in count:
		data.encode_s16(i * 2, int(sin(TAU * 440.0 * float(i) / float(rate)) * 12000.0))
	var header := PackedByteArray()
	header.resize(44)
	header.encode_u32(0, 0x46464952)  # RIFF
	header.encode_u32(4, 36 + data.size())
	header.encode_u32(8, 0x45564157)  # WAVE
	header.encode_u32(12, 0x20746D66)  # "fmt "
	header.encode_u32(16, 16)
	header.encode_u16(20, 1)
	header.encode_u16(22, 1)
	header.encode_u32(24, rate)
	header.encode_u32(28, rate * 2)
	header.encode_u16(32, 2)
	header.encode_u16(34, 16)
	header.encode_u32(36, 0x61746164)  # data
	header.encode_u32(40, data.size())
	var file := FileAccess.open(ProjectSettings.globalize_path(path), FileAccess.WRITE)
	if file == null:
		return ""
	file.store_buffer(header)
	file.store_buffer(data)
	file.close()
	return path
