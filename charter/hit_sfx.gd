class_name HitSfx
extends Node

## Shared hit-sound pool for editor playback and playtest.

const VOLUME_DB := -3.0
const KIND_DB := {"don": -3.0, "kat": -3.5, "hold_end": -4.0, "path": -3.5, "anchor": -2.0, "bell": -4.0, "tail": -3.5, "slide": 0.0}
const STYLE_PITCH := {"default": 1.0, "crisp": 1.18, "deep": 0.84}
const STYLE_DB := {"default": 0.0, "crisp": -1.0, "deep": 1.5}
const PATHS := {
	"don": "res://audio/sfx/tap_don.ogg",
	"hold_end": "res://audio/sfx/hold_end.ogg",
	"path": "res://audio/sfx/path.wav",
	"anchor": "res://audio/sfx/anchor.wav",
	"kat": "res://audio/sfx/tap_kat.wav",
	"bell": "res://audio/sfx/bell.ogg",
	"tail": "res://audio/sfx/path_tail.wav",
	# 星星可以开始划的提示音（比 path 头音更高更亮）。
	"slide": "res://audio/sfx/slide.wav",
}
## 自定义「音符开头」音效（用户口中的 hit）覆盖的 kind：tap（don/kat）、hold 头、path 头。
## 尾音、锚点、滑键提示音、铃音不在其中。
const HEAD_KINDS := ["don", "kat", "path"]

var _streams: Dictionary = {}
var _players: Array[AudioStreamPlayer] = []
var _index: int = 0
var style: String = "default"
## 自定义开头音效（user:// 路径）。空 = 用内置 don/kat/path；加载失败也退回内置。
var custom_head_path: String = ""
var _custom_head: AudioStream = null
var _custom_head_key: String = ""
## 同一路径重新选了内容不同的文件时，靠修改时间判断要不要重新加载。
var _custom_head_mtime: int = 0


func _ready() -> void:
	if AudioServer.get_bus_index("SFX") < 0:
		AudioServer.add_bus()
		var index := AudioServer.bus_count - 1
		AudioServer.set_bus_name(index, "SFX")
		AudioServer.set_bus_send(index, "Master")
	for key in PATHS:
		var stream: AudioStream = load(String(PATHS[key]))
		if stream != null:
			_streams[key] = stream
	for i in 10:
		var player := AudioStreamPlayer.new()
		player.bus = "SFX"
		player.volume_db = VOLUME_DB
		add_child(player)
		_players.append(player)


func set_style(value: String) -> void:
	style = value


## 指定自定义开头音效；传空字符串恢复内置音。文件丢失或格式不支持时静默退回内置，
## 但路径会保留，用户换回该文件后无需重新选择。
func set_custom_head(path: String) -> void:
	path = path.strip_edges()
	custom_head_path = path
	if path.is_empty():
		_custom_head_key = ""
		_custom_head_mtime = 0
		_custom_head = null
		return
	var mtime := FileAccess.get_modified_time(path)
	if path == _custom_head_key and mtime == _custom_head_mtime:
		return
	_custom_head_key = path
	_custom_head_mtime = mtime
	_custom_head = null
	var stream := ChartIO.audio_stream_from_path(path)
	if stream == null:
		push_warning("HitSfx: 无法加载自定义开头音效 %s，回退到内置音。" % path)
		return
	_custom_head = stream


func has_custom_head() -> bool:
	return _custom_head != null


## 某个 kind 实际使用的采样来源（导出混音用它解码）。
func stream_path_for(kind: String) -> String:
	if kind in HEAD_KINDS and not custom_head_path.is_empty():
		return custom_head_path
	return String(PATHS.get(kind, ""))


func play(kind: String, pitch: float = 1.0) -> void:
	if style == "mute":
		return
	var custom := kind in HEAD_KINDS and _custom_head != null
	var stream: AudioStream = _custom_head if custom else _streams.get(kind)
	if stream == null or _players.is_empty():
		return
	var player := _players[_index % _players.size()]
	_index += 1
	player.stream = stream
	# 自定义音效统一用一个音量基准，避免 don/kat/path 三档不同音量把同一采样拆成三种响度。
	var base_db: float = VOLUME_DB if custom else float(KIND_DB.get(kind, VOLUME_DB))
	player.volume_db = base_db + float(STYLE_DB.get(style, 0.0))
	player.pitch_scale = pitch * float(STYLE_PITCH.get(style, 1.0))
	player.play()


static func kind_for_note(note: Note) -> String:
	return "kat" if note.width >= 70.0 and note.width < 85.0 else "don"
