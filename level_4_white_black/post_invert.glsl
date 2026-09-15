#[compute]
#version 450


layout(
	local_size_x = 8,
	local_size_y = 8,
	local_size_z = 1
)in;


layout(
	rgba16f,//图片格式,每个通道16bit
	set = 0,
	binding = 0
)uniform image2D color_image;

layout(push_constant,std430)uniform Params{ //定义要给数据模块
	vec2 raster_size;//新建变量
	float values_1;
}params;//实例化


void main(){
	float values_1 = params.values_1;
	ivec2 id = ivec2(gl_GlobalInvocationID.xy);	
	ivec2 size = ivec2(params.raster_size.xy);
	//个人觉得这里不用min(size.x,size.y)更加适合暗角效果
	vec2 p = ( vec2(id) - 0.5*vec2( size ) )/vec2(size);


	if ( id.x >= size.x || id.y >= size.y  ){
		return;
	};


	vec4 color_origin  = imageLoad(color_image,id);
	vec4 color ;
	float gray = dot( color_origin.rgb,vec3(0.299,0.587,0.114) );
	color.rgb = vec3(gray);

	vec2 center = vec2(0.0, 0.0 );
	float dist = length(p - center);
	float mask = 1.0 - smoothstep(0.0,0.7,dist);

	color.rgb *= mask; 	

	vec4 color_final = mix(color_origin,color,values_1);


	imageStore(color_image,id,color_final);


}

