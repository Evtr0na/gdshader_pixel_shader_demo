extends Node3D
@onready var World_En:WorldEnvironment = $WorldEnvironment
var time_ :float= 0.0

func _physics_process(delta: float) -> void:

	var CompositorEffect_:CompositorEffect= World_En.compositor.compositor_effects.get(0)
	time_ += 3*delta
	CompositorEffect_.set("strength",( sin(time_) + 1.0 )/50.0)
