extends Control


var is_exist:bool = true


func _ready():
	is_exist = FileAccess.file_exists("res://123")
	print(is_exist)
	
