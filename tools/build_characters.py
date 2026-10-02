"""Import CC0 Kenney models, customize palette, keep idle/walk, save editable Blender assets and GLBs.
Run: blender --background --python tools/build_characters.py
"""
import bpy, colorsys, math
from mathutils import Vector
from pathlib import Path
root=Path(__file__).resolve().parents[1]
out=root/'assets/characters'
for name,variant,height in [('Kate','e',1.4),('Sarah','b',0.76)]:
 bpy.ops.wm.read_factory_settings(use_empty=True)
 bpy.ops.import_scene.gltf(filepath=str(out/'source'/f'character-female-{variant}.glb'))
 arm=next(o for o in bpy.context.scene.objects if o.type=='ARMATURE')
 for obj in list(bpy.context.scene.objects):
  if obj!=arm and obj.parent is None: bpy.data.objects.remove(obj,do_unlink=True)
 for track in list(arm.animation_data.nla_tracks):
  if track.name not in {'idle','walk'}: arm.animation_data.nla_tracks.remove(track)
 for action in list(bpy.data.actions):
  if action.name not in {'idle','walk'}:
   bpy.data.actions.remove(action)
 idle=bpy.data.actions['idle']
 arm.animation_data.action=idle
 arm.animation_data.action_slot=idle.slots[0]
 bpy.context.scene.frame_set(1)
 bpy.context.view_layer.update()
 # Modify the shared color palette into separate character-specific textures.
 for image in bpy.data.images:
  if image.size[0]<2: continue
  pixels=list(image.pixels[:])
  for i in range(0,len(pixels),4):
   h,s,v=colorsys.rgb_to_hsv(*pixels[i:i+3])
   if .64<h<.88 and s>.25:
    rgb=colorsys.hsv_to_rgb(.59 if name=='Kate' else .48, min(s,.6),v*.8)
    pixels[i:i+3]=rgb
  image.pixels[:]=pixels
  image.name=name+'_Palette'
  image.filepath_raw=str(out/(name.lower()+'_palette.png'))
  image.file_format='PNG'; image.save(); image.pack()
 deps=bpy.context.evaluated_depsgraph_get()
 vertices=[]
 for obj in arm.children:
  if obj.type=='MESH':
   evaluated=obj.evaluated_get(deps); mesh=evaluated.to_mesh()
   vertices.extend(obj.matrix_world@v.co for v in mesh.vertices)
   evaluated.to_mesh_clear()
 bottom=min(v.z for v in vertices); top=max(v.z for v in vertices)
 factor=height/(top-bottom)
 # Blender -Y is front on these source models; rotate 180 degrees so exported Godot -Z is front.
 pivot=bpy.data.objects.new(name+'Visual',None); bpy.context.collection.objects.link(pivot)
 arm.parent=pivot; arm.location.z=-bottom
 pivot.scale=(factor,)*3; pivot.rotation_euler.z=math.pi
 arm.name=name+'Rig'
 bpy.context.scene['asset_source']='https://kenney.nl/assets/mini-characters'
 bpy.context.scene['license']='CC0; customized palette, height, orientation and animation selection'
 bpy.context.scene['character_height']=height
 for obj in bpy.context.scene.objects: obj.select_set(True)
 bpy.context.view_layer.objects.active=arm
 bpy.ops.wm.save_as_mainfile(filepath=str(out/(name.lower()+'.blend')))
 bpy.ops.export_scene.gltf(filepath=str(out/(name.lower()+'.glb')),export_format='GLB',use_selection=True,export_animations=True,export_animation_mode='ACTIONS',export_anim_single_armature=True,export_cameras=False,export_lights=False)
 print('CHARACTER_EXPORTED',name,'height',height,'actions',[a.name for a in bpy.data.actions])
