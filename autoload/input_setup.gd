extends Node


# func _ready() -> void:

func add_key_action(action_name:StringName,keycode:Key)->void:
	if not InputMap.has_action(action_name):
		InputMap.add_action(action_name)
	for  event  in InputMap.action_get_events(action_name) :
		if event is InputEventKey and event.physical_keycode == keycode:
			return
	
	var event := InputEventKey.new()
	event.physical_keycode = keycode

	InputMap.action_add_event(action_name,event) 
