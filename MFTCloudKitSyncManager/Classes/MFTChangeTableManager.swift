//
//  MFTChangeTableManager.swift
//  CloudKitDemo
//
//  Created by Christian Gossain on 2015-11-07.
//  Copyright © 2015 Christian Gossain. All rights reserved.
//

import Foundation
import CoreData

let MFTLocalStoreChangeTableFilename = "MFTLocalStoreChangeTable.sqlite"

class MFTChangeTableManager: NSObject {
    
    private let observedContext: NSManagedObjectContext
    
    private var contextDidSaveNotificationObserver: AnyObject!
    
    private var storeURL: NSURL {
        return NSURL.mft_applicationDocumentsDirectory().URLByAppendingPathComponent("MFTChangeTableManagerCoreData.sqlite")
    }
    
    private var storeOptions: [String : Bool] {
        return [NSMigratePersistentStoresAutomaticallyOption : true, NSInferMappingModelAutomaticallyOption : true]
    }
    
    var persistentStoreCoordinator: NSPersistentStoreCoordinator!
    
    private var changeTableContext: NSManagedObjectContext!
    
    // MARK: - Initialization
    
    /**
     Initializes the change table manager with the specified managed object context
     
     - parameters:
        - managedObjectContext: The managed object context to be observed. The change table manager will track all changes that are saved by this context.
     */
    init(managedObjectContext: NSManagedObjectContext) {
        observedContext = managedObjectContext
        super.init()
        
        self.configureChangeTableCoreDataStack()
        
        // observe the context for did save notifications
        contextDidSaveNotificationObserver =
        NSNotificationCenter.defaultCenter().addObserverForName(NSManagedObjectContextDidSaveNotification,
        object: observedContext,
        queue: NSOperationQueue.mainQueue()) { [weak self] (note) -> Void in
            self?.handleContextDidSaveNotification(note)
        }
    }
    
    deinit {
        NSNotificationCenter.defaultCenter().removeObserver(contextDidSaveNotificationObserver)
    }
    
    // MARK: - Methods (Private)
    
    private func handleContextDidSaveNotification(note: NSNotification) {
        // inserted
        if let objects = note.userInfo?[NSInsertedObjectsKey] as? Set<NSManagedObject> where objects.count > 0 {
            logChangedManagedObjects(objects, changeType: .Insert)
        }
        
        // updated
        if let objects = note.userInfo?[NSUpdatedObjectsKey] as? Set<NSManagedObject> where objects.count > 0 {
            logChangedManagedObjects(objects, changeType: .Update)
        }
        
        // deleted
        if let objects = note.userInfo?[NSDeletedObjectsKey] as? Set<NSManagedObject> where objects.count > 0 {
            logChangedManagedObjects(objects, changeType: .Delete)
        }
        
        // save
        self.changeTableContext.saveContext()
    }
    
    private func logChangedManagedObjects(objects: Set<NSManagedObject>, changeType: MFTChangeTableChangeType) {
        /**
        Few thing to note here:
        
        1. For objects being inserted, we can be assume with a high degree of certainty that there are no corresponding entries in the change table representing the inserted objects.
        
        2. For objects being updated, this change could potentially be a new change, or could simply be an additional change.
            • If this is a new change, we can simply add the entry (i.e. the entry does not exist in the change table)
            • If the change entry already exists, the existing entry will either have an Insert or Update change type. If it is an insert, we should keep it as such.
        
        3. For objects being deleted, this change could potentially be a new change, or could simply be an additional change.
            • If this is a new change, we can simply add the entry
            • If the change entry already exists, and we are moving from an Insert, the entry was inserted and updated in the same "change session" (i.e. the inserted entry has not yet been synced and therefore the entry can simply be deleted from the change table and the server does not need to know about it.
            • If the change entry already exists, and we are moving from an Update, the entry exists on the server and we need to update the change type to a delete
        */
        enum ChangeTableEntryUpdatePolicy {
            case UpdateIncludingChangeType
            case UpdateExcludingChangeType
            case DeleteEntry
        }
        
        // update the change table for every changed object
        for obj in objects {
            var policy = ChangeTableEntryUpdatePolicy.UpdateIncludingChangeType // default
            var changeTableEntry: NSManagedObject?
            
            // first find existing entries for this object
            let fetchRequest = NSFetchRequest(entityName: MFTChangeTableEntityName)
            fetchRequest.predicate = NSPredicate(format: "%K == %@", MFTLocalRecordIDAttributeName, obj.valueForKey(MFTLocalRecordIDAttributeName) as! String)
            
            let results = try! self.changeTableContext.executeFetchRequest(fetchRequest)
            
            // check for existing entries
            if results.isEmpty {
                // this is a new change and we can simply add then entry to the change table
                changeTableEntry = NSEntityDescription.insertNewObjectForEntityForName(MFTChangeTableEntityName, inManagedObjectContext: self.changeTableContext)
            }
            else {
                // there is an existing change, update the change entry according to the above rules
                changeTableEntry = results.first as? NSManagedObject
                
                let raw = changeTableEntry?.valueForKey(MFTLocalRecordChangeTypeAttributeName) as! NSNumber
                
                if let currentChangeType = MFTChangeTableChangeType(number: raw) {
                    switch (changeType, currentChangeType) {
                        
                    case (.Update, .Insert):
                        // the change is now an update, but it's already marked as being inserted, we don't need to change the entry to an update
                        policy = .UpdateExcludingChangeType
                        
                    case (.Delete, .Insert):
                        // the change is a delete, and the existing entry is marked as having been inserted; this change has not been synced to the server and the server does not need to know about it, so we can simply delete the entry
                        policy = .DeleteEntry
                        
                    default:
                        break
                        
                    }
                }
            }
            
            // handle the policy
            switch policy {
            case .UpdateIncludingChangeType:
                changeTableEntry?.setValue(obj.entity.name, forKey: MFTLocalRecordEntityNameAttributeName)
                changeTableEntry?.setValue(obj.valueForKey(MFTLocalRecordIDAttributeName), forKey: MFTLocalRecordIDAttributeName)
                changeTableEntry?.setValue(changeType.toNumber(), forKey: MFTLocalRecordChangeTypeAttributeName)
                
            case .UpdateExcludingChangeType:
                changeTableEntry?.setValue(obj.entity.name, forKey: MFTLocalRecordEntityNameAttributeName)
                changeTableEntry?.setValue(obj.valueForKey(MFTLocalRecordIDAttributeName), forKey: MFTLocalRecordIDAttributeName)
                
            case .DeleteEntry:
                guard let entry = changeTableEntry else { return }
                changeTableContext.deleteObject(entry)
            }
        }
    }
    
    // MARK: - Private Core Data Stack (Change Table Stack)
    
    lazy var model: NSManagedObjectModel = {
        let managedObjectModel = NSManagedObjectModel()
        
        // create the change table entry entity
        let entity = NSEntityDescription()
        entity.name = MFTChangeTableEntityName
        
        // the name of the entity that was changed in the observed context
        let entityNameAttribute = NSAttributeDescription()
        entityNameAttribute.name = MFTLocalRecordEntityNameAttributeName
        entityNameAttribute.attributeType = .StringAttributeType
        entityNameAttribute.optional = false
        
        // the recordID of the object that was changed in the observed context
        let recordIDAttribute = NSAttributeDescription()
        recordIDAttribute.name = MFTLocalRecordIDAttributeName
        recordIDAttribute.attributeType = .StringAttributeType
        recordIDAttribute.optional = false
        
        // the type of change that occured on the object in the observed context
        let changeTypeAttribute = NSAttributeDescription()
        changeTypeAttribute.name = MFTLocalRecordChangeTypeAttributeName
        changeTypeAttribute.attributeType = .Integer16AttributeType
        changeTypeAttribute.optional = true
        
        // add the attribute to the entity description
        entity.properties = [entityNameAttribute, recordIDAttribute, changeTypeAttribute]
        
        // add the change table entry entity to the model
        managedObjectModel.entities = [entity]
        
        return managedObjectModel
    }()
    
    private func configureChangeTableCoreDataStack() {
        // configure the persistent store coordinator
        persistentStoreCoordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        
        do {
            try persistentStoreCoordinator.addPersistentStoreWithType(NSSQLiteStoreType, configuration: nil, URL: self.storeURL, options: self.storeOptions)
        } catch {
            let failureReason = "There was an error creating or loading the application's saved data."
            
            // Report any error we got.
            var dict = [String: AnyObject]()
            dict[NSLocalizedDescriptionKey] = "Failed to initialize the application's saved data"
            dict[NSLocalizedFailureReasonErrorKey] = failureReason
            
            dict[NSUnderlyingErrorKey] = error as NSError
            let wrappedError = NSError(domain: "YOUR_ERROR_DOMAIN", code: 9999, userInfo: dict)
            // Replace this with code to handle the error appropriately.
            // abort() causes the application to generate a crash log and terminate. You should not use this function in a shipping application, although it may be useful during development.
            NSLog("Unresolved error \(wrappedError), \(wrappedError.userInfo)")
            abort()
        }
        
        // configure the main managed object context
        changeTableContext = NSManagedObjectContext(concurrencyType: .MainQueueConcurrencyType)
        changeTableContext.persistentStoreCoordinator = persistentStoreCoordinator
    }
}
