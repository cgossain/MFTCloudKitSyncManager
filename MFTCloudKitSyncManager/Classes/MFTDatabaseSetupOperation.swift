//
//  MFTDatabaseSetupOperation.swift
//  CloudKitDemo
//
//  Created by Christian Gossain on 2015-11-10.
//  Copyright © 2015 Christian Gossain. All rights reserved.
//

import Foundation
import CloudKit

private let kClientDidCreateCustomDatabaseZoneKey = "kClientDidCreateCustomDatabaseZoneKey"

class MFTDatabaseSetupOperation: NSOperation {
    /// If no error is passed to the closure, the database setup has completed successfully, otherwise the error should be handled.
    var databaseSetupCompletionBlock: ((NSError?) -> Void)?
    
    var wipeDatabase = false
    
    private let internalQueue = NSOperationQueue()
    
    override func main() {
        let zoneID = CKRecordZoneID(zoneName: MFTCloudKitSyncManagerZoneName, ownerName: CKOwnerDefaultName)
        let zone = CKRecordZone(zoneID: zoneID)
        
        let database = CKContainer.defaultContainer().privateCloudDatabase
        
        if wipeDatabase {
            let modifyRecordZonesOperation = CKModifyRecordZonesOperation(recordZonesToSave: nil, recordZoneIDsToDelete: [zoneID])
            modifyRecordZonesOperation.database = database
            modifyRecordZonesOperation.modifyRecordZonesCompletionBlock = { (createdZones: [CKRecordZone]?, deletedZoneIDs: [CKRecordZoneID]?, operationError: NSError?) -> Void in
                // pass the error to the completion block
                self.databaseSetupCompletionBlock?(operationError)
            }
            internalQueue.addOperation(modifyRecordZonesOperation)
            
        } else {
            let modifyRecordZonesOperation = CKModifyRecordZonesOperation(recordZonesToSave: [zone], recordZoneIDsToDelete: nil)
            modifyRecordZonesOperation.database = database
            modifyRecordZonesOperation.modifyRecordZonesCompletionBlock = { (createdZones: [CKRecordZone]?, deletedZoneIDs: [CKRecordZoneID]?, operationError: NSError?) -> Void in
                // pass the error to the completion block
                self.databaseSetupCompletionBlock?(operationError)
            }
            internalQueue.addOperation(modifyRecordZonesOperation)
        }
        internalQueue.waitUntilAllOperationsAreFinished()
    }
    
}
