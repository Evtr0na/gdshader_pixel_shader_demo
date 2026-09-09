#[compute]
#version 450

layout(
    local_size_x = 8,
    local_size_y = 8,
    local_size_z = 1
) in;

layout(
    rgba8,
    set = 0,
    binding = 0
) uniform writeonly image2D output_image;

layout(push_constant, std430) uniform Params {
    vec4 data;
} params;


// float draw_line(){
// 	return 1.0
// }

void main() {
    ivec2 id = ivec2(gl_GlobalInvocationID.xy);

    ivec2 size = ivec2(params.data.y, params.data.z);

    if (id.x >= size.x || id.y >= size.y) {
        return;
    }
		//normalize base on the shortest edge 
		vec2 p = ( vec2(id) -0.5*size)/float( min(size.x,size.y) );

		vec2 point_1 = vec2(0.0,0.0);		
		float ring_radius = 0.4;
		float ring_width = 0.03;

		vec2 delta = p - point_1;
		float radius =0.3 ;
		float smooth_values = 0.003;
		float mask = 0.0;

//-----Ring------
		float	length_ =abs ( length(delta) - ring_radius);

		mask = 1.0 - smoothstep(ring_width/2.0,ring_width/2.0+smooth_values*2.0 ,length_);

//-----circle------
		length_ = length(delta);

		mask = max(mask,1.0 - smoothstep(
			radius - smooth_values,
			radius + smooth_values,
			length_
		));

		vec4 v = vec4(1.0);
		vec4 v_2 = vec4(vec3(0.0),1.0);
		vec4 v_3 = mix(v_2,v,mask);


    imageStore(output_image, id, v_3);

}
