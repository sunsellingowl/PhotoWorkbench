"""Generated images only; no personal images are opened by the acceptance suite."""
from pathlib import Path
import struct,zlib,sys,os
from PIL import Image,ImageCms
root=Path(sys.argv[1]); root.mkdir(parents=True,exist_ok=True)
PROFILE=bytearray(ImageCms.ImageCmsProfile(ImageCms.createProfile('sRGB')).tobytes())
PROFILE[24:36]=struct.pack('>6H',2020,1,1,0,0,0)
PROFILE=bytes(PROFILE)
def chunk(kind,data): return struct.pack('>I',len(data))+kind+data+struct.pack('>I',zlib.crc32(kind+data)&0xffffffff)
def png(name,depth=8,change=False,meta=True):
    w,h=64,48; rows=[]
    for y in range(h):
        row=bytearray([0])
        for x in range(w):
            if depth==8:
                rgb=[(x*3)%256,(y*5)%256,57,0 if x<24 else 255]
                if change and x==0 and y==0: rgb[0]=1
                row.extend(rgb)
            else:
                rgba=[x*700+1,y*900+3,13457,0 if x<24 else 65535]
                if change and x==0 and y==0: rgba[2]+=1
                row.extend(struct.pack('>4H',*rgba))
        rows.append(row)
    data=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',w,h,depth,6,0,0,0))
    if meta:
        data+=chunk(b'tEXt',b'Author\0PhotoWorkbench fixture')
        data+=chunk(b'iCCP',b'ICC\0\0'+zlib.compress(PROFILE))
        exif=Image.Exif(); exif[34665]={36867:'2020:01:02 03:04:05',36868:'2021:02:03 04:05:06'}; exif[274]=6
        data+=chunk(b'eXIf',exif.tobytes()[6:])
    data+=chunk(b'IDAT',zlib.compress(b''.join(rows),0))+chunk(b'IEND',b'')
    (root/name).write_bytes(data)
for depth in [8,16]:
    png(f'rgba{depth}.png',depth); png(f'rgba{depth}-changed.png',depth,True); png(f'rgba{depth}-stripped.png',depth,meta=False)
image=Image.new('RGB',(128,96))
image.putdata([((x*5+y*3)%256,(x+y*7)%256,(x*2+y)%256) for y in range(96) for x in range(128)])
exif=Image.Exif(); exif[34665]={36867:'2020:01:02 03:04:05',36868:'2021:02:03 04:05:06'}; exif[306]='2022:03:04 05:06:07'; exif[274]=6
image.save(root/'capture.JPG',quality=99,exif=exif,icc_profile=PROFILE)
exif=Image.Exif(); exif[34665]={36868:'2021:02:03 04:05:06'}; exif[306]='2022:03:04 05:06:07'
image.save(root/'digitized.jpg',quality=99,exif=exif)
exif=Image.Exif(); exif[306]='2022:03:04 05:06:07'
image.save(root/'dated.jpg',quality=99,exif=exif)
image.save(root/'fallback.webp',quality=95)
image.save(root/'plain.jpg',quality=100)
(root/'corrupt.png').write_bytes(b'\x89PNG\r\n\x1a\ninvalid file')
# APNG marker must be explicitly rejected, never silently flatten the animation.
d=(root/'rgba8.png').read_bytes(); (root/'animated.png').write_bytes(d[:33]+chunk(b'acTL',struct.pack('>II',1,0))+d[33:])
oversized=bytearray((root/'plain.jpg').read_bytes())
pos=2
while pos+4<len(oversized):
    marker=oversized[pos+1]; length=int.from_bytes(oversized[pos+2:pos+4],'big')
    if marker in (0xc0,0xc1,0xc2):
        oversized[pos+5:pos+9]=struct.pack('>HH',65535,65535); break
    pos+=length+2
(root/'oversized.jpg').write_bytes(oversized)
d=(root/'rgba8.png').read_bytes()
(root/'oversized.png').write_bytes(d[:8]+chunk(b'IHDR',struct.pack('>IIBBBBB',100000,100000,8,6,0,0,0))+d[33:])
for p in root.iterdir(): os.utime(p,(1700000000,1700000000))
