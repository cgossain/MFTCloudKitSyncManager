Pod::Spec.new do |s|
  s.name             = 'MFTCloudKitSyncManager'
  s.version          = '0.1.0'
  s.summary          = 'A simple to use core data manager with built in syncing to via CloudKit.'
  s.description      = <<-DESC
                       This project offers a simple interface to create your core data stack, with the optional ability to sync changes to a private zone in a users iCloud account, via CloudKit. The sync procedure implemented follows the proposed procedure decribed in the CloudKit sessions from WWDC 2015.
                       DESC

  s.homepage         = 'https://github.com/cgossain/MFTCloudKitSyncManager'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'Christian Gossain' => 'Christian Gossain' }
  s.source           = { :git => 'https://github.com/cgossain/MFTCloudKitSyncManager.git', :tag => s.version.to_s }
  s.ios.deployment_target = '9.3'
  s.source_files = 'MFTCloudKitSyncManager/Classes/**/*'
  s.frameworks = 'Foundation', 'CoreData', 'CloudKit'
end
