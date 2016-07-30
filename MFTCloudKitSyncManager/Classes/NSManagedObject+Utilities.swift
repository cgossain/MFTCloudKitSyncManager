//
//  NSManagedObject+Utilities.swift
//  CloudKitDemo
//
//  Created by Christian Gossain on 2015-11-08.
//  Copyright © 2015 Christian Gossain. All rights reserved.
//

import Foundation
import CoreData
import CloudKit

struct MFTReference {
    /// The name of the entity being referenced
    let destinationEntityName: String
    
    /// The CKReference object that points to the destination entity
    let reference: CKReference
}

extension NSManagedObject {
    
//    public override class func initialize() {
//        struct Static {
//            static var token: dispatch_once_t = 0
//        }
//        
//        // make sure this isn't a subclass
//        if self !== NSManagedObject.self {
//            return
//        }
//        
//        dispatch_once(&Static.token) {
//            let originalSelector = Selector("awakeFromInsert")
//            let swizzledSelector = Selector("gss_awakeFromInsert")
//            
//            let originalMethod = class_getInstanceMethod(self, originalSelector)
//            let swizzledMethod = class_getInstanceMethod(self, swizzledSelector)
//            
//            let didAddMethod = class_addMethod(self, originalSelector, method_getImplementation(swizzledMethod), method_getTypeEncoding(swizzledMethod))
//            
//            if didAddMethod {
//                class_replaceMethod(self, swizzledSelector, method_getImplementation(originalMethod), method_getTypeEncoding(originalMethod))
//            } else {
//                method_exchangeImplementations(originalMethod, swizzledMethod)
//            }
//        }
//    }
    
    public func mft_modificationDate() -> NSDate {
        return self.valueForKeyPath(MFTLocalRecordModificationDateAttributeName) as! NSDate
    }
    
//    public func gss_awakeFromInsert() {
//        self.gss_awakeFromInsert()
//        
//        // set the local record ID if one is not set
//        if self.primitiveValueForKey(GSSLocalRecordIDAttributeName) == nil {
//            self.setPrimitiveValue(NSUUID().UUIDString, forKey: GSSLocalRecordIDAttributeName)
//        }
//        
//        // set the modification date if not present
//        if self.primitiveValueForKey(GSSLocalRecordModificationDateAttributeName) == nil {
//            self.setPrimitiveValue(NSDate(), forKey: GSSLocalRecordModificationDateAttributeName)
//        }
//    }
    
    // MARK: Methods (Public)
    
    /**
     Returns a CKRecord counterpart to this object by either creating a new one or if the managed object is already storing the encoded fields of a CKRecord, simply updates that record and returns it.
     */
    func toCKRecord() -> CKRecord {
        var record: CKRecord?
        
        if let encodedSystemFields = self.valueForKey(MFTLocalRecordEncodedSystemFieldsAttributeName) as? NSData {
            // an encoded CKRecord is associated with this object; unarchive it and update it
            let unarchiver = NSKeyedUnarchiver(forReadingWithData: encodedSystemFields)
            unarchiver.requiresSecureCoding = true
            
            // this is the bare bones record containing only system fields; populate with the rest of the data
            record = CKRecord(coder: unarchiver)
        }
        else {
            // there is no encoded CKRecord; create a new one
            let recordID = self.toCKRecordID()
            
            record = CKRecord(recordType: self.entity.name!, recordID: recordID)
        }
        
        // populate the record with the values of self
        for property in self.entity.properties {
            if let attribute = property as? NSAttributeDescription {
                record?.setValue(self.valueForKey(attribute.name), forKey: attribute.name)
            }
            else if let relationship = property as? NSRelationshipDescription where !relationship.toMany {
                // only suporting to-one relationships at the moment (don't have a need for many-to-many at this point)
                // many-to-many is also may mean that your data model needs re-thinking to avoid them
                
                // get the destination object
                if let destinationObject = self.valueForKey(relationship.name) {
                    // create a CKRecordID that points to this object
                    let recordID = destinationObject.toCKRecordID()
                    var action = CKReferenceAction.DeleteSelf // default if there is no inverse relationship
                    
                    if let inverse = relationship.inverseRelationship {
                        // if there is an inverse relationship, determine the action according to the delete rule
                        switch inverse.deleteRule {
                        case .CascadeDeleteRule:
                            action = .DeleteSelf
                        default:
                            action = .None
                        }
                    }
                    
                    let reference = CKReference(recordID: recordID, action: action)
                    record?.setValue(reference, forKey: relationship.name)
                }
            }
        }
        return record!
    }
    
    func toCKRecordID() -> CKRecordID {
        let localRecordID = self.valueForKey(MFTLocalRecordIDAttributeName) as! String
        let zoneID = CKRecordZoneID(zoneName: MFTCloudKitSyncManagerZoneName, ownerName: CKOwnerDefaultName)
        let recordID = CKRecordID(recordName: localRecordID, zoneID: zoneID)
        
        return recordID
    }
    
    /** 
     Update the attributes of the receiver with the contents of the CKRecord, and returns a dictionary containing key value pair of the availble relationship/references
     */
    func updateAttributesWithCKRecord(record: CKRecord) -> [String : MFTReference] {
        var references = [String : MFTReference]()
        
        // populate self with the values of the record
        for key in record.allKeys() {
            if let attribute = self.entity.attributesByName[key] {
                self.setValue(record.valueForKey(key), forKey: attribute.name)
            }
            else if let relationship = self.entity.relationshipsByName[key] where !relationship.toMany {
                if let reference = record.valueForKey(relationship.name) as? CKReference {
                    let destinationEntityName = (relationship.destinationEntity?.name)!
                    references[key] = MFTReference(destinationEntityName: destinationEntityName, reference: reference)
                }
            }
        }
        
        // encode the records system fields to be stored in the objects as data
        let mutableData = NSMutableData()
        let archiver = NSKeyedArchiver(forWritingWithMutableData: mutableData)
        archiver.requiresSecureCoding = true
        record.encodeSystemFieldsWithCoder(archiver)
        archiver.finishEncoding()
        
        // encode the system fields
        self.setValue(mutableData, forKey: MFTLocalRecordEncodedSystemFieldsAttributeName)
        
        // return a dictionary containing the GSSReference associated with the objects relationships
        return references
    }
}