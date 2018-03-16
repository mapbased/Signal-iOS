//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import <YapDatabase/YapDatabaseConnection.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const StorageIsReadyNotification;

@class YapDatabaseExtension;

@protocol OWSDatabaseConnectionDelegate <NSObject>

- (BOOL)areAllRegistrationsComplete;

@end

#pragma mark -

@interface OWSDatabaseConnection : YapDatabaseConnection

@property (atomic, weak) id<OWSDatabaseConnectionDelegate> delegate;

#ifdef DEBUG
@property (atomic) BOOL canWriteBeforeStorageReady;
#endif

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithDatabase:(YapDatabase *)database
                        delegate:(id<OWSDatabaseConnectionDelegate>)delegate NS_DESIGNATED_INITIALIZER;

@end

#pragma mark -

@interface OWSStorage : NSObject

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initStorage NS_DESIGNATED_INITIALIZER;

// Returns YES if _ALL_ storage classes have completed both their
// sync _AND_ async view registrations.
+ (BOOL)isStorageReady;

// This object can be used to filter database notifications.
@property (nonatomic, readonly, nullable) id dbNotificationObject;

+ (void)setupStorage;

+ (void)resetAllStorage;

- (YapDatabaseConnection *)newDatabaseConnection;

#ifdef DEBUG
- (BOOL)registerExtension:(YapDatabaseExtension *)extension withName:(NSString *)extensionName;
#endif

- (void)asyncRegisterExtension:(YapDatabaseExtension *)extension withName:(NSString *)extensionName;

- (nullable id)registeredExtension:(NSString *)extensionName;

- (unsigned long long)databaseFileSize;
- (unsigned long long)databaseWALFileSize;
- (unsigned long long)databaseSHMFileSize;

- (YapDatabaseConnection *)registrationConnection;

#pragma mark - Password

/**
 * Returns NO if:
 *
 * - Keychain is locked because device has just been restarted.
 * - Password could not be retrieved because of a keychain error.
 */
+ (BOOL)isDatabasePasswordAccessible;

+ (nullable NSData *)tryToLoadDatabaseLegacyPassphrase:(NSError **)errorHandle;
+ (void)removeLegacyPassphrase;

+ (void)storeDatabaseCipherKeySpec:(NSData *)cipherKeySpecData;

- (void)logFileSizes;

@end

NS_ASSUME_NONNULL_END
