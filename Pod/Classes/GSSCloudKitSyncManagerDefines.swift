//
//  GSSDefines.swift
//  CloudKitDemo
//
//  Created by Christian Gossain on 2015-11-08.
//  Copyright © 2015 Christian Gossain. All rights reserved.
//

import Foundation

public let GSSCloudKitSyncManagerZoneName = "GSSCustomSyncZone"
public let GSSChangeTableEntityName = "GSSChangeTableEntityName"

public let GSSLocalRecordEntityNameAttributeName = "gss_affected_entity_name"
public let GSSLocalRecordChangeTypeAttributeName = "gss_change_type"
public let GSSLocalRecordIDAttributeName = "gss_record_id"
public let GSSLocalRecordEncodedSystemFieldsAttributeName = "gss_encoded_system_fields"
public let GSSLocalRecordModificationDateAttributeName = "gss_local_modification_date"

enum GSSChangeTableChangeType: Int16 {
    case Insert = 1
    case Update = 2
    case Delete = 3
    
    init?(number: NSNumber) {
        switch number.shortValue {
        case 1:
            self = .Insert
            
        case 2:
            self = .Update
            
        case 3:
            self = .Delete
            
        default:
            return nil
        }
    }
    
    func toNumber() -> NSNumber {
        return NSNumber(short: self.rawValue)
    }
}

extension NSURL {
    
    static func gss_applicationDocumentsDirectory() -> NSURL {
        let urls = NSFileManager.defaultManager().URLsForDirectory(.DocumentDirectory, inDomains: .UserDomainMask)
        return urls.first!
    }
    
}