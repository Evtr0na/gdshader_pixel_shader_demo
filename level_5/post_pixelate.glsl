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
	int pixel_size;
}params;//实例化


void main(){
	ivec2 id = ivec2(gl_GlobalInvocationID.xy);

	ivec2 size= params.raster_size;

	vec2 p = ( vec2( id ) - size*0.5 )*vec2( min(size.x,size.y) );
	 

	if (id.x >= size.x || id.y >= size.y){
	return;
	}
	
	if (params.mode == 0){
		vec4 color = imageLoad(source_image,id);
		imageStore(target_image,id,color);
		return;
	}

	int block_size = max(params.pixel_size,1);

	ivec2 sample_id = ( id/block_size) * block_size  + block_size / 2;

	sample_id  = clamp(sample_id,ivec2(0),size - ivec2(1));

	vec4 color  = imageLoad(source_image,sample_id);

	imageStore(target_image,id,color);

}

