//
//  GSSDeduplicationManager.swift
//  Pods
//
//  Created by Christian Gossain on 2016-01-30.
//
//

import Foundation
import CoreData

public protocol GSSContextDeduplicating {
    /**
     Returns an array of unique attribute names for the specified entity name. The deduplicator uses this information to find duplicates within the database. At least 1 valid attribute name must be provided for the specified entity for deduplication to occur (i.e. if an attribute name does not exist on the specified entity, the attribute is ignored).
     
     - parameter entityName: The name of the entity for which unique attributes are being requested.
     - returns: An array of strings representing the attributes to use to identify duplicate objects. At least 1 unique attribute must be provided for deduplication to occur.
     */
    func uniqueAttributeNamesForEntityName(entityName: String) -> [String]
    
    /** 
     Given a set of duplicate managed objects, this method should return the managed object to be kept; all other managed objects are marked as duplicates and deleted from the context.
     
     - parameters duplicates: A set of duplicate managed objects found in the managed object context.
     - returns: The managed object to be kept from the specified set of duplicates; the object returned must be from the specified set of duplicates, if it is not, or if nil is returned, deduplication does not occur for the specified set of duplicates.
     */
    func uniqueManagedObjectFromDuplicates(duplicates: Set<NSManagedObject>, forEntityName entityName: String) -> NSManagedObject?
}

public class GSSDeduplicationManager: NSObject {
    
    public var deduplicator: GSSContextDeduplicating?
    
    public func deduplicateManagedObjectContext(context: NSManagedObjectContext, forEntityNames entityNames: [String]) {
        // the context should first be saved; if it is not saved, unsaved changes are not considered in the deduplication
        context.saveContext()
        
        for entityName in entityNames {
            deduplicateManagedObjectContext(context, forEntityName: entityName)
        }
    }
    
    func deduplicateManagedObjectContext(context: NSManagedObjectContext, forEntityName entityName: String) {
        // perform the deduplication asynchronously
        context.performBlock {
            // get the unique attributes from the deduplicator
            if let uniqueAttributes = self.deduplicator?.uniqueAttributeNamesForEntityName(entityName) {
                // get the duplicates for the given entity name
                if let dupes = self.duplicatesInManagedObjectContext(context, entityName: entityName, uniqueAttributes: uniqueAttributes) {
                    let fetchRequest = self.fetchRequestForEntityName(entityName, uniqueAttributes: uniqueAttributes, duplicates: dupes)
                    
                    do {
                        if let results = try context.executeFetchRequest(fetchRequest) as? [NSManagedObject] {
                            var duplicateManagedObjectSets = [Set<NSManagedObject>]()
                            
                            // collect each set of duplicates into an array and keep track of them
                            let lastIdx = results.count - 1
                            var previousManagedObject: NSManagedObject?
                            var duplicates = Set<NSManagedObject>()
                            for (idx, obj) in results.enumerate() {
                                var shouldTerminateSet = (idx == lastIdx)
                                
                                // check if the object is equal to the previous one
                                if previousManagedObject != nil {
                                    if !obj.gss_isEqualToManagedObject(previousManagedObject!, forUniqueAttributes: uniqueAttributes) {
                                        shouldTerminateSet = true
                                    }
                                }
                                duplicates.insert(obj)
                                previousManagedObject = obj
                                
                                // terminate the set if neccessary
                                if shouldTerminateSet {
                                    duplicateManagedObjectSets.append(duplicates) // track the current set of duplicates
                                    duplicates.removeAll() // empty the set
                                }
                            }
                            
                            // pass the duplicate object sets to the deduplicator
                            var duplicatesToBeDeleted = [NSManagedObject]()
                            for d in duplicateManagedObjectSets {
                                if let uniqueObject = self.deduplicator?.uniqueManagedObjectFromDuplicates(d, forEntityName: entityName) {
                                    var mutableDuplicates = d
                                    if let _ = mutableDuplicates.remove(uniqueObject) {
                                        // the object that was returned was removed and therefore the reaming duplicates can be marked for deletion
                                        duplicatesToBeDeleted.appendContentsOf(mutableDuplicates)
                                    }
                                }
                            }
                            
                            // delete the duplicates
                            for objectToDelete in duplicatesToBeDeleted {
                                context.deleteObject(objectToDelete)
                            }
                            
                            context.saveContext()
                        }
                    } catch {
                        NSLog("ERROR FETCHING DUPLICATE MANAGED OBJECTS: \(error)")
                    }
                }
            }
        }
    }
    
    // MARK: - Methods (Private)
    
    /**
    Returns an array of dictionaries that specify the attribute values that appear in the database at least twice for a given entity, according to the specified unique attributes.
    
    The format of each dictionary is:
    ````
    Key                   | Value
    --------------------- | ---------------------
    count                 | # of duplicates found
    uniqueAttributeName   | attribute value
    uniqueAttributeName   | attribute value
    etc...                | attribute value
    ````
    
    The value of the _count_ key specifies the number of duplicates found in the database for the given set of unique attributes.
    */
    private func duplicatesInManagedObjectContext(context: NSManagedObjectContext, entityName: String, uniqueAttributes: [String]) -> [[String : AnyObject]]? {
        // get the corresponding property desctions from the entity for the specified unique attributes
        var uniqueAttributeDescriptions = [NSPropertyDescription]()
        if let entity = context.persistentStoreCoordinator?.managedObjectModel.entitiesByName[entityName] {
            for attributeName in uniqueAttributes {
                if let uniqueAttributeDescription = entity.propertiesByName[attributeName] {
                    uniqueAttributeDescriptions.append(uniqueAttributeDescription)
                }
            }
        }
        
        // at least 1 unique attribute is needed for deduplication to occur
        if uniqueAttributeDescriptions.count > 0 {
            var propertiesToFetch = [NSPropertyDescription]()
            var propertiesToGroupBy = [NSPropertyDescription]()
            
            for (idx, description) in uniqueAttributeDescriptions.enumerate() {
                if idx == 0 {
                    let primaryAttributeCountExpression = NSExpressionDescription()
                    primaryAttributeCountExpression.name = "count"
                    primaryAttributeCountExpression.expression = NSExpression(format: "count:(%K)", description.name)
                    primaryAttributeCountExpression.expressionResultType = .Integer64AttributeType
                    
                    propertiesToFetch.append(primaryAttributeCountExpression)
                }
                
                propertiesToFetch.append(description)
                propertiesToGroupBy.append(description)
            }
            
            let fetchRequest = NSFetchRequest(entityName: entityName)
            fetchRequest.propertiesToFetch = propertiesToFetch
            fetchRequest.propertiesToGroupBy = propertiesToGroupBy
            fetchRequest.includesPendingChanges = false
            fetchRequest.fetchBatchSize = 100
            fetchRequest.resultType = .DictionaryResultType
            
            do {
                let results = try context.executeFetchRequest(fetchRequest) as NSArray
                if let duplicates = results.filteredArrayUsingPredicate(NSPredicate(format: "count > 1")) as? [[String : AnyObject]] {
                    return duplicates
                }
            } catch {
                NSLog("ERROR FETCHING DUPLICATES: \(error)")
            }
        }
        return nil
    }
    
    private func fetchRequestForEntityName(entityName: String, uniqueAttributes: [String], duplicates:[[String : AnyObject]]) -> NSFetchRequest {
        let fetchRequest = NSFetchRequest(entityName: entityName)
        fetchRequest.sortDescriptors = sortDescriptorsForUniqueAttributes(uniqueAttributes)
        fetchRequest.fetchBatchSize = 100
        fetchRequest.includesPendingChanges = false
        
        // the duplicates array contains dictionaries that each specify a unique attribute and its value that appears more than once in the database
        // this allows us to form a predicate that will search agains these duplicated values
        let predicates = uniqueAttributes.map({ NSPredicate(format: "%K IN (%@.%K)", $0, duplicates, $0) })
        
        fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        
        return fetchRequest
    }
    
    private func sortDescriptorsForUniqueAttributes(attributes: [String]) -> [NSSortDescriptor] {
        return attributes.map({ NSSortDescriptor(key: $0, ascending: true) })
    }
    
}

extension NSManagedObject {
    
    func gss_isEqualToManagedObject(object: NSManagedObject, forUniqueAttributes uniqueAttributes: [String]) -> Bool {
        var mismatch = false
        for uniqueAttributeName in uniqueAttributes {
            if let attributeValue = self.valueForKeyPath(uniqueAttributeName), let otherAttributeValue = object.valueForKeyPath(uniqueAttributeName) {
                if !attributeValue.isEqual(otherAttributeValue) {
                    mismatch = true
                    
                    // there is a mismatch; the objects are not perfect matches for the specified unique attributes
                    break
                }
            } else {
                mismatch = true
                
                // one or both of the unique attribute values do not have a value; therefore there is not enough information to determine whether the objects are equal or not
                // the best we can do is assume there is a mismatch
                break
            }
        }
        return !mismatch // if there is no mismatch, the objects are considered equal
    }
    
}
