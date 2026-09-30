Pod::Spec.new do |spec|

  spec.name         = "BearoundSDKNotificationExtensions"
  spec.version      = "3.14.0"
  spec.summary      = "Notification Service and Content extensions for Bearound rich push on iOS."
  spec.description  = "Ready-made app extension classes for Bearound rich push: a Notification Service Extension that attaches the image or video of a push, and a Notification Content Extension that draws the image, two-card and carousel layouts. Ships separately from BearoundSDK and does not depend on it."
  spec.homepage     = "https://github.com/Bearound/bearound-ios-sdk"
  spec.documentation_url = "https://github.com/Bearound/bearound-ios-sdk/blob/main/README.md#rich-push-images-carousel-video"
  spec.license      = { :type => "MIT", :file => "LICENSE" }

  spec.author   = { "Felipe Araujo" => "felipe.araujo@opencircle.com.br" }
  spec.platform = :ios, "13.0"
  spec.source   = { :git => "https://github.com/Bearound/bearound-ios-sdk.git", :tag => "v#{spec.version}" }

  # A module of its own, never `BearoundSDK`: with dynamic frameworks CocoaPods embeds the
  # extension targets' frameworks into the app, and a second `BearoundSDK.framework` would
  # overwrite the core one (the app then crashes at launch). No dependency on the core
  # either: no Bluetooth, location or background modes inside an app extension.
  spec.module_name = "BearoundSDKNotificationExtensions"
  spec.pod_target_xcconfig = { "APPLICATION_EXTENSION_API_ONLY" => "YES" }
  spec.swift_versions = "5.0"

  # One pod, no subspecs, on purpose. Per-target subspecs (Service in the NSE, Content in the
  # content extension) become two CocoaPods variants that both build
  # `BearoundSDKNotificationExtensions.framework`; with dynamic frameworks both land in the
  # app's Frameworks/ and the last one wins, so one extension loses its class. Both
  # extension targets therefore install this same pod:
  #   target 'NotificationService' do  pod 'BearoundSDKNotificationExtensions'  end
  #   target 'NotificationContent' do  pod 'BearoundSDKNotificationExtensions'  end
  #
  # The contract parser (BearoundSDK/RichPush) is shared with the core source tree and
  # compiled into this module too, so the two pods never link each other.
  spec.source_files = [
    "NotificationService/**/*.{swift}",
    "NotificationContent/**/*.{swift}",
    "NotificationShared/**/*.{swift}",
    "BearoundSDK/RichPush/**/*.{swift}",
  ]
  spec.frameworks = "Foundation", "UIKit", "UserNotifications", "UserNotificationsUI", "ImageIO"

end
