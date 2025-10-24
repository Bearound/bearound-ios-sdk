Pod::Spec.new do |spec|

  spec.name         = "BearoundSDK"
  spec.version      = "1.0.23"
  spec.summary      = "Swift SDK for iOS — secure BLE beacon detection and indoor positioning by Bearound."
  spec.description  = "Official SDK for integrating Bearound's secure BLE beacon detection and indoor location technology on iOS. Provides real-time beacon monitoring, region tracking, and seamless API synchronization."
  spec.homepage     = "https://github.com/Bearound/bearound-ios-sdk"
  spec.license      = { :type => "MIT", :file => "LICENSE" }

  spec.author   = { "Felipe Araujo" => "felipe.araujo@opencircle.com.br" }
  spec.platform = :ios, "13.0"
  spec.source   = { :git => "https://github.com/Bearound/bearound-ios-sdk.git", :tag => "v#{spec.version}" }

  spec.source_files  = "BearoundSDK/**/*.{swift}"

  spec.frameworks = "Foundation", "CoreLocation", "CoreBluetooth", "AdSupport"

  spec.swift_versions = "5.0"

end
