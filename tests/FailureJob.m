#import "Checks-Bridging-Header.h"
#import "Workers/CommandWorker.h"
@implementation PWFailingTrashJob
- (BOOL)trashOriginalAtURL:(NSURL *)url resultingURL:(NSURL **)result error:(NSError **)error {
    if (error) *error=[NSError errorWithDomain:@"Test" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Simulated Trash failure"}];
    return NO;
}
@end
void PWProbeEngineFailure(PWJob *job) {
    CommandWorker *worker=[[CommandWorker alloc] initWithFile:job];
    [worker taskWithPath:@"/usr/bin/false" arguments:@[]];
    [worker launchTask]; [worker waitUntilTaskExit];
}
