Pod::Spec.new do |spec|

  spec.name         = "BeAround"
  spec.version      = "0.0.3"
  spec.summary      = "Swift SDK for iOS — secure BLE beacon detection and indoor positioning by Bearound."
  spec.description  = "Official SDKs for integrating Bearound's secure BLE beacon detection and indoor location technology across Android, iOS, React Native, and Flutter."
  spec.homepage     = "https://github.com/Bearound"
  spec.license      = "MIT © Bearound"

  spec.author   = { "BeAround" => "arthur.sousa@opencircle.com.br" }
  spec.platform = :ios, "13.0"
  spec.source   = { :git => "https://github.com/Bearound/bearound-ios-sdk.git", :tag => spec.version.to_s }
  
  spec.source_files  = "Sources/**/*.{swift}"

  #spec.frameworks = "UIKit", "CoreLocation", "CoreBluetooth"
  
  spec.swift_versions = "5.0"

end
