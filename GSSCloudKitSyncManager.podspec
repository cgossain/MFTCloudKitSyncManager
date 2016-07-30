#
# Be sure to run `pod lib lint GSSCloudKitSyncManager.podspec' to ensure this is a
# valid spec before submitting.
#
# Any lines starting with a # are optional, but their use is encouraged
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html
#

Pod::Spec.new do |s|
  s.name             = "GSSCloudKitSyncManager"
  s.version          = "0.1.0"
  s.summary          = "A simple to use core data manager with built in syncing to via CloudKit."
  s.description      = <<-DESC
                       This project offers a simple interface to create your core data stack, with the optional ability to sync changes to a private zone in a users iCloud account, via CloudKit. The sync procedure implemented follows the proposed procedure decribed in the CloudKit sessions from WWDC 2015.
                       DESC

  s.homepage         = "https://github.com/<GITHUB_USERNAME>/GSSCloudKitSyncManager"
  s.license          = 'MIT'
  s.author           = { "Christian Gossain" => "Christian Gossain" }
  s.source           = { :git => "https://github.com/<GITHUB_USERNAME>/GSSCloudKitSyncManager.git", :tag => s.version.to_s }

  s.platform     = :ios, '9.0'
  s.requires_arc = true

  s.source_files = 'Pod/Classes/**/*'
  s.resource_bundles = {
    'GSSCloudKitSyncManager' => ['Pod/Assets/*.png']
  }
  s.frameworks = 'Foundation', 'CoreData', 'CloudKit'
end
