#import <Cocoa/Cocoa.h>
#import "Job.h"
#import "JobQueue.h"
#import "File.h"
int hideLogs=1;
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc!=3) return 2;
        NSFileManager *fm=NSFileManager.defaultManager;
        NSURL *fixtures=[NSURL fileURLWithPath:@(argv[1]) isDirectory:YES];
        NSURL *output=[NSURL fileURLWithPath:@(argv[2]) isDirectory:YES];
        [fm createDirectoryAtURL:output withIntermediateDirectories:YES attributes:nil error:NULL];
        NSUserDefaults *defaults=[[NSUserDefaults alloc] initWithSuiteName:[@"local.cc.PhotoWorkbench.baseline." stringByAppendingString:NSUUID.UUID.UUIDString]];
        NSMutableDictionary *settings=[[NSDictionary dictionaryWithContentsOfFile:[NSBundle.mainBundle pathForResource:@"defaults" ofType:@"plist"]] mutableCopy];
        [settings addEntriesFromDictionary:@{@"LossyEnabled":@NO,@"AdvPngLevel":@0,@"JpegTranStripAll":@NO,@"PngOutRemoveChunks":@NO,@"PreserveDates":@YES,@"PreservePermissions":@YES}];
        [defaults registerDefaults:settings];
        NSMutableArray *jobs=[NSMutableArray new];
        for (NSString *name in @[@"rgba8.png",@"rgba16.png",@"capture.JPG"]) {
            NSURL *target=[output URLByAppendingPathComponent:name];
            if ([fm fileExistsAtPath:target.path]) { fprintf(stderr,"Use an empty baseline output directory\n"); return 3; }
            NSError *err=nil;
            if (![fm copyItemAtURL:[fixtures URLByAppendingPathComponent:name] toURL:target error:&err]) { NSLog(@"%@",err); return 4; }
            [jobs addObject:[[Job alloc] initWithFilePath:target resultsDatabase:nil]];
        }
        JobQueue *queue=[[JobQueue alloc] initWithCPUs:4 dirs:1 files:2 defaults:defaults];
        for (Job *job in jobs) [queue addJob:job];
        __block BOOL done=NO;
        dispatch_async(dispatch_get_global_queue(0,0),^{ [queue wait]; dispatch_async(dispatch_get_main_queue(),^{ done=YES; }); });
        NSDate *limit=[NSDate dateWithTimeIntervalSinceNow:120];
        while (!done && limit.timeIntervalSinceNow>0) [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
        if (!done) return 5;
        NSMutableArray *results=[NSMutableArray new];
        for (Job *job in jobs) {
            if (job.isFailed) { NSLog(@"Baseline failed: %@",job); return 6; }
            [results addObject:@{@"file":job.filePath.lastPathComponent,@"originalBytes":job.byteSizeOriginal,@"optimizedBytes":job.byteSizeOptimized}];
            // All these backups are generated fixtures, never user images.
            if (job.revertFile.path) [fm removeItemAtURL:job.revertFile.path error:NULL];
        }
        NSData *json=[NSJSONSerialization dataWithJSONObject:results options:NSJSONWritingPrettyPrinted error:NULL];
        [json writeToURL:[output URLByAppendingPathComponent:@"baseline.json"] atomically:YES];
        puts([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
    }
}
