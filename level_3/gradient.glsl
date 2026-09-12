#[compute]
#version 450

//假设1920*1080，派240×135个小队，每个小队派8×8个工人，每个工人处理一个像素
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



//前一个Parmas{}是一个结构，后一个params是变量名
layout(push_constant, std430) uniform Params {
    vec4 data;
} params;



//----- Draw Line ------
float draw_line(
	vec2 a,
	vec2 b,
	vec2 p,
	float size,
	float line_mask,
	float smooth_v
){
	vec2 ap = p - a;
	vec2 ab = b - a;

	float closest = dot(ap,ab);
	float len_ab = dot(ab,ab);

	if ( len_ab <= 0.0000001 ){
		return 0.0;
	}

	float s_ = clamp(closest/len_ab,0.0,1.0);

	vec2 ao = ab*s_;
	vec2 op = ap - ao;
	float dist = length(op);

	line_mask = 1.0 - smoothstep(size,size + smooth_v,dist);

	return line_mask ;

}


//----- Draw Circle ------
float draw_circle(
	vec2 center,
	float radius,
	float circle_mask,
	vec2 p,
	float smooth_v
	 

){
	float dist = length(p - center);

	circle_mask = 1.0 - smoothstep(
			radius - smooth_v,
			radius + smooth_v,
			dist
			);

	return circle_mask ;

}




void main() {
    ivec2 id = ivec2(gl_GlobalInvocationID.xy);

    vec2 size = vec2(params.data.y, params.data.z);

    if (id.x >= size.x || id.y >= size.y) {
        return;
    }
		//normalize base on the shortest edge 
		vec2 p = ( vec2(id) -0.5*size)/float( min(size.x,size.y) );
		float max_x = 0.5*size.x/size.y;
		float max_y = 0.5*size.y/size.y;
		
		

		float time = params.data.x;
		float time_1 = ( time*10.0 + 1.0 )/2.0;

		float offset_1 = 0.5/10.0*sin(time_1);
		float offset_2 = 0.4;
		float offset_3 = 0.2;

		vec2 point_1 = vec2(sin(time_1),cos(time_1))*offset_3;		
		vec2 point_2 = vec2(-max_x,max_y);

		float ring_radius = offset_2*( 0.4 + offset_1 );
		float ring_width = offset_2*( 0.03 );

		vec2 delta = p - point_1;
		float radius =offset_2*(0.3) ;

		float smooth_values = offset_2*(0.003);
		float mask = 0.0;

		float line_width = 0.01;

//----- Draw Line ------
		mask = draw_line(
			point_1,
			point_2,
			p,
			line_width,
			mask,
			smooth_values
		);

//-----Ring------
		float	length_ =abs ( length(delta) - ring_radius);
		mask = max(mask, 1.0 - smoothstep(ring_width/2.0,ring_width/2.0+smooth_values*2.0 ,length_) );

//-----circle------
		mask = max(mask,draw_circle(point_1, radius, mask, p, smooth_values));

		vec4 v = vec4(
			-offset_1+0.4,
			offset_1+0.2,
			offset_1*0.1,
			1.0
		);
		vec4 v_2 = vec4(vec3(0.0),1.0);
		vec4 v_3 = mix(v_2,v,mask);


    imageStore(output_image, id, v_3);

}
