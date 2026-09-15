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

//Rotation_2d
vec2 rotate_2d(vec2 p ,float angle ) {
	float c = cos(angle);
	float s = sin(angle);

	return vec2(
		c*p.x - s*p.y,
		s*p.x + c*p.y
	);

}



void main(){

	//parameter
	ivec2 id = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size= params.raster_size;
	float scale = 1.0/min(float( size.x ),float( size.y )); 	
	vec2 p = ( vec2( id + 0.5 ) - vec2( size )*0.5 )*scale;
	 
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
	int sample_count = max( 1,params.sample_count );
	vec2 screen_half = 0.5*vec2( size )*scale ;
	vec2 center	= clamp(params.center,-screen_half,screen_half);//blur center and limit center in screen

	vec2 direction = center - p;
	vec4 sum = vec4(0.0);
	float weight_sum = 0.0;

	for ( int i = 0 ; i < sample_count  ; i++ ){
		float t = float( i )/float( sample_count );
		// float weight =1.0 - t;
		float weight =pow( 1.0 - t ,2);
		// float weight =t;

		// vec2 sample_id_nor = p + direction * t * strength;
		vec2 sample_id_nor = mix(p,center,t*strength);//normalize id
		ivec2 sample_id = ivec2( sample_id_nor / scale + 0.5*vec2( size ) );//real id

		sample_id = clamp(sample_id,ivec2(0,0),size - ivec2(1));
		vec4 sample_color = imageLoad(source_image,sample_id);
		sample_color *= weight;

		sum += sample_color;//sum color
		weight_sum += weight;
	}
	
	vec4 color = sum/( weight_sum );

	imageStore(target_image,id,color);

}

