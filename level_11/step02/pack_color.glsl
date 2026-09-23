#[compute]
#version 450

layout(
	local_size_x = 8,
	local_size_y = 8,
	local_size_z = 1
)in;

layout(
		rgba16f,
		set = 0,
		binding = 1
)uniform readonly image2D src_color;


layout(
	rgba16f,
	set = 0,
	binding = 1
)uniform writeonly image2D dst_atlas;


layout(push_constant,std430)uniform Params{
	ivec4 data;
}params;


void main(){
	ivec2 pix = ivec2(gl_GlobalInvocationID.xy);

	int face = params.data.x;
	int res = params.data.y;

	if (pix.x > res || pix.y > res){
		return;
	}	

	vec4 color = imageLoad(src_color,pix);

	//grid满3换行 vec2(col,row)
	int col = face % 3;
	int row = face / 3;

	ivec2 title_origin = ivec2( col * res  ,row * res);
	ivec2 atlas_pixel = title_origin + pix ;

	imageStore(dst_atlas,atlas_pixel,vec4(color.rgb,1.0));

}

