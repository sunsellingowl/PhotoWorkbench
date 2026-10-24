#import "PWBackend.h"
#import <ImageIO/ImageIO.h>
#import <CommonCrypto/CommonDigest.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <png.h>
#import <zlib.h>

static BOOL fail(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"PhotoWorkbench" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
    return NO;
}
NSString *PWFileIdentity(NSURL *url) {
    struct stat s;
    if (lstat(url.fileSystemRepresentation, &s) || !S_ISREG(s.st_mode)) return nil;
    return [NSString stringWithFormat:@"%llu:%llu", (unsigned long long)s.st_dev, (unsigned long long)s.st_ino];
}
NSString *PWFileSignature(NSURL *url, NSError **error) {
    int fd = open(url.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) { fail(error, @"File is missing, unreadable, or a symbolic link."); return nil; }
    struct stat before, after;
    if (fstat(fd, &before) || !S_ISREG(before.st_mode)) { close(fd); fail(error, @"Not a regular file."); return nil; }
    CC_SHA256_CTX ctx; CC_SHA256_Init(&ctx);
    unsigned char buffer[65536], digest[CC_SHA256_DIGEST_LENGTH]; ssize_t n;
    while ((n = read(fd, buffer, sizeof(buffer))) > 0) CC_SHA256_Update(&ctx, buffer, (CC_LONG)n);
    BOOL stable = n == 0 && !fstat(fd, &after) && before.st_size == after.st_size &&
        before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec &&
        before.st_birthtimespec.tv_sec == after.st_birthtimespec.tv_sec && before.st_birthtimespec.tv_nsec == after.st_birthtimespec.tv_nsec;
    close(fd);
    if (!stable) { fail(error, @"File changed while being read. Add it again after editing finishes."); return nil; }
    CC_SHA256_Final(digest, &ctx);
    NSMutableString *result = [NSMutableString stringWithFormat:@"%llu:%llu:%lld:%lld:%ld:%lld:%ld:", (unsigned long long)before.st_dev, (unsigned long long)before.st_ino, before.st_size, (long long)before.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec, (long long)before.st_birthtimespec.tv_sec, before.st_birthtimespec.tv_nsec];
    for (int i = 0; i < sizeof(digest); i++) [result appendFormat:@"%02x", digest[i]];
    return result;
}
BOOL PWMoveExclusive(NSURL *from, NSURL *to, NSError **error) {
    if (!renameatx_np(AT_FDCWD, from.fileSystemRepresentation, AT_FDCWD, to.fileSystemRepresentation, RENAME_EXCL)) return YES;
    return fail(error, [NSString stringWithFormat:@"Cannot rename without overwriting: %s", strerror(errno)]);
}

static uint32_t be32(const uint8_t *p) { return ((uint32_t)p[0]<<24)|((uint32_t)p[1]<<16)|((uint32_t)p[2]<<8)|p[3]; }
static BOOL isPNG(NSData *d) { const uint8_t sig[] = {137,80,78,71,13,10,26,10}; return d.length >= 8 && !memcmp(d.bytes,sig,8); }
// Preserve raw ancillary chunks. tRNS is represented by decoded alpha; encoding chunks may change.
static NSDictionary *pngMetadata(NSData *data) {
    NSMutableDictionary *result = [NSMutableDictionary new]; const uint8_t *p = data.bytes; NSUInteger pos=8;
    while (pos + 12 <= data.length) {
        uint32_t length = be32(p+pos); if (length > data.length-pos-12) return nil;
        const uint8_t *type = p+pos+4;
        if ((uint32_t)crc32(0, type, length+4) != be32(p+pos+8+length)) return nil;
        NSString *name = [[NSString alloc] initWithBytes:type length:4 encoding:NSASCIIStringEncoding];
        if (!name || [name isEqualToString:@"acTL"]) return nil; // Animated PNG requires frame-aware validation.
        if ((type[0]&32) && ![name isEqualToString:@"tRNS"]) {
            NSMutableArray *values=result[name]; if (!values) result[name]=values=[NSMutableArray new];
            [values addObject:[data subdataWithRange:NSMakeRange(pos+8,length)]];
        }
        pos += length+12;
        if ([name isEqualToString:@"IEND"]) return pos==data.length ? result : nil;
    }
    return nil;
}
static NSDictionary *jpegMetadata(NSData *data) {
    const uint8_t *p=data.bytes; NSUInteger n=data.length, pos=2;
    if (n<4 || p[0]!=255 || p[1]!=216) return nil;
    NSMutableDictionary *result=[NSMutableDictionary new];
    // Scan all markers, including those between progressive scans.
    while (pos<n) {
        if (p[pos++]!=255) continue;
        while (pos<n && p[pos]==255) pos++;
        if (pos>=n) break; uint8_t marker=p[pos++];
        if (!marker || (marker>=208 && marker<=215)) continue;
        if (marker==217) return result;
        if (pos+2>n) return nil;
        NSUInteger len=((NSUInteger)p[pos]<<8)|p[pos+1];
        if (len<2 || len>n-pos) return nil;
        if ((marker>=224 && marker<=239) || marker==254) {
            NSString *key=[NSString stringWithFormat:@"%u",marker];
            NSMutableArray *items=result[key]; if (!items) result[key]=items=[NSMutableArray new];
            [items addObject:[data subdataWithRange:NSMakeRange(pos+2,len-2)]];
        }
        pos+=len;
    }
    return nil;
}

typedef struct { const unsigned char *data; size_t size, offset; unsigned char *pixels; png_bytep *rows; } PNGReader;
static void pngRead(png_structp png, png_bytep output, png_size_t count) {
    PNGReader *r=png_get_io_ptr(png);
    if (count > r->size-r->offset) png_error(png,"Truncated image");
    memcpy(output,r->data+r->offset,count); r->offset+=count;
}
static void pngError(png_structp png, png_const_charp message) { png_longjmp(png,1); }
static void pngWarning(png_structp png, png_const_charp message) {}
static NSData *pngPixels(NSData *data, size_t *width, size_t *height) {
    png_structp png=png_create_read_struct(PNG_LIBPNG_VER_STRING,NULL,pngError,pngWarning);
    if (!png) return nil;
    png_infop info=png_create_info_struct(png);
    PNGReader *r=calloc(1,sizeof(*r));
    if (!info || !r) { free(r); png_destroy_read_struct(&png,&info,NULL); return nil; }
    if (setjmp(png_jmpbuf(png))) {
        free(r->rows); free(r->pixels); free(r); png_destroy_read_struct(&png,&info,NULL); return nil;
    }
    r->data=data.bytes; r->size=data.length;
    png_set_read_fn(png,r,pngRead); png_set_user_limits(png,100000,100000);
    png_read_info(png,info);
    *width=png_get_image_width(png,info); *height=png_get_image_height(png,info);
    // Bound memory before allocation, fail closed rather than silently weakening verification.
    if (!*width || !*height || *width > (256*1024*1024ULL)/8 / *height) png_error(png,"Image exceeds validation memory limit");
    int color=png_get_color_type(png,info);
    BOOL alpha=(color&PNG_COLOR_MASK_ALPHA) || png_get_valid(png,info,PNG_INFO_tRNS);
    png_set_expand(png); png_set_expand_16(png);
    if (!(color&PNG_COLOR_MASK_COLOR)) png_set_gray_to_rgb(png);
    if (!alpha) png_set_add_alpha(png,65535,PNG_FILLER_AFTER);
    png_set_interlace_handling(png); png_read_update_info(png,info);
    size_t rowBytes=png_get_rowbytes(png,info);
    if (png_get_bit_depth(png,info)!=16 || rowBytes!=*width*8) png_error(png,"Unexpected decoded layout");
    r->pixels=malloc(rowBytes * *height); r->rows=malloc(sizeof(png_bytep) * *height);
    if (!r->pixels || !r->rows) png_error(png,"Out of memory");
    for (size_t y=0;y<*height;y++) r->rows[y]=r->pixels+y*rowBytes;
    png_read_image(png,r->rows); png_read_end(png,info);
    NSData *pixels=[NSData dataWithBytesNoCopy:r->pixels length:rowBytes * *height freeWhenDone:YES];
    free(r->rows); free(r); png_destroy_read_struct(&png,&info,NULL); return pixels;
}
static NSData *jpegPixels(NSData *data, size_t *width, size_t *height) {
    CGImageSourceRef source=CGImageSourceCreateWithData((__bridge CFDataRef)data,NULL);
    if (!source) return nil;
    NSDictionary *properties=CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source,0,NULL));
    size_t declaredWidth=[properties[(id)kCGImagePropertyPixelWidth] unsignedLongLongValue];
    size_t declaredHeight=[properties[(id)kCGImagePropertyPixelHeight] unsignedLongLongValue];
    if (!declaredWidth || !declaredHeight || declaredWidth>(256*1024*1024ULL)/4/declaredHeight) {
        CFRelease(source); return nil;
    }
    CGImageRef image=CGImageSourceCreateImageAtIndex(source,0,(__bridge CFDictionaryRef)@{(id)kCGImageSourceShouldCache:@YES});
    CFRelease(source); if (!image) return nil;
    *width=CGImageGetWidth(image); *height=CGImageGetHeight(image);
    NSData *result=nil;
    if (*width && *height && *width<=(256*1024*1024ULL)/4 / *height) {
        // A fixed destination colour space/decoder for both JPEGs, independent of metadata removal.
        CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB();
        CGImageRef untagged=CGImageCreateCopyWithColorSpace(image,space);
        NSMutableData *pixels=[NSMutableData dataWithLength:*width * *height * 4];
        CGContextRef ctx=CGBitmapContextCreate(pixels.mutableBytes,*width,*height,8,*width*4,space,kCGImageAlphaNoneSkipLast|kCGBitmapByteOrder32Big);
        if (ctx && untagged) { CGContextDrawImage(ctx,CGRectMake(0,0,*width,*height),untagged); result=pixels; }
        if (ctx) CGContextRelease(ctx); if (untagged) CGImageRelease(untagged); CGColorSpaceRelease(space);
    }
    CGImageRelease(image); return result;
}
static BOOL validateUnlocked(NSData *original, NSData *candidate, BOOL lossless, BOOL keepMetadata, NSError **error) {
    BOOL png=isPNG(original);
    if (png!=isPNG(candidate)) return fail(error,@"Candidate changed the image format.");
    NSDictionary *a=png?pngMetadata(original):jpegMetadata(original);
    NSDictionary *b=png?pngMetadata(candidate):jpegMetadata(candidate);
    if (!a || !b) return fail(error,@"Invalid, truncated, or animated image; original kept.");
    if (keepMetadata && ![a isEqual:b]) return fail(error,@"Candidate rejected: protected metadata changed.");
    size_t aw=0,ah=0,bw=0,bh=0;
    NSData *ap=png?pngPixels(original,&aw,&ah):jpegPixels(original,&aw,&ah);
    NSData *bp=png?pngPixels(candidate,&bw,&bh):jpegPixels(candidate,&bw,&bh);
    if (!ap || !bp) return fail(error,@"Image could not be fully validated (limit: 256 MB decoded per image).");
    if (aw!=bw || ah!=bh) return fail(error,@"Candidate changed image dimensions.");
    if (lossless && ![ap isEqual:bp]) return fail(error,@"Candidate rejected: decoded pixels changed.");
    return YES;
}
BOOL PWValidateImage(NSData *original, NSData *candidate, BOOL lossless, BOOL keepMetadata, NSError **error) {
    // Bound simultaneous decoded buffers to two images (512 MB total), across all workers.
    @synchronized([PWJob class]) { return validateUnlocked(original,candidate,lossless,keepMetadata,error); }
}
