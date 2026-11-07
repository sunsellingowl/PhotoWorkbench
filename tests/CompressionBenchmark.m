#import "PWBackend.h"
#import <sys/resource.h>

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *mode=@(argv[2]);
        NSURL *fixture=[NSURL fileURLWithPath:@(argv[1])];
        NSFileManager *fm=NSFileManager.defaultManager;
        NSURL *root=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[@"PhotoWorkbench-bench-" stringByAppendingString:NSUUID.UUID.UUIDString]]];
        [fm createDirectoryAtURL:root withIntermediateDirectories:NO attributes:nil error:NULL];
        NSUserDefaults *defaults=[[NSUserDefaults alloc] initWithSuiteName:[@"local.cc.PhotoWorkbench.benchmark." stringByAppendingString:NSUUID.UUID.UUIDString]];
        [defaults registerDefaults:[NSDictionary dictionaryWithContentsOfFile:[NSBundle.mainBundle pathForResource:@"defaults" ofType:@"plist"]]];
        [defaults registerDefaults:@{@"LossyEnabled":@NO,@"AdvPngLevel":[mode isEqual:@"deep"]?@4:@2,
            @"OptiPngEnabled":@YES,@"PngOutEnabled":@([mode isEqual:@"deep"]),@"ZopfliEnabled":@([mode isEqual:@"deep"]),
            @"AdvPngEnabled":@NO,@"PngCrush2Enabled":@NO,@"PngOutRemoveChunks":@NO,
            @"PreserveDates":@YES,@"PreservePermissions":@YES,@"RunLowPriority":@NO,@"GuetzliEnabled":@NO}];
        NSMutableArray<PWJob *> *jobs=[NSMutableArray new];
        for (int i=0;i<4;i++) {
            NSURL *url=[root URLByAppendingPathComponent:[NSString stringWithFormat:@"image_%d.png",i]];
            if (![fm copyItemAtURL:fixture toURL:url error:NULL]) return 2;
            PWJob *job=[[PWJob alloc] initWithURL:url];
            if (![job prepareWithDefaults:defaults error:NULL]) return 3;
            [jobs addObject:job];
        }
        NSDate *start=NSDate.date;
        PWCompression *backend=[PWCompression new]; __block BOOL done=NO;
        [backend startJobs:jobs defaults:defaults completion:^{done=YES;}];
        while (!done && -start.timeIntervalSinceNow<150) [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
        if (!done) { [backend stop]; return 4; }
        NSUInteger bytes=0;
        for (PWJob *job in jobs) {
            if (job.isFailed) return 5;
            bytes+=[fm attributesOfItemAtPath:job.filePath.path error:NULL].fileSize;
            NSURL *backup=[job valueForKey:@"restoreURL"];
            if (backup) [fm removeItemAtURL:backup error:NULL];
        }
        struct rusage parent,child; getrusage(RUSAGE_SELF,&parent);getrusage(RUSAGE_CHILDREN,&child);
        double cpu=parent.ru_utime.tv_sec+parent.ru_utime.tv_usec/1e6+parent.ru_stime.tv_sec+parent.ru_stime.tv_usec/1e6+
            child.ru_utime.tv_sec+child.ru_utime.tv_usec/1e6+child.ru_stime.tv_sec+child.ru_stime.tv_usec/1e6;
        NSDictionary *report=@{@"mode":mode,@"images":@4,@"seconds":@(-start.timeIntervalSinceNow),@"cpuSeconds":@(cpu),@"outputBytes":@(bytes)};
        NSData *json=[NSJSONSerialization dataWithJSONObject:report options:0 error:NULL];
        puts([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
        [fm removeItemAtURL:root error:NULL];
    }
}
