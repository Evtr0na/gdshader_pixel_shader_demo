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
	float sigma;
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
	
	vec2 screen_half = 0.5*vec2( size )*scale ;

	vec4 sum = vec4(0.0);
	int radius = max(0, params.radius );
	float weight_sum = 0.0;
	float sigma = max(0.0001 ,params.sigma );


	
	for (int x = -radius ; x <= radius ; x++){
		for (int y = -radius ; y <= radius ; y++){
			
			ivec2 sampler_id = ivec2(id.x + x,id.y + y);//offest
			sampler_id = ivec2( clamp(sampler_id, ivec2( 0.0 ),size - ivec2(1)) );//limit

			float dist_sq = x*x + y*y ;

			float weight = 1.0;
			weight = exp(-(dist_sq)/(2.0*sigma*sigma));

			int limit_2 = 10000;// limit_2 = 0 or 1 or 100
			if (abs(x) <= limit_2 || abs(y) <= limit_2){
				sum += imageLoad(source_image,sampler_id)*weight;//sample
				weight_sum += weight; 
			}	
		}
	}

	vec4 color = sum / weight_sum;//average

	imageStore(target_image,id,color);

}

