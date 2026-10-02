"""Run: blender --background lands.blend --python tools/export_lands.py.
Non-destructive derived assets. Clips scene meshes into independently rotating tiles.
"""
import bpy, bmesh, json, math
from mathutils import Vector
from pathlib import Path
root = Path(bpy.data.filepath).parent
scale = 2 / 3
normals = [Vector(v) for v in [(0,1,0),(0,-1,0),(1,0,0),(-1,0,0),(0,0,-1),(0,0,1)]]
def godot(v): return Vector((v.x,v.z,-v.y))*scale
def blender(v): return Vector((v.x,-v.z,v.y))/scale
sources = [o for o in bpy.context.scene.objects if o.type in {'MESH','FONT'} and o.name not in {'Plaza Fountain','Fountain Bowl'}]
deps = bpy.context.evaluated_depsgraph_get()
collection = bpy.data.collections.new('Godot Export')
bpy.context.scene.collection.children.link(collection)
blocks = {}
metadata = {'tiles':[], 'scale':scale, 'source':'lands.blend', 'route':[]}
for theme in ['Desert','Oasis','Hutong','Garden','Mountain','Europe']:
 corners=sorted([o for o in sources if o.name.startswith(theme+' Road Corner ')],key=lambda o:int(o.name.rsplit(' ',1)[1]))
 points=[]
 for obj in corners:
  p=godot(obj.matrix_world.translation)
  face=max(range(6),key=lambda i:p.dot(normals[i]))
  p-=normals[face]*(p.dot(normals[face])-3)
  points.append(list(p))
 metadata['route'].append({'theme':theme,'points':points})
for x in range(3):
 for y in range(3):
  for z in range(3):
   if (x,y,z)==(1,1,1): continue
   pivot=bpy.data.objects.new(f'Block_{x}_{y}_{z}',None)
   collection.objects.link(pivot)
   pivot.location=blender(Vector((x-1,y-1,z-1))*2)
   blocks[x,y,z]=pivot
# Bake world vertices and preserve evaluated materials (including converted text).
baked=[]
for obj in sources:
 evaluated=obj.evaluated_get(deps)
 mesh=bpy.data.meshes.new_from_object(evaluated,depsgraph=deps)
 mesh.transform(obj.matrix_world)
 center=godot(obj.matrix_world.translation)
 face=max(range(6),key=lambda i:center.dot(normals[i]))
 bounds=[godot(v.co) for v in mesh.vertices]
 baked.append((obj,mesh,face,bounds))
for key,pivot in blocks.items():
 center=Vector(tuple((v-1)*2 for v in key))
 for face,n in enumerate(normals):
  if center.dot(n)<1.9: continue
  u=Vector((1,0,0)) if abs(n.x)<.5 else Vector((0,0,1))
  v=u.cross(n)
  origin=center+n
  record={'block':list(key),'face':face,'rects':[], 'markers':{}}
  for obj,mesh,obj_face,bounds in baked:
   if face!=obj_face: continue
   us=[(p-origin).dot(u) for p in bounds]; vs=[(p-origin).dot(v) for p in bounds]
   if max(us)<-1-1e-5 or min(us)>1+1e-5 or max(vs)<-1-1e-5 or min(vs)>1+1e-5: continue
   if ' Road ' in obj.name:
    lo_u=max(-1,min(us)); hi_u=min(1,max(us)); lo_v=max(-1,min(vs)); hi_v=min(1,max(vs))
    if hi_u-lo_u>1e-5 and hi_v-lo_v>1e-5:
     record['rects'].append([lo_u,lo_v,hi_u,hi_v])
   if obj.name in ('Node 0','Node X'):
    p=godot(obj.matrix_world.translation)-origin
    record['markers'][obj.name]=[p.dot(u),p.dot(v)]
   bm=bmesh.new(); bm.from_mesh(mesh)
   for axis in [u,-u,v,-v]:
    plane=blender(origin+axis)
    normal=Vector((axis.x,-axis.z,axis.y))
    geom=list(bm.verts)+list(bm.edges)+list(bm.faces)
    if not geom: break
    bmesh.ops.bisect_plane(bm,geom=geom,dist=1e-6,plane_co=plane,plane_no=normal,clear_outer=True,clear_inner=False)
   if not bm.faces:
    bm.free(); continue
   for vert in bm.verts: vert.co=(vert.co-pivot.location)*scale
   out=bpy.data.meshes.new(f'{obj.name}_{key}')
   bm.to_mesh(out); bm.free()
   for mat in mesh.materials: out.materials.append(mat)
   part=bpy.data.objects.new(f'{obj.name}_{key}',out)
   collection.objects.link(part); part.parent=pivot
  metadata['tiles'].append(record)
# Pivots and geometry must both be scaled consistently.
for pivot in blocks.values(): pivot.location*=scale
for obj in bpy.context.selected_objects: obj.select_set(False)
for obj in collection.objects: obj.select_set(True)
(root/'assets'/'lands_navigation.json').write_text(json.dumps(metadata,indent=2))
bpy.ops.export_scene.gltf(filepath=str(root/'assets'/'lands.glb'),export_format='GLB',use_selection=True,export_cameras=False,export_lights=False)
print('EXPORTED',len(collection.objects),'objects',len(metadata['tiles']),'tiles',sum(len(t['rects']) for t in metadata['tiles']),'road rectangles')
