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
	int radius;
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

	vec4 sampler_color = vec4(0.0);
	int radius = params.radius;

	for (int i = -radius ; i <= radius ; i++){
		for (int s = -radius ; s <= radius ; s++){

			ivec2 sampler_p = ivec2(id.x + i,id.y + s);//offest
			sampler_p = ivec2( clamp(sampler_p, ivec2( 0.0 ),size) );//limit
			sampler_color += imageLoad(source_image,sampler_p);//sample
		}

	}

	vec4 color = sampler_color / pow(radius*2,2);//average





	imageStore(target_image,id,color);

}

