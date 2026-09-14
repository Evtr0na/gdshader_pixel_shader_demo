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
	int visual_style;
	float rotation_value;
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
	float scale = 1/min(float( size.x ),float( size.y )); 	
	vec2 p = ( vec2( id ) - vec2( size )*0.5 )*scale;
	int visual_style = params.visual_style;
	 

	if (id.x >= size.x || id.y >= size.y){
	return;
	}


	// mode = 0 ,copy to temp_image	
	if (params.mode == 0){
		vec4 color = imageLoad(source_image,id);
		imageStore(target_image,id,color);
		return;
	}

	// rotate
	float rotation_value_ = float( params.rotation_value );
	vec2 rotated_p = rotate_2d(vec2( p + 0.5*scale),radians(rotation_value_));
	
	//which cell is this id in? 
	float block_size = max(params.pixel_size,1);
	float block_span = float( block_size )*scale;
	vec2 cell = floor(rotated_p/block_span);
	vec2 pixelate_p = ( cell+0.5 )*block_span;

	// sample clolr
	ivec2 sample_id = ivec2( rotate_2d( pixelate_p ,-radians( rotation_value_ )) /scale  + vec2( size )*0.5);
	sample_id  = clamp(sample_id,ivec2(0),size - ivec2(1));
	vec4 color  = imageLoad(source_image,sample_id);


	// normalize in cell
	vec2 center =vec2( rotate_2d( pixelate_p,-radians(rotation_value_) ) /scale  + vec2( size )*0.5);//real location
	vec2 local = rotate_2d( (vec2( id ) - vec2(center))/block_size ,radians(rotation_value_));//normalize


	// Draw patterns
	float dist = max(local.x,local.y);
	if (visual_style == 0){
		vec2 q = abs( local );
		dist = max(q.x,q.y);//方形
	}
	else{
		if (visual_style == 1){
			dist = length(local);//圆形
		}
		else{
			if (visual_style == 2){
			dist = abs( local.x + local.y );//斜线
			}
			else{
				vec2 q = abs( local );
				dist = q.x + q.y;//棱形
			}
		}
	}

	//grey
	float grey = dot( color.rgb ,vec3(0.299,0.587,0.114));
	float luminance  = clamp(grey,0.0,1.0);
	float distance_ = mix( 0.0,0.5,luminance );

	//mask
	float dot_mask = 0.0;
	dot_mask = max(dot_mask,1.0 - smoothstep(distance_,distance_+0.1,dist));//Option-2

	//color
	vec3 white = vec3(1.0);
	vec3 black = vec3(0.0);

	// color = vec4( mix(white,black,1 - dot_mask) ,1.0);
	// color = vec4( mix(vec3( grey ),1 -black,dot_mask) ,1.0);
	color = vec4( mix(color.rgb,black,1.0 - dot_mask) ,1.0);


	imageStore(target_image,id,color);

}

