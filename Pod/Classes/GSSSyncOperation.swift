//
//  GSSSyncOperation.swift
//  CloudKitDemoApp
//
//  Created by Christian Gossain on 2015-11-06.
//  Copyright © 2015 Christian Gossain. All rights reserved.
//

import Foundation
import CoreData
import CloudKit

typealias GSSSyncOperationConflictResolutionBlock = (serverRecord: CKRecord, clientRecord: CKRecord, ancestorRecord: CKRecord) -> CKRecord

enum GSSSyncOperationConflictResolutionPolicy {
    case KeepServerRecord
    case KeepClientRecord
    case KeepNewerRecord
    case KeepOlderRecord
    case Custom
}

private let kPreviousServerChangeTokenKey = "kPreviousServerChangeTokenKey"

private enum GSSSyncOperationError: ErrorType {
    case FailedToSaveProcessedResults(error: NSError)
}

struct GSSFetchCursor {
    let moreComing: Bool
    let serverChangeToken: CKServerChangeToken?
}

class GSSSyncOperation: NSOperation {
    
    /// The deduplicator object to use when deduplicating the local store.
    var deduplicator: GSSContextDeduplicating?
    
    /**
     The conflict resolution policy to use when conflicts are encountered. Defaults to .KeepServerRecord
     
     If the .Custom policy is used, you must provide a -perRecordConflictResolutionBlock to resolve those conflicts. If conflicts are not resolved, the sync process will never complete.
     */
    var conflicResolutionPolicy = GSSSyncOperationConflictResolutionPolicy.KeepServerRecord
    
    /**
     This block is called once per conflicted record. Three record versions are passed to the block, the resolved record should be returned.
     
     You must apply your custom conflict resolution logic to the server record and return that record. The server record contains the updated change tag and therefore allows the resolved conflict to be saved to the server rather than conflicting again on a subsequent save attempt due to the outdated change tag.
     
     - note: This block is only called if the -conflicResolutionPolicy is set to .Custom conflict resolution policy.
     */
    var perRecordConflictResolutionBlock: GSSSyncOperationConflictResolutionBlock?
    
    private let internalQueue = NSOperationQueue()
    
    private let mainPSC: NSPersistentStoreCoordinator
    private let changeTablePSC: NSPersistentStoreCoordinator
    
    /**
     The private concurrency context representing the local cache.
     
     - note: Any changes that occur in this context are not tracked in the change table. This is what we want.
     */
    private var mainPrivateContext: NSManagedObjectContext
    private var changeTablePrivateContext: NSManagedObjectContext
    
    private var context: NSManagedObjectContext
    
    private var contextDidChangeNotificationObserver: AnyObject?
    
    // MARK: Initialization
    
    /**
    Initializes the sync operation with the specified persistent store coordinator, change table manager, and the main context.
    
    - parameters:
        - persistentStoreCoordinator: The persistent store coordinator associated with the main core data stack. The sync operation uses this coordinator to initialize a private queue context where changes received from iCloud are inserted.
        - changeTableManager: The change table manager instance used for tracking changes. The sync operation uses the manager to find local changes that need to be pushed to iCloud and to clear them once they are pushed.
        - mainContext: The main context that is being used to save and fetch data. Changes inserted into the private context are merged into this context to allow the UI to be updated accordingly (i.e. using the NSFetchedResultsController or by listening for notifications sent by this context)
    */
    init(persistentStoreCoordinator: NSPersistentStoreCoordinator, changeTableManager: GSSChangeTableManager, mainContext: NSManagedObjectContext) {
        mainPSC = persistentStoreCoordinator
        changeTablePSC = changeTableManager.persistentStoreCoordinator
        
        mainPrivateContext = NSManagedObjectContext(concurrencyType: .PrivateQueueConcurrencyType)
        mainPrivateContext.persistentStoreCoordinator = mainPSC
        
        changeTablePrivateContext = NSManagedObjectContext(concurrencyType: .PrivateQueueConcurrencyType)
        changeTablePrivateContext.persistentStoreCoordinator = changeTablePSC
        
        context = mainContext
        
        super.init()
        
        contextDidChangeNotificationObserver =
        NSNotificationCenter.defaultCenter().addObserverForName(NSManagedObjectContextDidSaveNotification, object: mainPrivateContext, queue: NSOperationQueue.mainQueue(), usingBlock: { (note) -> Void in
            self.context.mergeChangesFromContextDidSaveNotification(note)
        })
    }
    
    // MARK: - Overrides
    
    override func main() {
        /** 
         Sync will be a 2 part process.
         
         1. First we need to apply the local changes to the server.
            • If all the changes are applied successfully, we can wipe the changes table completely
         
         2. Second, we need to pull any changes available on the server and apply them locally
            • A fetch of the server changes will return a change token; if the changes are successfully processed, this token must be stored and used on a subsequent fetch.
            • And the process repeats on the next sync
         
         3. Deduplication is a reality of sync. Perhaps the deduplication routine should be run after insertsOrUpdates are processing into the local store.
        */
         
        // fetch the local changes as CKRecords
        var insertedOrUpdatedCKRecordsByRecordID = self.insertedOrUpdatedCKRecordsByRecordID()
        let deletedCKRecordIDs = self.deletedCKRecordIDs()
        
        var more = true
        var canApplyServerChanges = false
        var resolvedCKRecords = [CKRecord]() // the resolved records that are send back to the server
        
        while more {
            let insertedOrUpdatedCKRecords = Array(insertedOrUpdatedCKRecordsByRecordID.values)
            
            // try to apply local changes and handle any errors
            if let error = self.applyLocalChangesToServer(insertedOrUpdatedCKRecords, deletedCKRecodsIDs: deletedCKRecordIDs) {
                NSLog("Modify Records Error: %@", error.description)
                
                // Check for a partial failure. During an atomic operation, a partial failure indicates that in general the operation
                // succeeded, but some of the records failed. This is usually due to conflicts.
                if error.code == CKErrorCode.PartialFailure.rawValue {
                    if let partialErrorsByRecordID = error.userInfo[CKPartialErrorsByItemIDKey] as? [CKRecordID : NSError] {
                        for (recordID, recordError) in partialErrorsByRecordID {
                            if recordError.code == CKErrorCode.ServerRecordChanged.rawValue {
                                var resolvedRecord: CKRecord!
                                
                                // resolve the conflict on this record according the specified conflict resolution policy
                                switch self.conflicResolutionPolicy {
                                    
                                case .KeepServerRecord:
                                    let server = recordError.userInfo[CKRecordChangedErrorServerRecordKey] as! CKRecord
                                    
                                    resolvedRecord = server
                                    
                                case .KeepClientRecord:
                                    let server = recordError.userInfo[CKRecordChangedErrorServerRecordKey] as! CKRecord
                                    let client = recordError.userInfo[CKRecordChangedErrorClientRecordKey] as! CKRecord
                                    
                                    // Apply all the client records property values to the server record. The server record must alway 
                                    // be used as the base record to resolve conflicts, otherwise the conflict is never resolved due to 
                                    // a perpertual mismatch between the server and client record change tags
                                    let clientValuesByPropertyName = client.dictionaryWithValuesForKeys(client.allKeys())
                                    server.setValuesForKeysWithDictionary(clientValuesByPropertyName)
                                    
                                    resolvedRecord = server
                                    
                                case .KeepNewerRecord:
                                    let server = recordError.userInfo[CKRecordChangedErrorServerRecordKey] as! CKRecord
                                    let client = recordError.userInfo[CKRecordChangedErrorClientRecordKey] as! CKRecord
                                    
                                    let serverRecordModificationDate = server[GSSLocalRecordModificationDateAttributeName] as! NSDate
                                    let clientRecordModificationDate = client[GSSLocalRecordModificationDateAttributeName] as! NSDate
                                    
                                    if serverRecordModificationDate.compare(clientRecordModificationDate) == NSComparisonResult.OrderedAscending {
                                        // client record is the newer record
                                        
                                        // Apply all the client records property values to the server record. The server record must alway
                                        // be used as the base record to resolve conflicts, otherwise the conflict is never resolved due to
                                        // a perpertual mismatch between the server and client record change tags
                                        let clientValuesByPropertyName = client.dictionaryWithValuesForKeys(client.allKeys())
                                        server.setValuesForKeysWithDictionary(clientValuesByPropertyName)
                                    }
                                    
                                    resolvedRecord = server
                                    
                                case .KeepOlderRecord:
                                    let server = recordError.userInfo[CKRecordChangedErrorServerRecordKey] as! CKRecord
                                    let client = recordError.userInfo[CKRecordChangedErrorClientRecordKey] as! CKRecord
                                    
                                    let serverRecordModificationDate = server[GSSLocalRecordModificationDateAttributeName] as! NSDate
                                    let clientRecordModificationDate = client[GSSLocalRecordModificationDateAttributeName] as! NSDate
                                    
                                    if serverRecordModificationDate.compare(clientRecordModificationDate) == NSComparisonResult.OrderedDescending {
                                        // client record is the older record
                                        
                                        // Apply all the client records property values to the server record. The server record must alway
                                        // be used as the base record to resolve conflicts, otherwise the conflict is never resolved due to
                                        // a perpertual mismatch between the server and client record change tags
                                        let clientValuesByPropertyName = client.dictionaryWithValuesForKeys(client.allKeys())
                                        server.setValuesForKeysWithDictionary(clientValuesByPropertyName)
                                    }
                                    
                                    resolvedRecord = server
                                    
                                case .Custom:
                                    assert(self.perRecordConflictResolutionBlock != nil, "The 'Custom' conflict resolution policy requires the perRecordConflictResolutionBlock to be set.")
                                    
                                    let server = recordError.userInfo[CKRecordChangedErrorServerRecordKey] as! CKRecord
                                    let client = recordError.userInfo[CKRecordChangedErrorClientRecordKey] as! CKRecord
                                    let ancestor = recordError.userInfo[CKRecordChangedErrorAncestorRecordKey] as! CKRecord
                                    
                                    resolvedRecord =
                                    self.perRecordConflictResolutionBlock?(serverRecord: server, clientRecord: client, ancestorRecord: ancestor)
                                }
                                
                                // replace the record with the resolved version
                                insertedOrUpdatedCKRecordsByRecordID[recordID] = resolvedRecord
                                
                                // keep track of resolved records (they need to be saved back into the local cache)
                                resolvedCKRecords.append(resolvedRecord)
                            }
                        }
                        
                        // after resolving conflicts, we will need to try again
                        more = true
                    }
                }
                
                // TODO: Handle other possible errors
                
            }
            else {
                // no more attempts should be made; the opreation was successful
                more = false
                canApplyServerChanges = true
            }
        }
        
        // continue if the mody records operation was successful
        if canApplyServerChanges {
            // process the resolved conflicts back into the local cache
            processInsertedOrUpdatedCKRecords(resolvedCKRecords)
            
            do {
                // try to save the context
                if mainPrivateContext.hasChanges {
                    try self.mainPrivateContext.save()
                }
                
                // now perform part 2 of the syncing process
                do {
                    try applyServerChangesToLocalStore()
                } catch {
                    NSLog("ERROR APPLYING SERVER CHANGES TO LOCAL STORE: \(error)")
                }
            } catch {
                NSLog("ERROR SAVING PROCESSED CONFLICTS: \(error)")
            }
        }
    }
    
    /// Attempts to apply the records to the server, and returns conflicts that arise
    func applyLocalChangesToServer(insertedOrUpdatedCKRecords: [CKRecord], deletedCKRecodsIDs: [CKRecordID]) -> NSError? {
        var error: NSError?
        
        // apply the changed CKRecords to the server if there are any
        if insertedOrUpdatedCKRecords.count > 0 || deletedCKRecodsIDs.count > 0 {
            let modifyRecordsOperation = CKModifyRecordsOperation(recordsToSave: insertedOrUpdatedCKRecords, recordIDsToDelete: deletedCKRecodsIDs)
            modifyRecordsOperation.database = CKContainer.defaultContainer().privateCloudDatabase
            modifyRecordsOperation.modifyRecordsCompletionBlock = {(savedRecords: [CKRecord]?, deletedRecordIDs: [CKRecordID]?, operationError: NSError?) -> Void in
                if operationError != nil {
                    error = operationError
                }
                else if let saved = savedRecords, let deleted = deletedRecordIDs {
                    NSLog("COUNT OF SAVED OBJECTS: \(saved.count)")
                    for record in saved {
                        NSLog("SAVED RECORD ID: %@", record)
                    }
                    
                    NSLog("COUNT OF DELETED OBJECTS: \(deleted.count)")
                    for recordID in deleted {
                        NSLog("DELETED RECORD ID: %@", recordID)
                    }
                    
                    // the modify records operation is an atomic operation, and we applied all changes specified in the
                    // change table; therefore if it succeeds, we can remove all change entries from the change table
                    self.wipeChangeTable()
                }
            }
            internalQueue.addOperation(modifyRecordsOperation)
            internalQueue.waitUntilAllOperationsAreFinished()
        }
        return error
    }
    
    func applyServerChangesToLocalStore() throws {
        var insertedOrUpdatedCKRecords = [CKRecord]()
        var deletedCKRecodsIDs = [CKRecordID]()
        
        var previousChangeToken = previousServerChangeToken()
        var moreComing = true
        var shouldProcessServerChanges = true
        
        // fetch until there are no more results
        while moreComing {
            let result = try self.fetchRecordChangesUsingServerChangeToken(previousChangeToken)
            
            moreComing = result.cursor.moreComing
            previousChangeToken = result.cursor.serverChangeToken
            
            insertedOrUpdatedCKRecords.appendContentsOf(result.insertedOrUpdated)
            deletedCKRecodsIDs.appendContentsOf(result.deleted)
            
            // if there are no changes,there is no need to perform unneccessary work
            if insertedOrUpdatedCKRecords.count == 0 && deletedCKRecodsIDs.count == 0 {
                shouldProcessServerChanges = false
            }
        }
        
        // process the results if all changes have been pulled successfully; it is critical that any partial results that have been fetched are 
        // not processed; it is critical because if we do not have all the avaialble changes then processing partial results would be 
        // invalid since the full picture is not known
        if shouldProcessServerChanges {
            try processInsertedOrUpdatedCKRecords(insertedOrUpdatedCKRecords, deletedRecordIDs: deletedCKRecodsIDs)
            
            // It is very important to only save the server change token if the results of the delta update are successfully processed,
            // and saved. Otherwise the next delta update will start from the newer position and the changes that failed to be saved
            // are not re-downloaded leading to data that is no longer in sync.
            storeServerChangeToken(previousChangeToken)
        }
    }
    
    func fetchRecordChangesUsingServerChangeToken(serverChangeToken: CKServerChangeToken?) throws -> (insertedOrUpdated: [CKRecord], deleted: [CKRecordID], cursor: GSSFetchCursor) {
        var insertedOrUpdatedCKRecords = [CKRecord]()
        var deletedCKRecodsIDs = [CKRecordID]()
        var cursor = GSSFetchCursor(moreComing: false, serverChangeToken: serverChangeToken)
        var error: NSError?
        
        let recordZoneID = CKRecordZoneID(zoneName: GSSCloudKitSyncManagerZoneName, ownerName: CKOwnerDefaultName)
        let fetchRecordChangesOperation = CKFetchRecordChangesOperation(recordZoneID: recordZoneID, previousServerChangeToken: serverChangeToken)
        fetchRecordChangesOperation.database = CKContainer.defaultContainer().privateCloudDatabase
        
        // collect the inserts or updates for processing later
        fetchRecordChangesOperation.recordChangedBlock = { record in
            insertedOrUpdatedCKRecords.append(record)
        }
        
        // collect deleted objects for processing later
        fetchRecordChangesOperation.recordWithIDWasDeletedBlock = { deletedRecordID in
            deletedCKRecodsIDs.append(deletedRecordID)
        }
        
        // handle the error or process all the results from the delta fetch
        fetchRecordChangesOperation.fetchRecordChangesCompletionBlock = {(serverChangeToken: CKServerChangeToken?, clientChangeTokenData: NSData?, operationError: NSError?) -> Void in
            if operationError != nil {
                error = operationError
            }
            
            cursor = GSSFetchCursor(moreComing: fetchRecordChangesOperation.moreComing, serverChangeToken: serverChangeToken)
        }
        self.internalQueue.addOperation(fetchRecordChangesOperation)
        self.internalQueue.waitUntilAllOperationsAreFinished()
        
        // throw the error if one was encountered
        if error != nil {
            throw error!
        }
        else {
            return (insertedOrUpdated: insertedOrUpdatedCKRecords, deleted: deletedCKRecodsIDs, cursor: cursor)
        }
    }
    
    // MARK: - Methods (Private/ Local to Server)
    
    func insertedOrUpdatedCKRecordsByRecordID() -> [CKRecordID : CKRecord] {
        var recordsByRecordID = [CKRecordID : CKRecord]()
        var changeTableEntries = [NSManagedObject]()
        
        changeTablePrivateContext.performBlockAndWait({ () -> Void in
            let fetchRequest = NSFetchRequest(entityName: GSSChangeTableEntityName)
            
            let insertChangeType = GSSChangeTableChangeType.Insert.toNumber()
            let updateChangeType = GSSChangeTableChangeType.Update.toNumber()
            let predicate = NSPredicate(format: "%K == %@ || %K == %@", GSSLocalRecordChangeTypeAttributeName, insertChangeType, GSSLocalRecordChangeTypeAttributeName, updateChangeType)
            
            fetchRequest.predicate = predicate
            
            // fetch all change table entries marked as inserted or updated
            if let results = try! self.changeTablePrivateContext.executeFetchRequest(fetchRequest) as? [NSManagedObject] {
                changeTableEntries.appendContentsOf(results)
            }
        })
        
        // find the matching records
        for entry in changeTableEntries {
            if let obj = self.managedObjectForChangeTableEntry(entry) {
                let record = obj.toCKRecord()
                recordsByRecordID[record.recordID] = record
            }
        }
        
        // return a dictionary of matching records in the local store
        return recordsByRecordID
    }
    
    func deletedCKRecordIDs() -> [CKRecordID] {
        var recordIDs = [CKRecordID]()
        
        changeTablePrivateContext.performBlockAndWait { () -> Void in
            let deleteChangeType = GSSChangeTableChangeType.Delete.toNumber()
            
            let fetchRequest = NSFetchRequest(entityName: GSSChangeTableEntityName)
            fetchRequest.predicate = NSPredicate(format: "%K == %@", GSSLocalRecordChangeTypeAttributeName, deleteChangeType)
            
            // fetch all change table entries marked as deleted
            let results = try! self.changeTablePrivateContext.executeFetchRequest(fetchRequest) as! [NSManagedObject]
            
            // get the CKRecordID for each matching managed object
            for result in results {
                let recordID = result.toCKRecordID()
                
                recordIDs.append(recordID)
            }
        }
        return recordIDs
    }
    
    /// Return the matching managed object from the main store that matches the change table entry
    func managedObjectForChangeTableEntry(changeTableEntry: NSManagedObject) -> NSManagedObject? {
        var object: NSManagedObject?
        
        mainPrivateContext.performBlockAndWait { () -> Void in
            let fetchRequest = NSFetchRequest(entityName: changeTableEntry.valueForKey(GSSLocalRecordEntityNameAttributeName) as! String)
            fetchRequest.predicate = NSPredicate(format: "%K == %@", GSSLocalRecordIDAttributeName, changeTableEntry.valueForKey(GSSLocalRecordIDAttributeName) as! String)
            fetchRequest.fetchLimit = 1
            
            let results = try! self.mainPrivateContext.executeFetchRequest(fetchRequest) as! [NSManagedObject]
            object = results.first
        }
        
        return object
    }
    
    func wipeChangeTable() {
        // if an atomic modify record operation suceedeeds, this means that the change table has been fully applied and can be cleared
        let deleteRequest = NSBatchDeleteRequest(fetchRequest: NSFetchRequest(entityName: GSSChangeTableEntityName))
        
        // execute the batch delete
        try! self.changeTablePSC.executeRequest(deleteRequest, withContext: self.changeTablePrivateContext)
    }
    
    // MARK: - Methods (Private/ Server to Local)
    
    func processInsertedOrUpdatedCKRecords(insertedOrUpdated: [CKRecord], deletedRecordIDs: [CKRecordID]) throws {
        // handle inserts and/or updates
        self.processInsertedOrUpdatedCKRecords(insertedOrUpdated)
        
        // handle deletes
        self.processDeletedRecordIDs(deletedRecordIDs)
        
        // if a deduplicator was provided, deduplicate the local store here
        if let d = deduplicator {
            let deduplicationManager = GSSDeduplicationManager()
            deduplicationManager.deduplicator = d
            
            // determine what entities need to be deduplicated
            var insertedOrUpdatedEntityNames = [String]()
            for record in insertedOrUpdated {
                if !insertedOrUpdatedEntityNames.contains(record.recordType) {
                    insertedOrUpdatedEntityNames.append(record.recordType)
                }
            }
            
            // deduplicate the affected record types; note deleted or updated records will not produce duplicates
            deduplicationManager.deduplicateManagedObjectContext(mainPrivateContext, forEntityNames: insertedOrUpdatedEntityNames)
        }
        
        // try to save the context
        if mainPrivateContext.hasChanges {
            try self.mainPrivateContext.save()
        }
    }
    
    func processInsertedOrUpdatedCKRecords(records: [CKRecord]) {
        mainPrivateContext.performBlockAndWait { () -> Void in
            var referencesByManagedObject = [NSManagedObject : [String : GSSReference]]()
            
            // first insert or update the records including their attributes
            for record in records {
                var object: NSManagedObject!
                
                let fetchRequest = NSFetchRequest(entityName: record.recordType)
                fetchRequest.predicate = NSPredicate(format: "%K == %@", GSSLocalRecordIDAttributeName, record.valueForKey(GSSLocalRecordIDAttributeName) as! String)
                fetchRequest.fetchLimit = 1
                
                // search for an existing object or insert a new one
                if let result = try! self.mainPrivateContext.executeFetchRequest(fetchRequest).first as? NSManagedObject {
                    // found an existing object in the cache; update it
                    object = result
                }
                else {
                    // no matching object found in the cache; insert a new one
                    object = NSEntityDescription.insertNewObjectForEntityForName(record.recordType, inManagedObjectContext: self.mainPrivateContext)
                }
                
                // update the object with the record
                let recordReferences = object.updateAttributesWithCKRecord(record)
                
                // keep track of the references
                if recordReferences.count > 0 {
                    referencesByManagedObject[object] = recordReferences
                }
            }
            
            // now satisfy all the references/relationships
            for (object, references) in referencesByManagedObject {
                for (name, ref) in references {
                    let destinationEntityName = ref.destinationEntityName
                    let destinationRecordID = ref.reference.recordID.recordName
                    
                    // fetch the destination object
                    let fetchRequest = NSFetchRequest(entityName: destinationEntityName)
                    fetchRequest.predicate = NSPredicate(format: "%K == %@", GSSLocalRecordIDAttributeName, destinationRecordID)
                    fetchRequest.fetchLimit = 1
                    
                    if let destinationObject = try! self.mainPrivateContext.executeFetchRequest(fetchRequest).first as? NSManagedObject {
                        object.setValue(destinationObject, forKey: name)
                    }
                }
            }
        }
    }
    
    func processDeletedRecordIDs(recordIDs: [CKRecordID]) {
        if recordIDs.count > 0 {
            mainPrivateContext.performBlockAndWait { () -> Void in
                let predicate = NSPredicate(format: "%K IN $RECORD_IDs", GSSLocalRecordIDAttributeName)
                
                let recordIDStrings = recordIDs.map({$0.recordName})
                
                // attempt to delete the specified recordIDs for every entity in the model; eventually all the affected records will be found and deleted
                for entityName in self.mainPSC.managedObjectModel.entities.map({$0.name!}) {
                    let fetchRequest = NSFetchRequest(entityName: entityName)
                    fetchRequest.predicate = predicate.predicateWithSubstitutionVariables(["RECORD_IDs" : recordIDStrings])
                    
                    if let results = try! self.mainPrivateContext.executeFetchRequest(fetchRequest) as? [NSManagedObject] {
                        for result in results {
                            self.mainPrivateContext.deleteObject(result)
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - Methods (Private/ Server token handling)
    
    func storeServerChangeToken(token: CKServerChangeToken?) {
        if let newToken = token {
            let data = NSKeyedArchiver.archivedDataWithRootObject(newToken)
            
            NSUserDefaults.standardUserDefaults().setValue(data, forKey: kPreviousServerChangeTokenKey)
            NSUserDefaults.standardUserDefaults().synchronize()
        }
    }
    
    func previousServerChangeToken() -> CKServerChangeToken? {
        if let data = NSUserDefaults.standardUserDefaults().valueForKey(kPreviousServerChangeTokenKey) as? NSData {
            return NSKeyedUnarchiver.unarchiveObjectWithData(data) as? CKServerChangeToken
        }
        return nil
    }

}
