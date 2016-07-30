//
//  MFTCloudKitSyncManager.swift
//  CloudKitDemo
//
//  Created by Christian Gossain on 2015-11-07.
//  Copyright © 2015 Christian Gossain. All rights reserved.
//

import Foundation
import CoreData

public class MFTCloudKitSyncManager: NSObject {
    
    public static let sharedManager = MFTCloudKitSyncManager()
    
    /// The managed object context. You must call the -configureWithCustomStoreURL:modelName: method before accessing this property.
    public var managedObjectContext: NSManagedObjectContext { return mainContext }
    
    /** 
     An object that conforms to the GSSContextDeduplicating protocol. If this object is provided, the local store will be deduplicated when records are pulled in from the server.
     
     Set this object before performing the sync.
     */
    public var deduplicator: MFTContextDeduplicating?
    
    private var customStoreURL: NSURL?
    private var storeURL: NSURL {
        if customStoreURL != nil {
            return customStoreURL!
        } else {
            return NSURL.mft_applicationDocumentsDirectory().URLByAppendingPathComponent("MFTCloudKitSyncManagerCoreData.sqlite")
        }
    }
    
    private var storeOptions: [String : Bool] {
        return [NSMigratePersistentStoresAutomaticallyOption : true, NSInferMappingModelAutomaticallyOption : true]
    }
    
    private var modelURL: NSURL?
    private var model: NSManagedObjectModel!
    private var persistentStoreCoordinator: NSPersistentStoreCoordinator!
    private var mainContext: NSManagedObjectContext!
    
    private var changeTableManager: MFTChangeTableManager!
    
    private var contextWillSaveNotificationObserver: AnyObject?
    
    private let operationQueue = NSOperationQueue()
    
    
    // MARK: - Initialization
    
    deinit {
        if let observer = contextWillSaveNotificationObserver {
            NSNotificationCenter.defaultCenter().removeObserver(observer)
        }
    }
    
    // MARK: - Methods (Public)
    
    public func deleteRecordZone() {
        let databaseSetupOperation =  MFTDatabaseSetupOperation()
        databaseSetupOperation.wipeDatabase = true
        
        databaseSetupOperation.databaseSetupCompletionBlock = { operationError in
            if let error = operationError {
                NSLog("MODIFY ZONE ERROR: %@", error.description)
            } else {
                NSLog("ZONE DELETED!")
                MFTSyncOperation.clearServerChangeToken()
            }
        }
        operationQueue.addOperation(databaseSetupOperation)
    }
    
    public func performSync() {
        let databaseSetupOperation =  MFTDatabaseSetupOperation()
        databaseSetupOperation.databaseSetupCompletionBlock = { operationError in
            if let error = operationError {
                NSLog("MODIFY ZONE ERROR: %@", error.description)
            } else {
                NSLog("ZONE CREATED!")
                
                // now add the sync operation to the queue
                let syncOperation = MFTSyncOperation(persistentStoreCoordinator: self.persistentStoreCoordinator, changeTableManager: self.changeTableManager, mainContext: self.mainContext)
                syncOperation.deduplicator = self.deduplicator
                syncOperation.conflicResolutionPolicy = MFTSyncOperationConflictResolutionPolicy.KeepNewerRecord
                
                self.operationQueue.addOperation(syncOperation)
            }
        }
        operationQueue.addOperation(databaseSetupOperation)
    }
    
    /**
    Configures the core data stack with the specified parameters. You must call this method in order to use the manager.
    
    - parameters:
        - storeURL: The file location of the  URL of the core data persistent store, or nil to use the default store file location.
        - modelName: The name of the core data model to use, or nil to use a merged model from all models in the main bundle.
    
    */
    public func configureWithCustomStoreURL(customStoreURL: NSURL?, modelName: String?) {
        self.customStoreURL = customStoreURL
        
        // get the managed object model for the specified model name, or get a merged model is a name is not provided
        if modelName == nil {
            model = NSManagedObjectModel.mergedModelFromBundles(nil)!.copy() as! NSManagedObjectModel
        } else {
            let modelURL = NSBundle.mainBundle().URLForResource(modelName!, withExtension: "momd")!
            model = NSManagedObjectModel(contentsOfURL: modelURL)!.copy() as! NSManagedObjectModel
        }
        
        // insert custom attributes to every entity in the model; lightweight migration will ensure they do not cause a model version exception
        // these attributes are required for the sync mechanism to function properly
        for entity in model.entities {
            if entity.superentity == nil {
                // used to store a custom record ID for all entities in the model
                // this ID can be stored in iCloud and be used to match up CKRecord's with corresponsing NSManagedObject's
                let recordIDAttribute = NSAttributeDescription()
                recordIDAttribute.name = MFTLocalRecordIDAttributeName
                recordIDAttribute.attributeType = .StringAttributeType
                recordIDAttribute.optional = false
                
                entity.properties.append(recordIDAttribute)
                
                // used to store the encoded CKRecord system fields
                // a record needs to be initialized with the system fields during a update in order to properly detect conflicts
                let encodedSystemFieldsAttribute = NSAttributeDescription()
                encodedSystemFieldsAttribute.name = MFTLocalRecordEncodedSystemFieldsAttributeName
                encodedSystemFieldsAttribute.attributeType = .BinaryDataAttributeType
                encodedSystemFieldsAttribute.optional = true
                
                entity.properties.append(encodedSystemFieldsAttribute)
                
                // modification date used for conflict resolution
                let modificationDateAttribute = NSAttributeDescription()
                modificationDateAttribute.name = MFTLocalRecordModificationDateAttributeName
                modificationDateAttribute.attributeType = .DateAttributeType
                modificationDateAttribute.optional = false
                
                entity.properties.append(modificationDateAttribute)
            }
        }
        
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
        mainContext = NSManagedObjectContext(concurrencyType: .MainQueueConcurrencyType)
        mainContext.persistentStoreCoordinator = persistentStoreCoordinator
        
        // observe the context for will save notifications
        contextWillSaveNotificationObserver =
        NSNotificationCenter.defaultCenter().addObserverForName(NSManagedObjectContextWillSaveNotification,
        object: mainContext,
        queue: NSOperationQueue.mainQueue()) { [weak self] (note) -> Void in
            let context = (self?.mainContext)!
            
            // assign a random UUID to each object that was inserted into the context before it is saved into the local store
            for obj in context.insertedObjects {
                obj.setValue(NSUUID().UUIDString, forKey: MFTLocalRecordIDAttributeName)
                
                // set the modification date
                obj.setValue(NSDate(), forKey: MFTLocalRecordModificationDateAttributeName)
            }
            
            // udpate the modification date
            for obj in context.updatedObjects {
                obj.setValue(NSDate(), forKey: MFTLocalRecordModificationDateAttributeName)
            }
        }
        
        // configure the change table manager
        changeTableManager = MFTChangeTableManager(managedObjectContext: mainContext)
    }
    
    // MARK: - Methods (Private)
    
}

extension NSManagedObjectContext {
    
    public func saveContext() {
        if self.hasChanges {
            do {
                try self.save()
            } catch {
                // Replace this implementation with code to handle the error appropriately.
                // abort() causes the application to generate a crash log and terminate. You should not use this function in a shipping application, although it may be useful during development.
                let nserror = error as NSError
                NSLog("Unresolved error \(nserror), \(nserror.userInfo)")
                abort()
            }
        }
    }
    
    public func saveManagedObjectContextHierarchy() throws {
        var saveError: ErrorType?
        var currentContext: NSManagedObjectContext? = self
        
        while let context = currentContext {
            context.performBlockAndWait({
                do {
                    if context.hasChanges {
                        try context.save()
                    }
                }
                catch {
                    saveError = error
                }
            })
            
            
            if let error = saveError {
                throw error
            }
            
            // move to the parent context
            currentContext = context.parentContext
        }
    }
    
}
