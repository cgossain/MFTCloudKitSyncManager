//
//  GSSDefines.swift
//  CloudKitDemo
//
//  Created by Christian Gossain on 2015-11-08.
//  Copyright © 2015 Christian Gossain. All rights reserved.
//

import Foundation

public let MFTCloudKitSyncManagerZoneName = "MFTCustomSyncZone"
public let MFTChangeTableEntityName = "MFTChangeTableEntityName"

public let MFTLocalRecordEntityNameAttributeName = "mft_affected_entity_name"
public let MFTLocalRecordChangeTypeAttributeName = "mft_change_type"
public let MFTLocalRecordIDAttributeName = "mft_record_id"
public let MFTLocalRecordEncodedSystemFieldsAttributeName = "mft_encoded_system_fields"
public let MFTLocalRecordModificationDateAttributeName = "mft_local_modification_date"

enum MFTChangeTableChangeType: Int16 {
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
    
    static func mft_applicationDocumentsDirectory() -> NSURL {
        let urls = NSFileManager.defaultManager().URLsForDirectory(.DocumentDirectory, inDomains: .UserDomainMask)
        return urls.first!
    }
    
}