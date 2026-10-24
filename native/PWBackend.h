#import <Foundation/Foundation.h>
#import "Job.h"

NS_ASSUME_NONNULL_BEGIN
// Signatures include identity, timestamps and SHA-256, but not the path (renames are safe).
NSString * _Nullable PWFileSignature(NSURL *url, NSError **error);
NSString * _Nullable PWFileIdentity(NSURL *url);
BOOL PWMoveExclusive(NSURL *from, NSURL *to, NSError **error);
BOOL PWValidateImage(NSData *original, NSData *candidate, BOOL lossless, BOOL keepMetadata, NSError **error);

@interface PWJob : Job
- (instancetype)initWithURL:(NSURL *)url;
@property (readonly) BOOL hasSavedOutput;
@property (atomic, readonly) BOOL savedInBatch, wasStarted;
@property (atomic, readonly, nullable) NSString *committedSignature;
@property (readonly, nullable) NSNumber *savingsPercent;
@property (atomic, nullable) NSString *expectedUserSignature;
@property (atomic, readonly, nullable) NSString *validationNote;
@property (atomic, readonly, nullable) NSString *recoveryNote;
- (BOOL)prepareWithDefaults:(NSUserDefaults *)defaults error:(NSError **)error;
- (BOOL)restoreWithError:(NSError **)error;
// Overridable file-system boundary, used by the failure-injection acceptance check.
- (BOOL)trashOriginalAtURL:(NSURL *)url resultingURL:(NSURL * _Nullable * _Nullable)result error:(NSError **)error;
@end

@interface PWCompression : NSObject
- (void)startJobs:(NSArray<PWJob *> *)jobs defaults:(NSUserDefaults *)defaults completion:(void (^)(void))completion;
- (void)stop;
@end
NS_ASSUME_NONNULL_END
