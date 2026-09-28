
Pod::Spec.new do |spec|

  spec.name         = "BearoundSDK"
  spec.version      = "3.12.0"
  spec.summary      = "Swift SDK for iOS — secure BLE beacon detection and indoor positioning by Bearound."
  spec.description  = "Official SDK for integrating Bearound's secure BLE beacon detection and indoor location technology on iOS. Provides real-time beacon monitoring, region tracking, and seamless API synchronization."
  spec.homepage     = "https://github.com/Bearound/bearound-ios-sdk"
  spec.documentation_url = "https://github.com/Bearound/bearound-ios-sdk/blob/main/README.md"
  spec.license      = { :type => "MIT", :file => "LICENSE" }

  spec.author   = { "Felipe Araujo" => "felipe.araujo@opencircle.com.br" }
  spec.platform = :ios, "13.0"
  spec.source   = { :git => "https://github.com/Bearound/bearound-ios-sdk.git", :tag => "v#{spec.version}" }

  # `pod 'BearoundSDK'` installs the core only, exactly as before the subspecs existed.
  spec.default_subspec = "Core"

  spec.subspec "Core" do |core|
    core.source_files = "BearoundSDK/**/*.{swift}"

    # Ships the Apple-required privacy manifest AND doubles as the automatic
    # version carrier: CocoaPods stamps this bundle's Info.plist with
    # spec.version at install time, which BeAroundSDK.version reads under
    # static linking (see SDKVersion in Constants.swift).
    core.resource_bundles = { "BearoundSDKPrivacy" => ["BearoundSDK/PrivacyInfo.xcprivacy"] }

    core.frameworks = "Foundation", "CoreLocation", "CoreBluetooth"
  end

  # Rich push extensions. Standalone on purpose: they must NOT pull the core (BLE, location,
  # background modes) into an app extension, and they only use extension-safe APIs.
  #   target 'NotificationService' do  pod 'BearoundSDK/NotificationService'  end
  #   target 'NotificationContent' do  pod 'BearoundSDK/NotificationContent'  end
  spec.subspec "NotificationService" do |nse|
    nse.source_files = "NotificationService/**/*.{swift}", "BearoundSDK/RichPush/**/*.{swift}"
    nse.frameworks = "Foundation", "UIKit", "UserNotifications"
    nse.pod_target_xcconfig = { "APPLICATION_EXTENSION_API_ONLY" => "YES" }
  end

  spec.subspec "NotificationContent" do |content|
    content.source_files = "NotificationContent/**/*.{swift}", "BearoundSDK/RichPush/**/*.{swift}"
    content.frameworks = "Foundation", "UIKit", "UserNotifications", "UserNotificationsUI"
    content.pod_target_xcconfig = { "APPLICATION_EXTENSION_API_ONLY" => "YES" }
  end

  spec.swift_versions = "5.0"

end
