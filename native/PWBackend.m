#import "PWBackend.h"
#import "File.h"
#import "TempFile.h"
#import "JobQueue.h"
#import <fcntl.h>
#import <sys/stat.h>
#import <unistd.h>

int hideLogs = 1;
@interface Job (Saving)
- (BOOL)saveResult;
- (void)setSavedOutput:(File *)file;
- (void)setFileOptimized:(File *)file;
- (void)setNewFileInitial:(File *)file;
- (void)saveResultAndUpdateStatus;
@end
static NSError *PWError(NSString *text) {
    return [NSError errorWithDomain:@"PhotoWorkbench" code:2 userInfo:@{NSLocalizedDescriptionKey:text}];
}
static BOOL matches(NSURL *url, NSString *signature) { return signature && [PWFileSignature(url,NULL) isEqual:signature]; }
static BOOL swap(NSURL *a, NSURL *b) {
    return renameatx_np(AT_FDCWD,a.fileSystemRepresentation,AT_FDCWD,b.fileSystemRepresentation,RENAME_SWAP)==0;
}

@interface PWJob ()
@property (atomic, readwrite) NSString *validationNote, *recoveryNote;
@property NSData *referenceData;
@property NSString *sourceSignature, *savedSignature, *restoreSignature;
@property NSURL *restoreURL;
@property BOOL lossless, keepMetadata, keepDates, keepPermissions;
@property NSDictionary *lastSettings;
@property (atomic, readwrite) BOOL savedInBatch, wasStarted;
@end
@implementation PWJob
- (instancetype)initWithURL:(NSURL *)url { return [super initWithFilePath:url resultsDatabase:nil]; }
- (BOOL)hasSavedOutput { return self.savedOutput != nil; }
- (NSNumber *)savingsPercent { return self.percentOptimized; }
- (NSString *)committedSignature { return self.savedSignature; }
- (BOOL)prepareWithDefaults:(NSUserDefaults *)defaults error:(NSError **)error {
    self.savedInBatch=NO; self.wasStarted=NO;
    NSArray *keys=@[@"LossyEnabled",@"JpegOptimMaxQuality",@"PngMinQuality",@"AdvPngLevel",@"JpegTranStripAll",@"PngOutRemoveChunks",@"GuetzliEnabled",@"JpegOptimEnabled",@"JpegTranEnabled",@"OptiPngEnabled",@"PngOutEnabled",@"ZopfliEnabled",@"AdvPngEnabled",@"PngCrush2Enabled"];
    NSMutableDictionary *settings=[NSMutableDictionary new];
    for (NSString *key in keys) settings[key]=[defaults objectForKey:key] ?: @0;
    if (self.lastSettings && ![settings isEqual:self.lastSettings]) {
        [self.workersPreviousResults removeAllObjects];
        // Retain our own earliest Trash original, while allowing a fresh optimization after settings change.
        [self setNewFileInitial:nil];
    }
    self.lastSettings=settings;
    self.lossless=![defaults boolForKey:@"LossyEnabled"];
    BOOL png=[self.filePath.pathExtension.lowercaseString isEqualToString:@"png"];
    self.keepMetadata=![defaults boolForKey:png?@"PngOutRemoveChunks":@"JpegTranStripAll"];
    self.keepDates=[defaults boolForKey:@"PreserveDates"];
    self.keepPermissions=[defaults boolForKey:@"PreservePermissions"];
    self.validationNote=nil; self.recoveryNote=nil;
    if ([defaults boolForKey:@"GuetzliEnabled"] && !self.lossless &&
        (![defaults boolForKey:@"JpegTranStripAll"] || [defaults integerForKey:@"JpegOptimMaxQuality"]<85)) {
        if (error) *error=PWError(@"Guetzli requires JPEG metadata removal and quality of at least 85. Change these settings explicitly.");
        return NO;
    }
    if (self.savedSignature && !matches(self.filePath,self.savedSignature)) {
        if (error) *error=PWError(@"File changed outside PhotoWorkbench. Remove and add it again before compressing.");
        return NO;
    }
    return YES;
}
- (void)doEnqueueWorkersInCPUQueue:(NSOperationQueue *)queue serialQueue:(dispatch_queue_t)serialQueue defaults:(NSUserDefaults *)defaults {
    self.wasStarted=YES;
    NSError *error=nil;
    self.sourceSignature=PWFileSignature(self.filePath,&error);
    self.referenceData=[NSData dataWithContentsOfURL:self.filePath options:0 error:&error];
    const unsigned char pngSignature[]={137,80,78,71,13,10,26,10};
    BOOL actualPNG=self.referenceData.length>=8 && !memcmp(self.referenceData.bytes,pngSignature,8);
    self.keepMetadata=![defaults boolForKey:actualPNG?@"PngOutRemoveChunks":@"JpegTranStripAll"];
    struct stat st;
    if (!self.sourceSignature || (self.expectedUserSignature && ![self.expectedUserSignature isEqual:self.sourceSignature]) || !self.referenceData || !matches(self.filePath,self.sourceSignature) ||
        lstat(self.filePath.fileSystemRepresentation,&st) || !(st.st_mode & 0222) ||
        !PWValidateImage(self.referenceData,self.referenceData,YES,YES,&error)) {
        [self setError:error.localizedDescription ?: @"File is read-only or changed while being read."];
        [self cleanup]; return;
    }
    [super doEnqueueWorkersInCPUQueue:queue serialQueue:serialQueue defaults:defaults];
}
- (BOOL)setFileOptimized:(TempFile *)file toolName:(NSString *)tool {
    if (!file || file.byteSize>=self.wipInput.byteSize) return NO;
    NSError *error=nil;
    NSData *candidate=[NSData dataWithContentsOfURL:file.path options:0 error:&error];
    if (!candidate || !PWValidateImage(self.referenceData,candidate,self.lossless,self.keepMetadata,&error)) {
        self.validationNote=[NSString stringWithFormat:@"%@: %@",tool,error.localizedDescription ?: @"Invalid output"];
        return NO;
    }
    return [super setFileOptimized:file toolName:tool];
}
- (BOOL)trashOriginalAtURL:(NSURL *)url resultingURL:(NSURL **)result error:(NSError **)error {
    return [NSFileManager.defaultManager trashItemAtURL:url resultingItemURL:result error:error];
}
// Swap a complete, verified, same-volume staging file into place. The original remains available
// throughout. Neither a colliding destination nor another application's changed file is deleted.
- (BOOL)commitData:(NSData *)data attributesFrom:(NSURL *)attributesURL expected:(NSString *)expected
       keepBackup:(BOOL)keepBackup error:(NSError **)error {
    NSFileManager *fm=NSFileManager.defaultManager;
    NSURL *directory=[[self.filePath URLByDeletingLastPathComponent] URLByAppendingPathComponent:[@".PhotoWorkbench-" stringByAppendingString:NSUUID.UUID.UUIDString] isDirectory:YES];
    NSURL *stage=[directory URLByAppendingPathComponent:self.filePath.lastPathComponent];
    BOOL exchanged=NO, success=NO;
    NSString *candidateSignature=nil;
    @try {
        if (![fm createDirectoryAtURL:directory withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions:@0700} error:error]) return NO;
        if (self.keepPermissions || !keepBackup) {
            if (![fm copyItemAtURL:attributesURL toURL:stage error:error]) return NO;
            NSFileHandle *handle=[NSFileHandle fileHandleForWritingToURL:stage error:error];
            if (!handle) return NO;
            @try { [handle writeData:data]; [handle truncateFileAtOffset:data.length]; [handle synchronizeFile]; }
            @finally { [handle closeFile]; }
        } else if (![data writeToURL:stage options:NSDataWritingWithoutOverwriting error:error]) return NO;
        if (self.keepDates || !keepBackup) {
            NSDictionary *attrs=[fm attributesOfItemAtPath:attributesURL.path error:error];
            if (!attrs || ![fm setAttributes:@{NSFileModificationDate:attrs[NSFileModificationDate], NSFileCreationDate:attrs[NSFileCreationDate]} ofItemAtPath:stage.path error:error]) return NO;
        }
        candidateSignature=PWFileSignature(stage,error);
        if (!candidateSignature || !matches(self.filePath,expected)) {
            if (error) *error=PWError(@"File changed before saving; original kept."); return NO;
        }
        if (!swap(stage,self.filePath)) { if (error) *error=PWError([NSString stringWithFormat:@"Atomic replacement failed: %s",strerror(errno)]); return NO; }
        exchanged=YES;
        if (!matches(stage,expected)) { if (error) *error=PWError(@"Concurrent file change detected during replacement."); return NO; }
        if (keepBackup) {
            NSURL *trashed=nil;
            if (![self trashOriginalAtURL:stage resultingURL:&trashed error:error] || !trashed) return NO;
            // Keep the earliest original for this session; later originals also remain in Trash.
            if (!self.restoreURL) { self.restoreURL=trashed; self.restoreSignature=PWFileSignature(trashed,NULL); }
        } else {
            // Only remove our known, unmodified compressed copy after the swap succeeded.
            if (!matches(stage,expected) || ![fm removeItemAtURL:stage error:error]) return NO;
        }
        success=YES; self.savedSignature=PWFileSignature(self.filePath,error);
        return YES;
    } @catch (NSException *exception) {
        if (error) *error=PWError(exception.reason ?: @"Save failed."); return NO;
    } @finally {
        if (exchanged && !success) {
            if ([fm fileExistsAtPath:stage.path] && matches(self.filePath,candidateSignature) && swap(stage,self.filePath)) {
                exchanged=NO; // stage is now our candidate, safe to remove
            } else {
                self.recoveryNote=[NSString stringWithFormat:@"Save interrupted. Recovery files retained at %@. Check this folder before continuing.",directory.path];
            }
        }
        if (!exchanged || success) {
            // Never recursively remove an unexamined recovery folder.
            if (!exchanged) [fm removeItemAtURL:stage error:NULL];
            rmdir(directory.fileSystemRepresentation);
        }
    }
}
- (BOOL)saveResult {
    NSError *error=nil; File *output=self.wipInput;
    NSData *data=[NSData dataWithContentsOfURL:output.path options:0 error:&error];
    if (!data || !PWValidateImage(self.referenceData,data,self.lossless,self.keepMetadata,&error) ||
        ![self commitData:data attributesFrom:self.filePath expected:self.sourceSignature keepBackup:YES error:&error]) {
        self.recoveryNote=self.recoveryNote ?: error.localizedDescription;
        [self setError:self.recoveryNote ?: @"Unable to save optimized image."]; return NO;
    }
    [self.filePath removeAllCachedResourceValues];
    [self setSavedOutput:[output copyOfPath:self.filePath size:data.length]];
    self.savedInBatch=YES;
    [self setFileOptimized:nil]; return YES;
}
- (void)saveResultAndUpdateStatus {
    [super saveResultAndUpdateStatus];
    if (self.isFailed && self.savedInBatch) [self setError:@"Saved a verified smaller result, but one or more engines reported a failure."];
    self.referenceData=nil;
}
- (BOOL)canRevert { return self.restoreURL && !self.isBusy; }
- (BOOL)restoreWithError:(NSError **)error {
    if (!self.canRevert || !matches(self.filePath,self.savedSignature) || !matches(self.restoreURL,self.restoreSignature)) {
        if (error) *error=PWError(@"Restore unavailable: the current image or its Trash original is missing or has changed."); return NO;
    }
    NSData *data=[NSData dataWithContentsOfURL:self.restoreURL options:0 error:error];
    if (!data || ![self commitData:data attributesFrom:self.restoreURL expected:self.savedSignature keepBackup:NO error:error]) return NO;
    // Keep the Trash entry; consuming it would add another destructive failure point.
    self.restoreURL=nil; self.restoreSignature=nil;
    File *input=[[File alloc] initWithData:data fromPath:self.filePath];
    [self setNewFileInitial:input]; [self setFileOptimized:nil];
    [self setStatus:@"noopt" order:6 text:@"Restored original content"]; return YES;
}
- (BOOL)revert { return [self restoreWithError:NULL]; }
- (void)releaseValidationData { self.referenceData=nil; }
@end

@implementation PWCompression {
    JobQueue *_queue;
    NSArray<PWJob *> *_jobs;
    BOOL _stopped;
    NSUInteger _next;
    NSUserDefaults *_defaults;
    void (^_completion)(void);
}
- (void)startJobs:(NSArray<PWJob *> *)jobs defaults:(NSUserDefaults *)defaults completion:(void (^)(void))completion {
    NSAssert(!_queue,@"Only one batch at a time");
    _jobs=jobs; _defaults=defaults; _completion=[completion copy]; _next=0; _stopped=NO;
    [self startNext];
}
- (void)startNext {
    if (_stopped || _next>=_jobs.count) {
        void (^finished)(void)=_completion; _completion=nil; _jobs=nil; _queue=nil;
        finished(); return;
    }
    NSInteger cpus=MAX(1,NSProcessInfo.processInfo.activeProcessorCount);
    // ponytail: feed two images at a time to bound snapshots while retaining upstream worker scheduling.
    _queue=[[JobQueue alloc] initWithCPUs:cpus dirs:1 files:2 defaults:_defaults];
    NSArray<PWJob *> *jobs=[_jobs subarrayWithRange:NSMakeRange(_next,MIN(2,_jobs.count-_next))];
    _next+=jobs.count;
    for (PWJob *job in jobs) [_queue addJob:job];
    JobQueue *queue=_queue;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        [queue wait];
        for (PWJob *job in jobs) { if (!job.isDone) [job cleanup]; [job releaseValidationData]; }
        dispatch_async(dispatch_get_main_queue(), ^{ self->_queue=nil; [self startNext]; });
    });
}
- (void)stop { _stopped=YES; for (PWJob *job in _jobs) [job stop]; }
@end
