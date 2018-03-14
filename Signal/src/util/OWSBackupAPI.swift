//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

import Foundation
import SignalServiceKit
import CloudKit

@objc public class OWSBackupAPI: NSObject {

    // If we change the record types, we need to ensure indices
    // are configured properly in the CloudKit dashboard.
    static let signalBackupRecordType = "signalBackup"
    static let manifestRecordName = "manifest"
    static let payloadKey = "payload"
    static let maxRetries = 5

    private class func recordIdForTest() -> String {
        return "test-\(NSUUID().uuidString)"
    }

    private class func database() -> CKDatabase {
        let myContainer = CKContainer.default()
        let privateDatabase = myContainer.privateCloudDatabase
        return privateDatabase
    }

    private class func invalidServiceResponseError() -> Error {
        return OWSErrorWithCodeDescription(.backupFailure,
                                           NSLocalizedString("BACKUP_EXPORT_ERROR_INVALID_CLOUDKIT_RESPONSE",
                                                             comment: "Error indicating that the app received an invalid response from CloudKit."))
    }

    // MARK: - Upload

    @objc
    public class func saveTestFileToCloud(fileUrl: URL,
                                          success: @escaping (String) -> Swift.Void,
                                          failure: @escaping (Error) -> Swift.Void) {
        saveFileToCloud(fileUrl: fileUrl,
                        recordName: NSUUID().uuidString,
                        recordType: signalBackupRecordType,
                        success: success,
                        failure: failure)
    }

    // "Ephemeral" files are specific to this backup export and will always need to
    // be saved.  For example, a complete image of the database is exported each time.
    // We wouldn't want to overwrite previous images until the entire backup export is
    // complete.
    @objc
    public class func saveEphemeralDatabaseFileToCloud(fileUrl: URL,
                                                       success: @escaping (String) -> Swift.Void,
                                                       failure: @escaping (Error) -> Swift.Void) {
        saveFileToCloud(fileUrl: fileUrl,
                        recordName: "ephemeralFile-\(NSUUID().uuidString)",
            recordType: signalBackupRecordType,
            success: success,
            failure: failure)
    }

    // "Persistent" files may be shared between backup export; they should only be saved
    // once.  For example, attachment files should only be uploaded once.  Subsequent
    // backups can reuse the same record.
    @objc
    public class func savePersistentFileOnceToCloud(fileId: String,
                                                    fileUrlBlock: @escaping (Swift.Void) -> URL?,
                                                    success: @escaping (String) -> Swift.Void,
                                                    failure: @escaping (Error) -> Swift.Void) {
        saveFileOnceToCloud(recordName: "persistentFile-\(fileId)",
            recordType: signalBackupRecordType,
            fileUrlBlock: fileUrlBlock,
            success: success,
            failure: failure)
    }

    @objc
    public class func upsertManifestFileToCloud(fileUrl: URL,
                                                success: @escaping (String) -> Swift.Void,
                                                failure: @escaping (Error) -> Swift.Void) {
        // We want to use a well-known record id and type for manifest files.
        upsertFileToCloud(fileUrl: fileUrl,
                          recordName: manifestRecordName,
                          recordType: signalBackupRecordType,
                          success: success,
                          failure: failure)
    }

    @objc
    public class func saveFileToCloud(fileUrl: URL,
                                      recordName: String,
                                      recordType: String,
                                      success: @escaping (String) -> Swift.Void,
                                      failure: @escaping (Error) -> Swift.Void) {
        let recordID = CKRecordID(recordName: recordName)
        let record = CKRecord(recordType: recordType, recordID: recordID)
        let asset = CKAsset(fileURL: fileUrl)
        record[payloadKey] = asset

        saveRecordToCloud(record: record,
                          success: success,
                          failure: failure)
    }

    @objc
    public class func saveRecordToCloud(record: CKRecord,
                                        success: @escaping (String) -> Swift.Void,
                                        failure: @escaping (Error) -> Swift.Void) {
        saveRecordToCloud(record: record,
                          remainingRetries: maxRetries,
                          success: success,
                          failure: failure)
    }

    private class func saveRecordToCloud(record: CKRecord,
                                         remainingRetries: Int,
                                         success: @escaping (String) -> Swift.Void,
                                         failure: @escaping (Error) -> Swift.Void) {

        database().save(record) {
            (_, error) in

            let response = responseForCloudKitError(error: error,
                                                    remainingRetries: remainingRetries,
                                                    label: "Save Record")
            switch response {
            case .success:
                let recordName = record.recordID.recordName
                success(recordName)
            case .failureDoNotRetry(let responseError):
                failure(responseError)
            case .failureRetryAfterDelay(let retryDelay):
                DispatchQueue.global().asyncAfter(deadline: DispatchTime.now() + retryDelay, execute: {
                    saveRecordToCloud(record: record,
                                      remainingRetries: remainingRetries - 1,
                                      success: success,
                                      failure: failure)
                })
            case .failureRetryWithoutDelay:
                DispatchQueue.global().async {
                    saveRecordToCloud(record: record,
                                      remainingRetries: remainingRetries - 1,
                                      success: success,
                                      failure: failure)
                }
            case .unknownItem:
                owsFail("\(self.logTag) unexpected CloudKit response.")
                failure(invalidServiceResponseError())
            }
        }
    }

    // Compare:
    // * An "upsert" creates a new record if none exists and
    //   or updates if there is an existing record.
    // * A "save once" creates a new record if none exists and
    //   does nothing if there is an existing record.
    @objc
    public class func upsertFileToCloud(fileUrl: URL,
                                        recordName: String,
                                        recordType: String,
                                        success: @escaping (String) -> Swift.Void,
                                        failure: @escaping (Error) -> Swift.Void) {

        checkForFileInCloud(recordName: recordName,
                            remainingRetries: maxRetries,
                            success: { (record) in
                                if let record = record {
                                    // Record found, updating existing record.
                                    let asset = CKAsset(fileURL: fileUrl)
                                    record[payloadKey] = asset
                                    saveRecordToCloud(record: record,
                                                      success: success,
                                                      failure: failure)
                                } else {
                                    // No record found, saving new record.
                                    saveFileToCloud(fileUrl: fileUrl,
                                                    recordName: recordName,
                                                    recordType: recordType,
                                                    success: success,
                                                    failure: failure)
                                }
        },
                            failure: failure)
    }

    // Compare:
    // * An "upsert" creates a new record if none exists and
    //   or updates if there is an existing record.
    // * A "save once" creates a new record if none exists and
    //   does nothing if there is an existing record.
    @objc
    public class func saveFileOnceToCloud(recordName: String,
                                          recordType: String,
                                          fileUrlBlock: @escaping (Swift.Void) -> URL?,
                                          success: @escaping (String) -> Swift.Void,
                                          failure: @escaping (Error) -> Swift.Void) {

        checkForFileInCloud(recordName: recordName,
                            remainingRetries: maxRetries,
                            success: { (record) in
                                if record != nil {
                                    // Record found, skipping save.
                                    success(recordName)
                                } else {
                                    // No record found, saving new record.
                                    guard let fileUrl = fileUrlBlock() else {
                                        Logger.error("\(self.logTag) error preparing file for upload.")
                                        failure(OWSErrorWithCodeDescription(.exportBackupError,
                                                                            NSLocalizedString("BACKUP_EXPORT_ERROR_SAVE_FILE_TO_CLOUD_FAILED",
                                                                                              comment: "Error indicating the a backup export failed to save a file to the cloud.")))
                                        return
                                    }

                                    saveFileToCloud(fileUrl: fileUrl,
                                                    recordName: recordName,
                                                    recordType: recordType,
                                                    success: success,
                                                    failure: failure)
                                }
        },
                            failure: failure)
    }

    // MARK: - Delete

    @objc
    public class func deleteRecordFromCloud(recordName: String,
                                            success: @escaping (Swift.Void) -> Swift.Void,
                                            failure: @escaping (Error) -> Swift.Void) {
        deleteRecordFromCloud(recordName: recordName,
                              remainingRetries: maxRetries,
                              success: success,
                              failure: failure)
    }

    private class func deleteRecordFromCloud(recordName: String,
                                             remainingRetries: Int,
                                             success: @escaping (Swift.Void) -> Swift.Void,
                                             failure: @escaping (Error) -> Swift.Void) {

        let recordID = CKRecordID(recordName: recordName)

        database().delete(withRecordID: recordID) {
            (_, error) in

            let response = responseForCloudKitError(error: error,
                                                    remainingRetries: remainingRetries,
                                                    label: "Delete Record")
            switch response {
            case .success:
                success()
            case .failureDoNotRetry(let responseError):
                failure(responseError)
            case .failureRetryAfterDelay(let retryDelay):
                DispatchQueue.global().asyncAfter(deadline: DispatchTime.now() + retryDelay, execute: {
                    deleteRecordFromCloud(recordName: recordName,
                                          remainingRetries: remainingRetries - 1,
                                          success: success,
                                          failure: failure)
                })
            case .failureRetryWithoutDelay:
                DispatchQueue.global().async {
                    deleteRecordFromCloud(recordName: recordName,
                                          remainingRetries: remainingRetries - 1,
                                          success: success,
                                          failure: failure)
                }
            case .unknownItem:
                owsFail("\(self.logTag) unexpected CloudKit response.")
                failure(invalidServiceResponseError())
            }
        }
    }

    // MARK: - Exists?

    private class func checkForFileInCloud(recordName: String,
                                           remainingRetries: Int,
                                           success: @escaping (CKRecord?) -> Swift.Void,
                                           failure: @escaping (Error) -> Swift.Void) {
        let recordId = CKRecordID(recordName: recordName)
        let fetchOperation = CKFetchRecordsOperation(recordIDs: [recordId ])
        // Don't download the file; we're just using the fetch to check whether or
        // not this record already exists.
        fetchOperation.desiredKeys = []
        fetchOperation.perRecordCompletionBlock = { (record, recordId, error) in

            let response = responseForCloudKitError(error: error,
                                                    remainingRetries: remainingRetries,
                                                    label: "Check for Record")
            switch response {
            case .success:
                guard let record = record else {
                    owsFail("\(self.logTag) missing fetching record.")
                    failure(invalidServiceResponseError())
                    return
                }
                // Record found.
                success(record)
            case .failureDoNotRetry(let responseError):
                failure(responseError)
            case .failureRetryAfterDelay(let retryDelay):
                DispatchQueue.global().asyncAfter(deadline: DispatchTime.now() + retryDelay, execute: {
                    checkForFileInCloud(recordName: recordName,
                                        remainingRetries: remainingRetries - 1,
                                        success: success,
                                        failure: failure)
                })
            case .failureRetryWithoutDelay:
                DispatchQueue.global().async {
                    checkForFileInCloud(recordName: recordName,
                                        remainingRetries: remainingRetries - 1,
                                        success: success,
                                        failure: failure)
                }
            case .unknownItem:
                // Record not found.
                success(nil)
            }
        }
        database().add(fetchOperation)
    }

    @objc
    public class func checkForManifestInCloud(success: @escaping (Bool) -> Swift.Void,
                                              failure: @escaping (Error) -> Swift.Void) {

        checkForFileInCloud(recordName: manifestRecordName,
                            remainingRetries: maxRetries,
                            success: { (record) in
                                success(record != nil)
        },
                            failure: failure)
    }

    @objc
    public class func fetchAllRecordNames(success: @escaping ([String]) -> Swift.Void,
                                          failure: @escaping (Error) -> Swift.Void) {

        let query = CKQuery(recordType: signalBackupRecordType, predicate: NSPredicate(value: true))
        // Fetch the first page of results for this query.
        fetchAllRecordNamesStep(query: query,
                                previousRecordNames: [String](),
                                cursor: nil,
                                remainingRetries: maxRetries,
                                success: success,
                                failure: failure)
    }

    private class func fetchAllRecordNamesStep(query: CKQuery,
                                               previousRecordNames: [String],
                                               cursor: CKQueryCursor?,
                                               remainingRetries: Int,
                                               success: @escaping ([String]) -> Swift.Void,
                                               failure: @escaping (Error) -> Swift.Void) {

        var allRecordNames = previousRecordNames

        let queryOperation = CKQueryOperation(query: query)
        // If this isn't the first page of results for this query, resume
        // where we left off.
        queryOperation.cursor = cursor
        // Don't download the file; we're just using the query to get a list of record names.
        queryOperation.desiredKeys = []
        queryOperation.recordFetchedBlock = { (record) in
            assert(record.recordID.recordName.count > 0)
            allRecordNames.append(record.recordID.recordName)
        }
        queryOperation.queryCompletionBlock = { (cursor, error) in

            let response = responseForCloudKitError(error: error,
                                                    remainingRetries: remainingRetries,
                                                    label: "Fetch All Records")
            switch response {
            case .success:
                if let cursor = cursor {
                    Logger.verbose("\(self.logTag) fetching more record names \(allRecordNames.count).")
                    // There are more pages of results, continue fetching.
                    fetchAllRecordNamesStep(query: query,
                                            previousRecordNames: allRecordNames,
                                            cursor: cursor,
                                            remainingRetries: maxRetries,
                                            success: success,
                                            failure: failure)
                    return
                }
                Logger.info("\(self.logTag) fetched \(allRecordNames.count) record names.")
                success(allRecordNames)
            case .failureDoNotRetry(let responseError):
                failure(responseError)
            case .failureRetryAfterDelay(let retryDelay):
                DispatchQueue.global().asyncAfter(deadline: DispatchTime.now() + retryDelay, execute: {
                    fetchAllRecordNamesStep(query: query,
                                            previousRecordNames: allRecordNames,
                                            cursor: cursor,
                                            remainingRetries: remainingRetries - 1,
                                            success: success,
                                            failure: failure)
                })
            case .failureRetryWithoutDelay:
                DispatchQueue.global().async {
                    fetchAllRecordNamesStep(query: query,
                                            previousRecordNames: allRecordNames,
                                            cursor: cursor,
                                            remainingRetries: remainingRetries - 1,
                                            success: success,
                                            failure: failure)
                }
            case .unknownItem:
                owsFail("\(self.logTag) unexpected CloudKit response.")
                failure(invalidServiceResponseError())
            }
        }
        database().add(queryOperation)
    }

    // MARK: - Download

    @objc
    public class func downloadManifestFromCloud(
        success: @escaping (Data) -> Swift.Void,
        failure: @escaping (Error) -> Swift.Void) {
        downloadDataFromCloud(recordName: manifestRecordName,
                              success: success,
                              failure: failure)
    }

    @objc
    public class func downloadDataFromCloud(recordName: String,
                                            success: @escaping (Data) -> Swift.Void,
                                            failure: @escaping (Error) -> Swift.Void) {

        downloadFromCloud(recordName: recordName,
                          remainingRetries: maxRetries,
                          success: { (asset) in
                            DispatchQueue.global().async {
                                do {
                                    let data = try Data(contentsOf: asset.fileURL)
                                    success(data)
                                } catch {
                                    Logger.error("\(self.logTag) couldn't load asset file: \(error).")
                                    failure(invalidServiceResponseError())
                                }
                            }
        },
                          failure: failure)
    }

    @objc
    public class func downloadFileFromCloud(recordName: String,
                                            toFileUrl: URL,
                                            success: @escaping (Swift.Void) -> Swift.Void,
                                            failure: @escaping (Error) -> Swift.Void) {

        downloadFromCloud(recordName: recordName,
                          remainingRetries: maxRetries,
                          success: { (asset) in
                            DispatchQueue.global().async {
                                do {
                                    try FileManager.default.copyItem(at: asset.fileURL, to: toFileUrl)
                                    success()
                                } catch {
                                    Logger.error("\(self.logTag) couldn't copy asset file: \(error).")
                                    failure(invalidServiceResponseError())
                                }
                            }
        },
                          failure: failure)
    }

    // We return the CKAsset and not its fileUrl because
    // CloudKit offers no guarantees around how long it'll
    // keep around the underlying file.  Presumably we can
    // defer cleanup by maintaining a strong reference to
    // the asset.
    private class func downloadFromCloud(recordName: String,
                                         remainingRetries: Int,
                                         success: @escaping (CKAsset) -> Swift.Void,
                                         failure: @escaping (Error) -> Swift.Void) {

        let recordId = CKRecordID(recordName: recordName)
        let fetchOperation = CKFetchRecordsOperation(recordIDs: [recordId ])
        // Download all keys for this record.
        fetchOperation.perRecordCompletionBlock = { (record, recordId, error) in

            let response = responseForCloudKitError(error: error,
                                                    remainingRetries: remainingRetries,
                                                    label: "Download Record")
            switch response {
            case .success:
                guard let record = record else {
                    Logger.error("\(self.logTag) missing fetching record.")
                    failure(invalidServiceResponseError())
                    return
                }
                guard let asset = record[payloadKey] as? CKAsset else {
                    Logger.error("\(self.logTag) record missing payload.")
                    failure(invalidServiceResponseError())
                    return
                }
                success(asset)
            case .failureDoNotRetry(let responseError):
                failure(responseError)
            case .failureRetryAfterDelay(let retryDelay):
                DispatchQueue.global().asyncAfter(deadline: DispatchTime.now() + retryDelay, execute: {
                    downloadFromCloud(recordName: recordName,
                                      remainingRetries: remainingRetries - 1,
                                      success: success,
                                      failure: failure)
                })
            case .failureRetryWithoutDelay:
                DispatchQueue.global().async {
                    downloadFromCloud(recordName: recordName,
                                      remainingRetries: remainingRetries - 1,
                                      success: success,
                                      failure: failure)
                }
            case .unknownItem:
                Logger.error("\(self.logTag) missing fetching record.")
                failure(invalidServiceResponseError())
            }
        }
        database().add(fetchOperation)
    }

    // MARK: - Access

    @objc
    public class func checkCloudKitAccess(completion: @escaping (Bool) -> Swift.Void) {
        CKContainer.default().accountStatus(completionHandler: { (accountStatus, error) in
            DispatchQueue.main.async {
                switch accountStatus {
                case .couldNotDetermine:
                    Logger.error("\(self.logTag) could not determine CloudKit account status:\(String(describing: error)).")
                    OWSAlerts.showErrorAlert(message: NSLocalizedString("CLOUDKIT_STATUS_COULD_NOT_DETERMINE", comment: "Error indicating that the app could not determine that user's CloudKit account status"))
                    completion(false)
                case .noAccount:
                    Logger.error("\(self.logTag) no CloudKit account.")
                    OWSAlerts.showErrorAlert(message: NSLocalizedString("CLOUDKIT_STATUS_NO_ACCOUNT", comment: "Error indicating that user does not have an iCloud account."))
                    completion(false)
                case .restricted:
                    Logger.error("\(self.logTag) restricted CloudKit account.")
                    OWSAlerts.showErrorAlert(message: NSLocalizedString("CLOUDKIT_STATUS_RESTRICTED", comment: "Error indicating that the app was prevented from accessing the user's CloudKit account."))
                    completion(false)
                case .available:
                    completion(true)
                }
            }
        })
    }

    // MARK: - Retry

    private enum CKErrorResponse {
        case success
        case failureDoNotRetry(error:Error)
        case failureRetryAfterDelay(retryDelay: Double)
        case failureRetryWithoutDelay
        // This only applies to fetches.
        case unknownItem
    }

    private class func responseForCloudKitError(error: Error?,
                                                remainingRetries: Int,
                                                label: String) -> CKErrorResponse {
        if let error = error as? CKError {
            if error.code == CKError.unknownItem {
                // This is not always an error for our purposes.
                Logger.verbose("\(self.logTag) \(label) unknown item.")
                return .unknownItem
            }

            Logger.error("\(self.logTag) \(label) failed: \(error)")

            if remainingRetries < 1 {
                Logger.verbose("\(self.logTag) \(label) no more retries.")
                return .failureDoNotRetry(error:error)
            }

            if #available(iOS 11, *) {
                if error.code == CKError.serverResponseLost {
                    Logger.verbose("\(self.logTag) \(label) retry without delay.")
                    return .failureRetryWithoutDelay
                }
            }

            switch error {
            case CKError.requestRateLimited, CKError.serviceUnavailable, CKError.zoneBusy:
                let retryDelay = error.retryAfterSeconds ?? 3.0
                Logger.verbose("\(self.logTag) \(label) retry with delay: \(retryDelay).")
                return .failureRetryAfterDelay(retryDelay:retryDelay)
            case CKError.networkFailure:
                Logger.verbose("\(self.logTag) \(label) retry without delay.")
                return .failureRetryWithoutDelay
            default:
                Logger.verbose("\(self.logTag) \(label) unknown CKError.")
                return .failureDoNotRetry(error:error)
            }
        } else if let error = error {
            Logger.error("\(self.logTag) \(label) failed: \(error)")
            if remainingRetries < 1 {
                Logger.verbose("\(self.logTag) \(label) no more retries.")
                return .failureDoNotRetry(error:error)
            }
            Logger.verbose("\(self.logTag) \(label) unknown error.")
            return .failureDoNotRetry(error:error)
        } else {
            Logger.info("\(self.logTag) \(label) succeeded.")
            return .success
        }
    }
}
