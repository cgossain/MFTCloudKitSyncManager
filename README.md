# MFTCloudKitSyncManager

[![CI Status](http://img.shields.io/travis/Christian Gossain/MFTCloudKitSyncManager.svg?style=flat)](https://travis-ci.org/Christian Gossain/MFTCloudKitSyncManager)
[![Version](https://img.shields.io/cocoapods/v/MFTCloudKitSyncManager.svg?style=flat)](http://cocoapods.org/pods/MFTCloudKitSyncManager)
[![License](https://img.shields.io/cocoapods/l/MFTCloudKitSyncManager.svg?style=flat)](http://cocoapods.org/pods/MFTCloudKitSyncManager)
[![Platform](https://img.shields.io/cocoapods/p/MFTCloudKitSyncManager.svg?style=flat)](http://cocoapods.org/pods/MFTCloudKitSyncManager)

## Introduction

This projects was partially inspired by the WWDC 2015 sessions around working with CloudKit where, among other things, there was a discussion about implementing sync via CloudKit to a local store. This project also came out of a need for a project I was working on, however before the project was completed we decided to go with another cloud solution.

This library syncs a private CloudKit database zone with a local CoreData store. One-to-One and One-to-Many relationships have been implemented and tested and work great. One-to-Many have not been tested. This library also offers a deduplication manager that deduplicates your local store according to rules that you specify via the MFTContextDeduplicating protocol.

Since we ended up not using this library, there are probably kinks that need to be ironed out, however the core functionaly works great.

I decided to Open-Source this project since I believe it offers a well implemented sync mechanism between CloudKit and CoreData, and hope that someone else will find it usefull is some way.

## Example

To run the example project, clone the repo, and run `pod install` from the Example directory first.

## Requirements

## Installation

MFTCloudKitSyncManager is available through [CocoaPods](http://cocoapods.org). To install
it, simply add the following line to your Podfile:

```ruby
pod "MFTCloudKitSyncManager"
```

## Author

Christian Gossain, Christian Gossain

## License

MFTCloudKitSyncManager is available under the MIT license. See the LICENSE file for more info.
