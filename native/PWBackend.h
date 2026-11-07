#import <Foundation/Foundation.h>
#import "Job.h"

NS_ASSUME_NONNULL_BEGIN
// Signatures include identity, timestamps and SHA-256, but not the path (renames are safe).
NSString * _Nullable PWFileSignature(NSURL *url, NSError **error);
NSString * _Nullable PWFileIdentity(NSURL *url);
BOOL PWMoveExclusive(NSURL *from, NSURL *to, NSError **error);
// Decode once, retain only dimensions, metadata and a digest (not a full pixel buffer).
@interface PWImageCheck : NSObject
+ (nullable instancetype)imageWithData:(NSData *)data error:(NSError **)error;
- (BOOL)matches:(PWImageCheck *)candidate lossless:(BOOL)lossless keepMetadata:(BOOL)keepMetadata error:(NSError **)error;
@end
BOOL PWValidateImage(NSData *original, NSData *candidate, BOOL lossless, BOOL keepMetadata, NSError **error);

@interface PWJob : Job
- (instancetype)initWithURL:(NSURL *)url;
@property (atomic, readonly) BOOL savedInBatch, wasStarted;
@property (atomic, readonly, nullable) NSString *committedSignature;
// 上游实际可能返回 nil，在桥接处补正可空标注，无需再包一个同义属性。
@property (readonly, nonatomic, nullable) NSNumber *percentOptimized;
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
