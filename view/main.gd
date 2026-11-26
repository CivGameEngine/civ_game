extends Node3D
## Точка входа: создаёт партию и связывает ядро с отображением и вводом.
## Ядро (core/) меняется только через Game.apply_action().

## Параметры новой партии. Стартовое меню задаёт их до входа в сцену.
@export var map_size := "SMALL"
@export var map_type := "CONTINENTS"
@export var game_speed := "STANDARD"
@export var fixed_seed := 0   # 0 — случайное зерно
var initial_game: Game

var game: Game
var map_view: MapView
var units_view: UnitsView
var cities_view: CitiesView
var districts_view: DistrictsView
var overlay: OverlayView
var camera_rig: CameraRig
var hud: Hud

var selected: Unit = null
var selected_city: City = null
var hover_tile := -1
## Режим размещения района: тип района ("" — режим выключен).
var placing_district := ""
var _hover_path_target := -2
## Какие части геометрии карты пересобрать при следующем обновлении.
var _geometry_dirty := {}
var _result_presented := false
var _menu_confirmation: ConfirmationDialog

## Событие -> части геометрии, которые оно меняет.
const GEOMETRY_EVENTS := {
	"city_founded": ["terrain", "improvements", "borders"],
	"border_grew": ["borders"],
	"improvement_built": ["improvements"],
	"harvested": ["terrain", "improvements"],
	"road_built": ["roads"],
	"pillaged": ["improvements"],
	"camp_spawned": ["improvements"],
	"camp_cleared": ["improvements"],
	"village_reward": ["improvements"],
	"city_captured": ["borders"],
	"city_conceded": ["borders"],
	"city_destroyed": ["borders", "improvements"],
	"district_placed": ["terrain", "improvements"],
}


func _ready() -> void:
	_setup_environment()
	map_view = MapView.new()
	map_view.name = "Map"
	add_child(map_view)
	var pieces := Node3D.new()
	pieces.name = "MapPieces"
	pieces.scale = Vector3.ONE * MapStyle.WORLD_HEX_RADIUS
	add_child(pieces)
	overlay = OverlayView.new()
	overlay.name = "Overlay"
	pieces.add_child(overlay)
	cities_view = CitiesView.new()
	cities_view.name = "Cities"
	pieces.add_child(cities_view)
	districts_view = DistrictsView.new()
	districts_view.name = "Districts"
	pieces.add_child(districts_view)
	units_view = UnitsView.new()
	units_view.name = "Units"
	pieces.add_child(units_view)
	camera_rig = CameraRig.new()
	camera_rig.name = "CameraRig"
	add_child(camera_rig)
	hud = Hud.new()
	add_child(hud)
	hud.act = act
	hud.minimap_pressed.connect(func(tile: int): camera_rig.focus(map_view.tile_world(tile, camera_rig.position.x)))
	hud.minimap_zoom.connect(func(direction: int):
		camera_rig.target_distance = clampf(camera_rig.target_distance * (0.85 if direction > 0 else 1.18),
			camera_rig.min_distance, camera_rig.max_distance))
	hud.end_turn_pressed.connect(_end_turn)
	hud.new_map_pressed.connect(_new_game)
	hud.save_pressed.connect(save_game)
	hud.load_pressed.connect(load_game)
	hud.menu_pressed.connect(_confirm_main_menu)
	hud.reveal_toggled.connect(_set_reveal)
	hud.city_closed.connect(func(): _select_city(null))
	hud.place_district.connect(_start_placement)
	hud.place_wonder.connect(func(id: String): _start_placement("WONDER:" + id))
	if initial_game != null:
		_attach_game(initial_game)
		initial_game = null
		hud.show_message("Игра загружена: ход %d" % game.state.turn)
	else:
		_new_game()


func _setup_environment() -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color("1a1d24")
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color("c9d4e8")
	e.ambient_light_energy = 0.38
	env.environment = e
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.light_color = Color("fff1d6")
	sun.light_energy = 0.7
	sun.rotation_degrees = Vector3(-55, -35, 0)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 60.0
	add_child(sun)


func _new_game() -> void:
	var seed_value := fixed_seed if fixed_seed != 0 else randi() % 1000000 + 1
	var t0 := Time.get_ticks_msec()
	var g := Game.new_game(GameData.get_default(), {
		"map_size": map_size, "map_type": map_type, "speed": game_speed, "seed": seed_value, "humans": [0],
	})
	print("Карта создана за %d мс, зерно %d" % [Time.get_ticks_msec() - t0, seed_value])
	_attach_game(g)
	hud.show_message("Зерно карты: %d" % seed_value)


func save_game() -> void:
	var err := SaveLoad.save(game)
	hud.show_message("Игра сохранена (F9 — загрузить)" if err == "" else err)


func load_game() -> void:
	var g := SaveLoad.load_game(GameData.get_default())
	if g == null:
		hud.show_message("Сохранения нет (F6 — сохранить)")
		return
	_attach_game(g)
	hud.show_message("Игра загружена: ход %d" % g.state.turn)


func _confirm_main_menu() -> void:
	if _menu_confirmation == null:
		_menu_confirmation = ConfirmationDialog.new()
		_menu_confirmation.title = "Главное меню"
		_menu_confirmation.dialog_text = "Вернуться в главное меню? Несохранённые изменения партии будут потеряны."
		_menu_confirmation.ok_button_text = "В меню"
		_menu_confirmation.cancel_button_text = "Остаться"
		_menu_confirmation.confirmed.connect(_return_to_main_menu)
		add_child(_menu_confirmation)
	_menu_confirmation.popup_centered()


func _return_to_main_menu() -> void:
	if get_tree().change_scene_to_file("res://view/start_menu.tscn") != OK:
		hud.show_message("Не удалось открыть главное меню")


## Подключает партию к отображению (новую или загруженную).
func _attach_game(g: Game) -> void:
	game = g
	_result_presented = false
	game.events_emitted.connect(_on_events)
	hud.game = game
	map_view.build(game)
	var map := game.state.map
	camera_rig.setup(map_view.world_width, map_view.tile_world(map.size() - 1).z)
	units_view.setup(game, map_view)
	cities_view.setup(game, map_view)
	districts_view.setup(game, map_view)
	overlay.setup(map_view)
	placing_district = ""
	selected = null
	selected_city = null
	hud.open_city(-1)
	hud.close_research()
	_geometry_dirty = {}
	_refresh_all()
	var focus_tile := 0 if game.state.start_positions.is_empty() else game.state.start_positions[0]
	var caps := game.state.cities_of(game.state.current_player)
	if not caps.is_empty():
		focus_tile = caps[0].tile
	camera_rig.focus(map_view.tile_world(focus_tile))
	_select_next_unit()


func _viewer() -> Player:
	return game.state.player(game.state.current_player)


## Применить действие от имени игрока и обновить экран.
func act(action: Dictionary) -> Array:
	var events := game.apply_action(action)
	_after_action()
	var t: String = action.get("type", "")
	if t in ["found_city", "found_religion", "spread_religion", "proclaim_belief", "start_inquisition", "purge_religion", "theological_attack", "build_improvement", "harvest", "skip_unit", "sleep_unit", "fortify", "build_road", "attack", "promote", "upgrade_unit", "build_fort", "pillage", "attach_commander"] and \
			(selected == null or game.state.unit(selected.id) == null or selected.moves_left <= 0.0 or not selected.orders.is_empty()):
		_select_next_unit()
	if t == "found_city":
		for e in events:
			if e["type"] == "city_founded":
				_select_city(game.state.city(e["city"]))
	return events


func _refresh_all() -> void:
	if not _geometry_dirty.is_empty():
		map_view.refresh_geometry(_geometry_dirty)
		_geometry_dirty = {}
	var viewer := _viewer()
	map_view.refresh_fog(viewer)
	map_view.refresh_resources(viewer)
	units_view.selected_id = selected.id if selected != null else -1
	units_view.refresh(viewer, camera_rig.position.x)
	cities_view.refresh(viewer, camera_rig.position.x)
	districts_view.refresh(viewer, camera_rig.position.x)
	hud.refresh_top()
	hud.refresh_research()
	hud.show_unit(selected)
	if selected_city != null and game.state.city(selected_city.id) != null:
		hud.refresh_city()
		if placing_district == "":
			overlay.show_city(game, selected_city, camera_rig.position.x)
	if not game.state.result.is_empty():
		hud.set_end_turn_text("Итоги партии (Enter)", false)
		if not _result_presented:
			hud.open_victory()
			_result_presented = true
		return
	var blocking := EmpireRules.blocking_decisions(game, viewer.id)
	if blocking.is_empty():
		hud.set_end_turn_text("Конец хода (Enter)", false)
	else:
		hud.set_end_turn_text(blocking[0]["text"], true)


func _on_events(events: Array) -> void:
	for e in events:
		var t: String = e["type"]
		if GEOMETRY_EVENTS.has(t):
			for part in GEOMETRY_EVENTS[t]:
				_geometry_dirty[part] = true
		if t == "error":
			hud.show_message(e["message"])
		elif t == "trade_completed" and e["player"] == _viewer().id:
			hud.show_message("Торговый путь завершён. Торговец вернулся.")
		elif t == "trade_cancelled" and e["player"] == _viewer().id:
			hud.show_message("Торговый путь прерван")
		elif t == "trade_raided":
			if e["by"] == _viewer().id:
				hud.show_message("Торговый путь разграблен · +%d золота" % int(e["gold"]))
			elif e["player"] == _viewer().id:
				hud.show_message("Ваш торговый путь разграблен")
		elif t == "unit_blocked" and game.state.unit(e["unit"]) != null \
				and game.state.unit(e["unit"]).owner == game.state.current_player:
			hud.show_message("Путь перекрыт")
		elif t == "tech_researched" and e["player"] == game.state.current_player:
			hud.show_message("Изучено: %s" % EmpireRules.tech_display(game, e["player"], e["tech"])["name"], 3.0)
		elif t == "civic_completed" and e["player"] == game.state.current_player:
			hud.show_message("Принят институт: %s" % game.data.civics[e["civic"]]["name"], 3.0)
		elif t == "religion_founded":
			hud.show_message("Основана религия: %s" % game.state.religions[e["religion"]]["name"], 3.0)
		elif t == "pantheon_founded" and e["player"] == game.state.current_player:
			hud.show_message("Основан пантеон: %s" % ReligionRules.belief(game, "pantheons", e["pantheon"])["name"], 3.0)
		elif t == "religion_enhanced":
			hud.show_message("Провозглашено верование: %s" % ReligionRules.belief(game, str(e["kind"]) + "_beliefs", e["belief"])["name"], 3.0)
		elif t == "religion_spread" and e["player"] == game.state.current_player:
			hud.show_message("Вера распространена в городе %s" % game.state.city(e["city"]).name, 3.0)
		elif t == "science_project_completed" and e["player"] == game.state.current_player:
			hud.show_message("Космический проект завершён: %s" % game.data.science_projects[e["project"]]["name"], 4.0)
		elif t == "great_work_created" and e["player"] == game.state.current_player:
			hud.show_message("В городе создан шедевр", 4.0)
		elif t == "great_work_moved" and e["player"] == game.state.current_player:
			hud.show_message("Шедевр перевезён в город %s" % game.state.city(int(e["to_city"])).name, 3.0)
		elif t == "national_park_founded" and e["player"] == game.state.current_player:
			hud.show_message("Основан национальный парк: +%.0f туризма" % float(e["tourism"]), 4.0)
		elif t == "rock_concert" and e["player"] == game.state.current_player:
			hud.show_message("Концерт: +%.0f туризма против %s%s" % [float(e["tourism"]),
				game.state.player(int(e["host"])).name, " · группа распалась" if e["dissolved"] else ""], 4.0)
		elif t == "world_exchange_opened":
			hud.show_message("Открыта Мировая биржа: началась гонка за финансовую победу", 5.0)
		elif t == "finance_hegemony":
			hud.show_message("%s: финансовая гегемония, осталось %d ходов" % [
				game.state.player(int(e["player"])).name, int(e["remaining"])], 5.0)
		elif t == "finance_hegemony_broken":
			hud.show_message("Гегемония державы %s прервана" % game.state.player(int(e["player"])).name, 4.0)
		elif t == "inquisition_started" and e["player"] == game.state.current_player:
			hud.show_message("Инквизиция учреждена", 3.0)
		elif t == "religion_purged" and e["player"] == game.state.current_player:
			hud.show_message("Город очищен от чужой веры", 3.0)
		elif t == "theological_combat":
			hud.show_message("Теологический бой", 2.5)
		elif t == "religious_incident" and e["victim"] == game.state.current_player:
			hud.show_message("Чужая активная проповедь: можно заявить протест в разделе «Религия»", 4.0)
		elif t == "religious_promise_breached" and e["victim"] == game.state.current_player:
			hud.show_message("Нарушено обещание прекратить проповедь", 4.0)
		elif t == "religious_promise_breached" and e["offender"] == game.state.current_player:
			hud.show_message("Вы нарушили обещание прекратить проповедь", 4.0)
		elif t == "religious_evidence_recorded" and e["victim"] == game.state.current_player:
			hud.show_message("Есть основание для обращения в ООН: откройте раздел «Религия»", 4.0)
		elif t == "village_reward" and e["player"] == game.state.current_player:
			hud.show_message("Племенное поселение: %s" % e["text"], 3.0)
		elif t == "camp_cleared" and e["player"] == game.state.current_player:
			hud.show_message("Лагерь варваров уничтожен: +%d золота" % int(e["gold"]), 3.0)
		elif t == "city_captured":
			hud.show_message("Город %s захвачен: %s" % [game.state.city(e["city"]).name, game.state.player(e["by"]).name], 3.5)
		elif t == "city_destroyed":
			hud.show_message("Город разорён варварами", 3.5)
		elif t == "war_declared":
			hud.show_message("%s объявляет войну: %s" % [game.state.player(e["player"]).name, game.state.player(e["target"]).name], 3.5)
		elif t == "peace_made":
			hud.show_message("Заключён мир", 3.0)
		elif t == "treaty_accepted" and _viewer().id in [int(e["from"]), int(e["to"])]:
			hud.show_message("Дипломатический договор принят")
		elif t == "alliance_leveled" and _viewer().id in [int(e["from"]), int(e["to"])]:
			hud.show_message("Союз достиг уровня %d" % int(e["level"]), 4.0)
		elif t == "demand_accepted" and _viewer().id in [int(e["issuer"]), int(e["recipient"])]:
			hud.show_message("Дипломатическое требование принято")
		elif t == "demand_refused" and _viewer().id in [int(e["issuer"]), int(e["recipient"])]:
			hud.show_message("Дипломатическое требование отклонено")
		elif t == "congress_result":
			hud.show_message("ООН · голосование №%d %s" % [int(e["id"]), "принято" if e["passed"] else "отклонено"])
		elif t == "congress_violation" and e["accused"] == game.state.current_player:
			hud.show_message("Нарушение решения ООН · потеря мирового влияния и эмбарго", 4.0)
		elif t == "supply_closed" and e["reason"] == "luxury_access_lost" \
				and _viewer().id in [int(e["buyer"]), int(e["seller"])]:
			hud.show_message("Доступ к редкому ресурсу прекращён · возврат покупателю %s золота" % Hud._fmt(float(e["refund"])))
		elif t == "unit_withdrawing" and _viewer().id == int(e["player"]):
			hud.show_message("Юниту нужно покинуть закрытую территорию")
		elif t == "unit_relocated" and _viewer().id == int(e["player"]):
			hud.show_message("Юнит выведен за закрытые границы")
		elif t == "barbarian_raid":
			var c := game.state.city(e["target"])
			if c != null and c.owner == game.state.current_player:
				hud.show_message("Варвары готовят набег на %s!" % c.name, 4.0)
		elif t == "combat" and (e.has("attacker") or e.has("city_attacker")):
			var me := game.state.current_player
			var au := game.state.unit(e.get("attacker", -1))
			if au != null and au.owner == me:
				hud.show_message("Урон врагу: %d · ваши потери: %d" % [int(e["dmg_to_def"]), int(e.get("dmg_to_att", 0))], 2.5)
		elif t == "unit_killed" and e["owner"] == game.state.current_player and e.get("reason", "") != "spent":
			hud.show_message("Юнит погиб", 2.5)
		elif t == "player_eliminated":
			hud.show_message("%s выбывает из игры" % game.state.player(e["player"]).name, 4.0)


func _process(_delta: float) -> void:
	if game == null:
		return
	# Фигурки и наложения следуют за камерой через шов цилиндра.
	units_view.refresh(_viewer(), camera_rig.position.x)
	cities_view.refresh(_viewer(), camera_rig.position.x)
	districts_view.refresh(_viewer(), camera_rig.position.x)
	_update_hover()


func _update_hover() -> void:
	var mouse := get_viewport().get_mouse_position()
	var cam := camera_rig.camera
	var tile := map_view.pick_tile(cam.project_ray_origin(mouse), cam.project_ray_normal(mouse))
	if get_viewport().gui_get_hovered_control() != null:
		tile = -1
	if tile != hover_tile:
		hover_tile = tile
		hud.show_tile(_viewer(), tile, map_view.reveal_all)
		if placing_district != "" and selected_city != null:
			if placing_district.begins_with("WONDER:"):
				hud.show_wonder_preview(selected_city, placing_district.substr(7), tile)
			else:
				hud.show_district_preview(selected_city, placing_district, tile)
		if selected != null and tile >= 0 and game.state.unit(selected.id) != null and Combat.can_attack(game, selected):
			var tgt := Combat.target_at(game, selected.owner, tile)
			if tgt["kind"] == "unit" or tgt["kind"] == "city":
				hud.show_combat_preview(Combat.preview(game, selected, tile), Combat.attack_error(game, selected, tile))
	overlay.show_hover(tile, camera_rig.position.x)
	var path_target := tile if selected != null else -1
	if path_target != _hover_path_target:
		_hover_path_target = path_target
		if path_target >= 0 and selected != null and game.state.unit(selected.id) != null and path_target != selected.tile:
			overlay.show_path(Pathfinder.find_path(game, selected, path_target), camera_rig.position.x)
		else:
			overlay.clear_path()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_click_tile(hover_tile)
		elif mb.button_index == MOUSE_BUTTON_RIGHT and placing_district != "":
			_stop_placement()
		elif mb.button_index == MOUSE_BUTTON_RIGHT and selected != null and hover_tile >= 0:
			_move_selected(hover_tile)
	elif event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_ENTER, KEY_KP_ENTER:
				_end_turn()
			KEY_SPACE:
				if selected != null:
					act({"type": "skip_unit", "unit": selected.id})
			KEY_F:
				if selected != null:
					var kind := "fortify" if Movement.layer(game, selected.type) == "COMBAT" else "sleep_unit"
					act({"type": kind, "unit": selected.id})
			KEY_B:
				if selected != null:
					act({"type": "found_city", "unit": selected.id})
			KEY_R:
				if selected != null:
					act({"type": "build_road", "unit": selected.id})
			KEY_E:
				if selected != null and not Army.slots_for(game, selected.type).is_empty():
					hud.open_equipment(selected.id)
			KEY_TAB:
				_select_next_unit(true)
			KEY_F2:
				_set_reveal(not map_view.reveal_all)
				hud.set_reveal(map_view.reveal_all)
			KEY_F5:
				_new_game()
			KEY_F6:
				save_game()
			KEY_F9:
				load_game()
			KEY_ESCAPE:
				if placing_district != "":
					_stop_placement()
					return
				_select(null)
				_select_city(null)
				hud.close_research()


func _click_tile(tile: int) -> void:
	if tile < 0:
		return
	if placing_district != "" and selected_city != null:
		var wonder_mode := placing_district.begins_with("WONDER:")
		var err := WonderRules.placement_error(game, selected_city, placing_district.substr(7), tile) if wonder_mode \
			else DistrictRules.placement_error(game, selected_city, placing_district, tile)
		if err != "":
			hud.show_message(err)
			return
		var type := placing_district
		_stop_placement()
		act({"type": "set_production", "city": selected_city.id, "kind": "wonder" if wonder_mode else "district",
			"id": type.substr(7) if wonder_mode else type, "tile": tile})
		return
	# В режиме города щелчок по ничьей клетке рядом — покупка.
	if selected_city != null and game.state.map.owner_city[tile] < 0 \
			and game.state.map.grid.distance(selected_city.tile, tile) <= 3:
		act({"type": "buy_tile", "city": selected_city.id, "tile": tile})
		return
	var city := game.state.city_at(tile)
	var mine: Array[Unit] = []
	for u in game.state.units_at(tile):
		if u.owner == game.state.current_player:
			mine.append(u)
	# Щелчок по городу открывает его (повторный щелчок — юниты в городе).
	if city != null and _viewer().is_revealed(tile) and (selected_city != city or mine.is_empty()):
		_select(null)
		_select_city(city)
		return
	_select_city(null)
	if mine.is_empty():
		_select(null)
		return
	var idx := mine.find(selected)
	_select(mine[(idx + 1) % mine.size()])


func _start_placement(type: String) -> void:
	if selected_city == null:
		return
	placing_district = type
	overlay.clear_city()
	overlay.show_placement(game, selected_city, type, camera_rig.position.x)
	var label := str(game.data.wonders[type.substr(7)]["name"]) if type.begins_with("WONDER:") \
		else DistrictRules.display_name(game, selected_city.owner, type)
	hud.show_message("Выберите клетку для «%s» (ПКМ или Esc — отмена)" % label, 4.0)


func _stop_placement() -> void:
	placing_district = ""
	overlay.clear_placement()
	if selected_city != null:
		overlay.show_city(game, selected_city, camera_rig.position.x)


func _select(u: Unit) -> void:
	selected = u
	_hover_path_target = -2
	units_view.selected_id = u.id if u != null else -1
	hud.show_unit(u)


func _select_city(c: City) -> void:
	if placing_district != "":
		_stop_placement()
	selected_city = c
	hud.open_city(c.id if c != null else -1)
	if c == null:
		overlay.clear_city()
	else:
		overlay.show_city(game, c, camera_rig.position.x)


func _select_next_unit(cycle: bool = false) -> void:
	var waiting := game.units_needing_orders(game.state.current_player)
	if waiting.is_empty():
		_select(null)
		return
	var idx := waiting.find(selected) if cycle else -1
	var u: Unit = waiting[(idx + 1) % waiting.size()]
	_select(u)
	camera_rig.focus(map_view.tile_world(u.tile, camera_rig.position.x))


func _move_selected(tile: int) -> void:
	if game.state.unit(selected.id) == null:
		_select(null)
		return
	var tgt := Combat.target_at(game, selected.owner, tile)
	if tgt["kind"] != "" and tgt["kind"] != "camp" and Combat.can_attack(game, selected):
		var err := Combat.attack_error(game, selected, tile)
		if err == "":
			act({"type": "attack", "unit": selected.id, "target": tile})
		else:
			hud.show_message(err)
		return
	act({"type": "move_unit", "unit": selected.id, "target": tile})
	if selected != null and selected.moves_left <= 0.0:
		_select_next_unit()


## Конец хода; если остались обязательные решения — показать первое из них.
func _end_turn() -> void:
	if not game.state.result.is_empty():
		hud.open_victory()
		return
	var blocking := EmpireRules.blocking_decisions(game, game.state.current_player)
	if not blocking.is_empty():
		var b: Dictionary = blocking[0]
		hud.show_message(b["text"])
		match b["type"]:
			"choose_pantheon":
				hud.open_religion()
			"choose_tech":
				hud.open_research("tech")
			"choose_civic":
				hud.open_research("civic")
			"city_production":
				var c := game.state.city(b["city"])
				_select(null)
				_select_city(c)
				camera_rig.focus(map_view.tile_world(c.tile, camera_rig.position.x))
			"unit_orders":
				var u := game.state.unit(b["unit"])
				_select_city(null)
				_select(u)
				camera_rig.focus(map_view.tile_world(u.tile, camera_rig.position.x))
		return
	game.apply_action({"type": "end_turn"})
	_select(null)
	_after_action()
	if not game.state.result.is_empty():
		return
	_select_next_unit()
	hud.show_message("Ход %d" % game.state.turn, 1.5)


func _after_action() -> void:
	_hover_path_target = -2
	if selected != null and game.state.unit(selected.id) == null:
		selected = null
	if selected_city != null and game.state.city(selected_city.id) == null:
		_select_city(null)
	_refresh_all()


func _set_reveal(on: bool) -> void:
	map_view.set_reveal_all(on)
	hud.set_reveal(on)
	map_view.refresh_resources(_viewer())
	hud.show_tile(_viewer(), hover_tile, on)
