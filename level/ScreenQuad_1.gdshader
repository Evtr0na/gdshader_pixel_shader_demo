shader_type spatial;

render_mode
unshaded,
fog_disabled,
cull_disabled,
depth_draw_never,
depth_test_disabled;


uniform sampler2D
screen_texture:hint_screen_texture,
repeat_enable,
filter_nearest;

uniform sampler2D
depth_texture:hint_depth_texture,
repeat_disable,
filter_nearest
;
uniform float offest_1;
uniform float offest_2;
uniform float offest_3;
uniform float offest_4;

void vertex() {
    
    POSITION = vec4(
    VERTEX.xy,
    1.0,
    1.0
    );
    // POSITION = vec4(
    // VERTEX.x*offest_1+offest_3,
    // VERTEX.y*offest_2+offest_4,
    // 1.0,
    // 1.0
    // );
    
}



void fragment() {
    float depth = texture(depth_texture, SCREEN_UV).;
    vec3 depth_ = vec3(depth);
    vec4 original = texture(screen_texture, SCREEN_UV);
    
    if (depth<0.000001){
        ALBEDO = original.rgb;
    }
    else{
        vec3 ndc = vec3(
        SCREEN_UV*2.0-1.0,
        depth
        );
        
        vec4 world = vec4(
        INV_VIEW_MATRIX*
        INV_PROJECTION_MATRIX*
        vec4(ndc,1.0)
        );
        
        vec3  world_positon =world.xyz/world.w;
        ALBEDO =fract(abs(world_positon)*0.25);
    }
    
    
    
}
