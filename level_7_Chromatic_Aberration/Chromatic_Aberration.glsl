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
)uniform readonly image2D source_image;

layout(
	rgba16f,
	set = 0,
	binding = 1
)uniform writeonly image2D target_image;

layout(push_constant,std430)uniform Params{ //定义要给数据模块
	ivec2 raster_size;//新建变量
	int mode;
	vec2 center;
	float strength;
	int sample_count;
}params;//实例化




void main(){

	//parameter
	ivec2 id = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size= params.raster_size;
	float scale = 1.0/min(float( size.x ),float( size.y )); 	
	vec2 p = ( vec2( id ) + 0.5 - vec2( size )*0.5 )*scale;
	 
	if (id.x >= size.x || id.y >= size.y){
	return;
	}

	// mode = 0 ,copy to temp_image	
	if (params.mode == 0){
		vec4 color = imageLoad(source_image,id);
		imageStore(target_image,id,color);
		return;
	}
	
	float strength = max(0.0, params.strength );//blur strength
	vec2 screen_half = 0.5*vec2( size )*scale ;
	vec2 center	= clamp(params.center,-screen_half,screen_half);//blur center and limit center in screen
	
	vec2 direction =  p - center ;
	vec2 offest = direction * strength ;

	//offest 径向、随离中心距离增强的 Chromatic Aberration
	vec2 red_p = center + direction + offest;
	vec2 blue_p = center + direction - offest; 

	//turn back to id
	ivec2 red_id = ivec2( red_p / scale + 0.5 * vec2( size ) );
	ivec2 blue_id = ivec2( blue_p / scale + 0.5 * vec2( size ) );

	// limit in screen space
	red_id = clamp(red_id,ivec2(0),size - ivec2(1));
	blue_id = clamp(blue_id,ivec2(0),size - ivec2(1));

	//sample
	vec4 red = imageLoad(source_image,red_id);
	vec4 green = imageLoad(source_image,id);
	vec4 blue = imageLoad(source_image,blue_id);
	
	vec4 color = vec4(red.r,green.g,blue.b,1.0);


	imageStore(target_image,id,color);

}

