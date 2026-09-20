## 1

[0:02] Hello there. You've probably seen that project shadowglass video going around where a guy

[0:08] managed to get uh almost fully stable pixels in 3D. If not, the guy deserves some support. Uh the

[0:16] video is in the description. He mentioned that a good magician never reveals his tricks, but as a

[0:25] wizard, I'm going to show my approach to the 3D pixel art effect. My first try was to downsample

[0:33] the scene using points. I managed to get this The Dig look, which I for sure dig, but the flickering

[0:43] was there despite making a custom downsampler. I spent some time thinking about it and I'm not sure

[0:51] that 3D pixels are really possible. However, our eyes can be fooled. Notice how rotating the camera

[0:59] doesn't change the image at all. That's because I'm surrounded by six renderings of the scene. In

[1:05] other words, the trick is simply to use a cubemap. But we still have a problem with flickering when

[1:13] we move. And I don't know if there's any simple way of completely eliminating it. To minimize it,

[1:19] you must avoid thin geometry in your scene and use aggressive LODs in your texture sampling.

[1:28] You can also use fog or even depth blur to hide high frequency details.

[1:35] And finally, you can do what I did and sample the scene using two cube maps for interpolation.

[1:43] All right, let's see how to set this up. I'll use Godot,

[1:47] but you can do the same in other engines. Start by adding a node3D to the scene and

[1:52] add another node3D as its child. That will be your cube map. Fill it with six subviewports

[1:59] and for each viewport, set the resolution to a low square resolution and add cameras.

[2:10] Rotate the cameras so each camera faces a different axis. Then duplicate the cube

[2:16] map. Add a subviewport container to your scene with another subviewport and place your main

[2:22] camera into it. Attach a script to your cube map controller. The script is pretty simple.

[2:30] Declare the shader material that will receive the cubemap textures, a controllable float,

[2:36] a player or a camera, your cube map nodes, and two arrays to store the cube map viewports. Fill those

[2:43] arrays with the viewports. And we can move to the process method, which will position each camera in

[2:50] each viewport to the same position as the main camera and to an offset position. We do this

[2:56] offset sampling to reduce aliasing. It is a form of supersampling. Then all this code do is to pass

[3:03] the viewport textures into the shader material. Okay. Now we need a shadermaterial, a shader and

[3:09] a quad in front of our camera to render our final image to. Add a quad mesh in front of your main

[3:16] camera. Create a new shader and assign it to a new shader material. Then assign the shader material

[3:24] to your quad. Set the render modes of your shader to the following. Create some variables to control

[3:32] it and declare uniforms to receive the cubemap textures from our script. Create a method for

[3:40] converting a direction into a UV coordinate and a method to blend the cubemap faces. This is

[3:48] optional, but you can have a copy of that method with a slight offset to generate some antialising.

[3:55] Then grab your view direction in world space and use it to sample the cubemaps. Quantize

[4:02] and mix them to generate the final color. I'm also doing an accumulation motion blur in this shader,

[4:08] but that's not necessary. So I won't teach you this unless I get enough requests in the comments.

[4:14] That's it. Tweak the values to your liking. Uh I will also show you how to improve the colors.

[4:21] Games like Sonic 3 and Echo the Tides of Time are masterpieces to me because of how beautifully

[4:27] they've used their limited color palettes. Naturally, I've been trying to make my games

[4:34] look good while keeping the nostalgic pixelation. My game Sepulchron is something I've been working

[4:41] on in my free time. It is a puzzle roguelike inspired by point-and-click games and with lots

[4:48] of physics interactions. I wish this could be my full-time job. Uh, but it's too bad that we all

[4:53] have bills to pay. Heh? That being said, I've already started planning my next game for when

[4:59] I release Sepulchron. I would love to hear your opinion as it will use the same artstyle I just

[5:06] showed you in this video how to make. It will be an RTS along the lines of Starcraft meets,

[5:13] MS-DOS Diggers, and Fear and Hunger. You'll gather resources and try to survive on brutally hostile

[5:20] alien planets all in that gritty 80s sci-fi 3D pixel art style. As a multiplayer game,

[5:27] killing other players is encouraged, but the alien challenges themselves are so brutal

[5:33] that fighting another player would be a high-risk move. The game will likely be called Solstygian.

[5:42] You will command your forces from a god's eye view with fog of war or dive down into a third person

[5:48] unit perspective to collect resources whenever you choose. Okay, enough sidetracking. Let me

[5:55] know what you think of my game idea and let's get back to colors. Here I'm applying a lookup table

[6:02] or LUT so I can efficiently sample from a color palette. And as a bonus, I can even interpolate

[6:09] between LUTs in case I want to have better control of my day-night cycle colors. To use a

[6:17] lookup table is very easy. Take a few screenshots of your game and paste them into Photoshop. Then

[6:24] add a neutral lookup table next to them. Tweak the image colors and curves until you are satisfied

[6:32] and select the save for web option. Here you can choose between various color levels and palettes.

[6:40] The more colors you add, the less it will look like vintage graphics. The less colors you use,

[6:46] the more it will flicker. Once you are satisfied, save it and crop the lookup table. Import it as a

[6:56] texture 3D in Godot and modify your shader to sample from it instead of quantizing.

[7:04] Be careful with HDR. You might have to use a tonemapper. I'm using a simple log compression,

[7:11] but you can also use ACES, filmic, AGX or whatever you prefer. Finally,

[7:17] you can dither your sky. The less colors you are using,

[7:20] the more explicit the dithering patterns will be. Just use a procedural sky and apply debanding

[7:32] or program a sky shader yourself with some dithering. I have a tutorial on sky shaders

[7:37] you may follow. It uses noise to deband, but you can modify it to use dithering. I guess that's

[7:45] all for today. Subscribe if you want to know more about Sepulchron, Solstygian or future videos on

[7:52] shader programming. If you want to support me, the best you can do is wishlist Sepulchron on Steam.

[8:01] Uh that's how you can help me release it and move on to Solstygian. Also,

[8:08] please leave a comment. I really want to hear from you. Um when we are developing a game,

[8:14] we tend to get lost in it and we grow used to its little quirks.


## 2
00:01 Welcome back. A while ago, I made a  video trying to figure out how the, 
00:05 project shadow glass look was achieved. At  the time, I already knew the idea behind it,
00:11 but I still couldn't find a way to reproduce  it in Godot, mostly due to its pipeline, 
00:17 limitations. Well, eventually I found a way  while developing a custom GI shader. Today,
00:25 I'm going to explain the approach I used to  achieve this effect, how it works internally,
00:29 and how you can implement something similar  yourself. Just keep in mind, this is not a, 
00:34 step-by-step tutorial. I'm only going to provide  the foundation behind the technique. Four months, 
00:40 ago, I asked the developer if I was on the  right track, but never got a reply. After weeks, 
00:47 of experimentation, debugging and fighting with  compositor and compute shader issues, my reverse, 
00:54 engineered approach worked and I turned it into  a Godot plug-in. I did make it a paid plug-in,
01:00 but I still wanted to show how it works here. The  Godot community has always been very helpful and I.
01:06 think sharing between devs is important. If you  want to see what the plug-in offers, skip this, 
01:11 chapter. Otherwise, stay for the technique. As  shown in my previous video, rendering the scene to.
01:17 a cube map and then sampling it with a camera gets  rid of shimmering during rotation, but not during, 
01:23 translation. The only way to stabilize translation  is to stop translating all together. Instead,
01:29 we warp the cube map as we move so it stays  correctly projected onto the geometry. To do that,
01:35 we need two cube maps. One that only snaps and  another that follows the camera. The static, 
01:41 cube map snaps to the camera once it gets too far  away. Before snapping, the static cube map stores, 
01:47 a copy of itself in memory. This copy is used  to smoothly interpolate between the previous and, 
01:53 current positions. Depth is stored in the cube  map and used to determine what the cube map can, 
01:59 and cannot see. I'm highlighting the disocclusion  in magenta and as we move it grows until the cube, 
02:06 map snaps again. Most of the color comes from  the static cube map while the magenta areas, 
02:14 fall back to the camera bound cube map. We can  also fall back to the original scene eliminating.
02:20 all flickering at the cost of some non-pixelated  disoccluded areas. But the flickering isn't that, 
02:28 distracting. Keep in mind I'm using dithering  which greatly amplifies it. But cube maps usually, 
02:36 don't carry depth information. So let's see how  to solve that in Godot. In my previous video,
02:42 I showed how to create a cube map using six sub  viewports and six cameras. The view ports control, 
02:48 the resolution. I also made a separate scene  just for the cube map. Now each camera needs, 
02:54 a compositor effect. Its main job is to compress  and store the camera's radial depth in the alpha, 
03:00 channel of the cube map images. The compute  shader stores the depth and compresses it in a, 
03:06 way that preserves precision in the near field. We  don't care as much about the far field. The cube, 
03:12 map viewport output now contains depth in its  alpha channel. Using GDScript, we capture that, 
03:18 output and pass it along with the cube map's world  position to a fragment shader on a camera facing.
03:24 quad. To properly sample the cube map, we need  the current pixel's world position and the cube, 
03:30 map center. Since a cube map is sampled using  a view direction, we only need to offset that, 
03:36 direction accordingly in the fragment shader.  We use this corrected direction to sample the, 
03:41 cube map and decode the compressed depth stored in  the alpha channel. Now we just compare the camera, 
03:48 depth with the cube map depth. If the difference  is too large, it likely sampled a disocclusion.
03:54 Here we reproject both cube maps into world space  reject invalid depth mismatches and blend the, 
04:00 valid samples in linear space to achieve a smooth  temporal transition. That's the core technique and, 
04:07 it should be enough for you to implement it  yourself. But if you would rather avoid the, 
04:12 hassle of compositors and compute shaders,  I will walk you through my plugin instead.
04:21 Once you download it, create a new  Godot 4.5.1 plus project. Ensure it, 
04:27 is using Forward Plus. Other pipelines won't work.
04:34 Open your resources folder. Create  a folder named addons and open it.
04:43 Find your CUBY plug-in folder and  copy it into the add-ons folder.
04:55 You may get some errors. Just enable the plugin  in project -> project settings -> plugins. Now, 
05:03 the plug-in is running. Add your  objects and set up your scene.
05:14 As you can see, it works right out of the box.
05:18 It comes with a pixelated sky shader. Just add an  environment to the scene and use it as your sky.
05:28 The shader is into the materials folder.  There are multiple variables to tweak and, 
05:34 some textures you may use such as atmosphere  and clouds. Also within the materials folder,
05:47 I'm also including a script to automate  the day-night cycle. You will need two, 
05:53 directional lights for it. I will skip the setup  here, but you can follow the plug-in manual.
06:00 The pixel density on the skybox is configurable.
06:07 as well as the dithering, halo size, sun size, and  the list goes on. Now, let's go over the main CUBY, 
06:15 configurations. In the plug-in folder, look for an  icon labeled cuby_saved_config and doubleclick it.
06:26 The inspector will pop open with  the available inputs. You can, 
06:32 enable or disable the effect in the editor  viewport. Change the resolution on the go.
06:47 Change the snapping distance between cube map, 
06:49 and camera and also the time it  takes to blend both cube maps.
06:57 Change the fallback distance so the player  can hold weapons without clipping. Disable or, 
07:03 enable the skybox rendering on the cube maps.  And it will look a bit more like pixel art,
07:11 but will give you more flickering  where geometry meets the sky.
07:14 And you will also have to change the  layer where your weapon is rendered.
07:25 Let's change the dithering a bit.  Change how far the dithering spreads.
07:41 Now let's make it fall back to the  cube map instead of the raw scene.
07:44 It will flicker more on the edges  but will look more like pixel art.
07:55 uncheck it to see the raw scene  when there's disocclusion.
08:04 The plug-in also provides a custom PBR  material that accepts LUT palettes.
08:14 When LUT is unchecked, the CUBY configs will  tweak the shader quantization mode and levels.
08:21 Choose between naive quantization, luma,  and luma chroma for more accurate results.
08:34 This is what the scene looks  like with no quantization.
08:42 Let's mess around with the  parameters of the cube map renderer.
09:05 Layer 2 is used to remove the  weapons from the rendering.
09:13 Let's get back to the original sky.
09:24 We can also apply a LUT to the sky material.
09:34 Bear in mind that the day-night  cycle greatly affects visuals.
09:39 The plug-in also includes custom particles  like the grass because standard billboards, 
09:45 won't work properly with the cube map  rendering. Those billboards always, 
09:49 face the cube map center instead  of aligning to the camera plane.
09:55 I've also included a palette to  LUT converter. You can download, 
10:00 palettes from lospec.com and  apply them to your materials.
10:07 Download the one pixel tall palette. Find  the palettes to LUT script within the plug-in, 
10:14 folder and double click it. Feed it a one  pixel tall palette texture and click bake.
10:22 It will generate your lut in the same folder  as the palette and with the suffix cuby_LUT.
10:37 You must click the generated texture  and reimport it as a 3D texture.
10:46 Make sure to set the slices accordingly. In  this case, I'm using 32 because that's the, 
10:50 output of my script. Now, let's apply  a LUT to geometry, particles, and sky.
11:03 By acquiring my plug-in, you are  supporting this channel and also, 
11:07 the development of my game Sepulchron  as well as other upcoming games. So,
11:13 thank you for watching. I hope you enjoyed it.  I hope it was clear enough, but if there are, 
11:20 any questions, feel free to reach out in the  comments. As always, thank you and bye-bye.
