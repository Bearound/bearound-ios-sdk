//
//  DeviceInfoCollector.swift
//  BearoundSDK
//
//  Created by Bearound on 29/12/25.
//

import CoreLocation
import CoreTelephony
import Foundation
import Network
import SystemConfiguration
import SystemConfiguration.CaptiveNetwork
import UIKit
import UserNotifications

final class DeviceInfoCollector: @unchecked Sendable {
	private let appStartTime: Date

	/// Wi-Fi access point the device is joined to. Refreshed opportunistically because the
	/// platform API is async while payload building is not.
	private let wifiCollector = WifiCollector()

	/// Read-only CLLocationManager, mirroring the pattern in `BearoundSDK`: we only ever
	/// read `.location` (the fix CoreLocation already has cached) and never start updates,
	/// so this costs no battery and no GPS wake-up.
	private lazy var locationReader = CLLocationManager()

	/// Whether this collector participates in cold-start tracking. The SDK's sync
	/// collector passes true (and the FIRST payload of the process reports
	/// coldStart=true, consumed via [consumeColdStart]); the ErrorReporter's collector
	/// passes false and never consumes nor reports it.
	private let isColdStart: Bool

	/// Process-wide cold-start flag, spent by the first sync payload. The old design
	/// stamped the constructor flag on EVERY payload — coldStart was true for the whole
	/// process lifetime, carrying no signal.
	private static let coldStartLock = NSLock()
	private static var coldStartPending = true
	private static func consumeColdStart() -> Bool {
		coldStartLock.lock(); defer { coldStartLock.unlock() }
		let value = coldStartPending
		coldStartPending = false
		return value
	}

	// Static device facts captured ONCE here instead of via UIDevice/UIScreen on every
	// collect — collectDeviceInfo runs on the beaconQueue and UIKit properties are
	// main-thread APIs by contract. Battery monitoring is also enabled once here (it
	// was a per-call SETTER off-main, the riskiest of the bunch); the remaining
	// per-sync reads are plain getters.
	private let staticOSVersion: String
	private let staticDeviceName: String
	private let staticScreenWidth: Int
	private let staticScreenHeight: Int

	private var cachedNotificationPermission: String = "not_determined"

	private let permissionLock = NSLock()

	private var permissionCacheReady = false

	init(isColdStart: Bool = true) {
		appStartTime = Date()
		self.isColdStart = isColdStart

		let device = UIDevice.current
		device.isBatteryMonitoringEnabled = true
		staticOSVersion = device.systemVersion
		staticDeviceName = device.name
		let screen = UIScreen.main
		staticScreenWidth = Int(screen.bounds.width * screen.scale)
		staticScreenHeight = Int(screen.bounds.height * screen.scale)

		Task {
			await updateNotificationPermissionCache()
		}
	}

	@available(iOS 13.0.0, *)
	private func updateNotificationPermissionCache() async {
		let settings = await UNUserNotificationCenter.current().notificationSettings()

		let status =
			switch settings.authorizationStatus {
			case .authorized:
				"authorized"
			case .denied:
				"denied"
			case .notDetermined:
				"not_determined"
			case .provisional:
				"provisional"
			case .ephemeral:
				"ephemeral"
			@unknown default:
				"unknown"
			}

		// Dispatch to sync context to safely use NSLock (Swift 6 compatibility)
		DispatchQueue.main.async { [weak self] in
			self?.updateCachedPermission(status)
		}
	}
	
	/// Thread-safe update of cached permission (must be called from sync context)
	private func updateCachedPermission(_ status: String) {
		permissionLock.lock()
		cachedNotificationPermission = status
		permissionCacheReady = true
		permissionLock.unlock()
	}

	func collectDeviceInfo(
		locationPermission: CLAuthorizationStatus,
		bluetoothState: String,
		appInForeground: Bool
	) -> UserDevice {
		permissionLock.lock()
		let notificationPermission = cachedNotificationPermission
		let isCacheReady = permissionCacheReady
		permissionLock.unlock()

		if !isCacheReady {
			print("BeAroundSDK: Notification permission cache not ready yet, using default value")
		}

		return UserDevice(
			deviceId: DeviceIdentifier.getDeviceId(),
			pushToken: PushTokenStore.tokenForPayload,
			apnsEnvironment: APNSEnvironment.current(),
			manufacturer: "Apple",
			model: deviceModel(),
			osVersion: staticOSVersion,
			timestamp: Int(Date().timeIntervalSince1970 * 1000),
			timezone: TimeZone.current.identifier,
			batteryLevel: batteryLevel(),
			isCharging: isCharging(),
			bluetoothState: bluetoothState,
			locationPermission: locationPermissionString(locationPermission),
			notificationsPermission: notificationPermission,
			networkType: networkType(),
			cellularGeneration: cellularGeneration(),
			ramTotalMb: ramTotalMb(),
			ramAvailableMb: ramAvailableMb(),
			screenWidth: staticScreenWidth,
			screenHeight: staticScreenHeight,
			appInForeground: appInForeground,
			appUptimeMs: appUptimeMs(),
			coldStart: isColdStart ? Self.consumeColdStart() : false,
			lowPowerMode: isLowPowerModeEnabled(),
			locationAccuracy: locationAccuracyString(locationPermission),
			apId: wifiCollector.connectedApId(),
			// Temporary companion to apId while the collection is being validated.
			wifiSSID: wifiCollector.connectedSSID(),
			connectionMetered: connectionMetered(),
			connectionExpensive: connectionExpensive(),
			os: "iOS",
			deviceName: deviceName(),
			carrierName: carrierName(),
			availableStorageMb: availableStorageMb(),
			systemLanguage: systemLanguage(),
			thermalState: thermalState(),
			systemUptimeMs: systemUptimeMs(),
			wifis: wifiCollector.current(),
			location: DeviceLocation(locationReader.location),
			advertisingId: AdvertisingIdCollector.current(),
			trackingAuthorization: AdvertisingIdCollector.authorizationStatus()
		)
	}

	/// Kicks off an async refresh of the connected access point. Called before a sync so
	/// the next payload carries a fresh value; never blocks the caller.
	func refreshWifi() {
		wifiCollector.refresh()
	}

	private func deviceModel() -> String {
		var systemInfo = utsname()
		uname(&systemInfo)
		let modelCode = withUnsafePointer(to: &systemInfo.machine) {
			$0.withMemoryRebound(to: CChar.self, capacity: 1) {
				String(validatingUTF8: $0)
			}
		}
		return modelCode ?? "Unknown"
	}

	// Battery monitoring is enabled once in init — these are plain getters now.
	private func batteryLevel() -> Int {
		let level = UIDevice.current.batteryLevel
		return level >= 0 ? Int(level * 100) : 0
	}

	private func isCharging() -> Bool {
		let state = UIDevice.current.batteryState
		return state == .charging || state == .full
	}

	private func isLowPowerModeEnabled() -> Bool {
		ProcessInfo.processInfo.isLowPowerModeEnabled
	}

	private func locationPermissionString(_ status: CLAuthorizationStatus) -> String {
		switch status {
		case .notDetermined: return "not_determined"
		case .restricted: return "restricted"
		case .denied: return "denied"
		case .authorizedAlways: return "authorized_always"
		case .authorizedWhenInUse: return "authorized_when_in_use"
		@unknown default: return "unknown"
		}
	}

	private func locationAccuracyString(_ status: CLAuthorizationStatus) -> String? {
		guard status == .authorizedAlways || status == .authorizedWhenInUse else {
			return nil
		}

		if #available(iOS 14.0, *) {
			// Reuse the SDK-wide shared instance — see BeAroundSDK.authQueryManager kdoc.
			// Spinning up a transient CLLocationManager here triggered TCC IPC churn.
			switch BeAroundSDK.sharedAccuracyAuthorization() {
			case .fullAccuracy: return "full"
			case .reducedAccuracy: return "reduced"
			@unknown default: return "unknown"
			}
		}

		return "full"
	}

	private func networkType() -> String {
		if #available(iOS 12.0, *) {
			// Long-lived monitor with an instant snapshot — the old code spun up
			// a fresh NWPathMonitor and blocked on a semaphore (≤0.5s) on every
			// read, and this method is called up to 3× per collection.
			return NetworkSnapshotProvider.shared.current
		} else {
			// Fallback for iOS < 12.0
			var zeroAddress = sockaddr_in()
			zeroAddress.sin_len = UInt8(MemoryLayout.size(ofValue: zeroAddress))
			zeroAddress.sin_family = sa_family_t(AF_INET)

			guard
				let defaultRouteReachability = withUnsafePointer(
					to: &zeroAddress,
					{
						$0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
							SCNetworkReachabilityCreateWithAddress(nil, $0)
						}
					})
			else {
				return "none"
			}

			var flags: SCNetworkReachabilityFlags = []
			if !SCNetworkReachabilityGetFlags(defaultRouteReachability, &flags) {
				return "none"
			}

			let isReachable = flags.contains(.reachable)
			let needsConnection = flags.contains(.connectionRequired)
			let isNetworkReachable = isReachable && !needsConnection

			if !isNetworkReachable {
				return "none"
			}

			if flags.contains(.isWWAN) {
				return "cellular"
			}

			return "wifi"
		}
	}

	private func cellularGeneration() -> String? {
		let networkInfo = CTTelephonyNetworkInfo()

		if #available(iOS 12.0, *) {
			guard let carrier = networkInfo.serviceCurrentRadioAccessTechnology?.values.first else {
				return nil
			}

			switch carrier {
			case CTRadioAccessTechnologyGPRS,
				CTRadioAccessTechnologyEdge,
				CTRadioAccessTechnologyCDMA1x:
				return "2G"

			case CTRadioAccessTechnologyWCDMA,
				CTRadioAccessTechnologyHSDPA,
				CTRadioAccessTechnologyHSUPA,
				CTRadioAccessTechnologyCDMAEVDORev0,
				CTRadioAccessTechnologyCDMAEVDORevA,
				CTRadioAccessTechnologyCDMAEVDORevB,
				CTRadioAccessTechnologyeHRPD:
				return "3G"

			case CTRadioAccessTechnologyLTE:
				return "4G"

			default:
				if #available(iOS 14.1, *) {
					if carrier == CTRadioAccessTechnologyNRNSA
						|| carrier == CTRadioAccessTechnologyNR
					{
						return "5G"
					}
				}
				return nil
			}
		}

		return nil
	}

	// The old `wifiSSID()` lived here. It read the network NAME, which identified the
	// user's household in clear text and served no purpose downstream — `WifiCollector`
	// now reports the hashed access point identity instead.

	private func connectionMetered() -> Bool? {
		let networkType = networkType()
		switch networkType {
		case "cellular":
			return true
		case "wifi":
			return false
		default:
			return nil
		}
	}

	private func connectionExpensive() -> Bool? {
		let networkType = networkType()
		switch networkType {
		case "cellular":
			return true
		case "wifi":
			return false
		default:
			return nil
		}
	}

	private func ramTotalMb() -> Int {
		Int(ProcessInfo.processInfo.physicalMemory / 1024 / 1024)
	}

	private func ramAvailableMb() -> Int {
		var taskInfo = mach_task_basic_info()
		var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4

		let kerr: kern_return_t = withUnsafeMutablePointer(to: &taskInfo) {
			$0.withMemoryRebound(to: integer_t.self, capacity: 1) {
				task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
			}
		}

		if kerr == KERN_SUCCESS {
			let usedMb = Int(taskInfo.resident_size / 1024 / 1024)
			return ramTotalMb() - usedMb
		}

		return 0
	}

	private func appUptimeMs() -> Int {
		Int(Date().timeIntervalSince(appStartTime) * 1000)
	}

	private func deviceName() -> String {
		staticDeviceName
	}

	private func carrierName() -> String? {
		let networkInfo = CTTelephonyNetworkInfo()

		if #available(iOS 12.0, *) {
			// Note: serviceSubscriberCellularProviders is deprecated in iOS 16.0+
			// with no replacement due to privacy changes and eSIM prevalence
			if #available(iOS 16.0, *) {
				// Carrier information is no longer reliably available on iOS 16+
				// Fall through to legacy API attempt
			} else {
				if let carriers = networkInfo.serviceSubscriberCellularProviders {
					for carrier in carriers.values {
						if let carrierName = carrier.carrierName, !carrierName.isEmpty {
							return carrierName
						}
					}
				}
			}
		} else {
			if let carrier = networkInfo.subscriberCellularProvider,
				let carrierName = carrier.carrierName, !carrierName.isEmpty
			{
				return carrierName
			}
		}

		return nil
	}

	private func availableStorageMb() -> Int? {
		let fileManager = FileManager.default
		do {
			let systemAttributes = try fileManager.attributesOfFileSystem(
				forPath: NSHomeDirectory())
			if let freeSize = systemAttributes[.systemFreeSize] as? NSNumber {
				return Int(freeSize.int64Value / 1024 / 1024)
			}
		} catch {
			print("BeAroundSDK: Error getting storage info: \(error)")
		}
		return nil
	}

	private func systemLanguage() -> String {
		if #available(iOS 16.0, *) {
			return Locale.current.language.languageCode?.identifier ?? "unknown"
		} else {
			return Locale.current.languageCode ?? "unknown"
		}
	}

	private func thermalState() -> String {
		if #available(iOS 11.0, *) {
			switch ProcessInfo.processInfo.thermalState {
			case .nominal:
				return "nominal"
			case .fair:
				return "fair"
			case .serious:
				return "serious"
			case .critical:
				return "critical"
			@unknown default:
				return "unknown"
			}
		}
		return "not_available"
	}

	private func systemUptimeMs() -> Int {
		Int(ProcessInfo.processInfo.systemUptime * 1000)
	}
}

