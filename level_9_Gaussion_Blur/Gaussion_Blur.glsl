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
	float sigma;
	int radius;
}params;//实例化


void main(){

	//parameter
	ivec2 id = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size= params.raster_size;
	 
	if (id.x >= size.x || id.y >= size.y){
	return;
	}
	
	vec4 sum = vec4(0.0);
	int radius = max(0, params.radius );
	float weight_sum = 0.0;
	float sigma = max(0.0001 ,params.sigma );

	//mode = 1 , direction = ivec2(0,1)
	//mode = 0 , direction = ivec2(1,0)
	int mode = params.mode;
	ivec2 direction = ivec2(1 - mode,mode);

	for (int i = -radius ; i <= radius ; i++ ){

		ivec2 sample_id = direction * i + id; 
		sample_id = clamp(sample_id,ivec2(0.0),size - ivec2(1));//limit in screen space

		float dist_sq = float(i*i) ;
		float weight = 	exp(-dist_sq/( 2.0*sigma*sigma ));

		sum += imageLoad(source_image,sample_id)*weight;
		weight_sum += weight;
	}
	 
	vec4 color = sum / weight_sum;//average

	imageStore(target_image,id,color);
}

