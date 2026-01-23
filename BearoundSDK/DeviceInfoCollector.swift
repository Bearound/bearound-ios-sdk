//
//  DeviceInfoCollector.swift
//  BearoundSDK
//
//  Created by Bearound on 29/12/25.
//

import AdSupport
import AppTrackingTransparency
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
	private let isColdStart: Bool

	private var cachedNotificationPermission: String = "not_determined"

	private let permissionLock = NSLock()

	private var permissionCacheReady = false

	init(isColdStart: Bool = true) {
		appStartTime = Date()
		self.isColdStart = isColdStart

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

	private func updateNotificationPermissionCacheSync() {
		UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
			guard let self else { return }

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

			self.updateCachedPermission(status)
		}
	}

	func collectDeviceInfo(
		locationPermission: CLAuthorizationStatus,
		bluetoothState: String,
		appInForeground: Bool,
		location: CLLocation? = nil
	) -> UserDevice {
		let device = UIDevice.current
		let screen = UIScreen.main

		permissionLock.lock()
		let notificationPermission = cachedNotificationPermission
		let isCacheReady = permissionCacheReady
		permissionLock.unlock()

		if !isCacheReady {
			print("BeAroundSDK: Notification permission cache not ready yet, using default value")
		}

		let deviceLocation: DeviceLocation?
		if let loc = location {
			var sourceInfo: String?
			if #available(iOS 15.0, *) {
				sourceInfo = loc.sourceInformation?.description
			}

			var speedAcc: Double?
			if #available(iOS 10.0, *) {
				speedAcc = loc.speedAccuracy >= 0 ? loc.speedAccuracy : nil
			}

			var courseAcc: Double?
			if #available(iOS 13.4, *) {
				courseAcc = loc.courseAccuracy >= 0 ? loc.courseAccuracy : nil
			}

			deviceLocation = DeviceLocation(
				latitude: loc.coordinate.latitude,
				longitude: loc.coordinate.longitude,
				accuracy: loc.horizontalAccuracy >= 0 ? loc.horizontalAccuracy : nil,
				altitude: loc.altitude,
				altitudeAccuracy: loc.verticalAccuracy >= 0 ? loc.verticalAccuracy : nil,
				heading: loc.course >= 0 ? loc.course : nil,
				speed: loc.speed >= 0 ? loc.speed : nil,
				speedAccuracy: speedAcc,
				course: loc.course >= 0 ? loc.course : nil,
				courseAccuracy: courseAcc,
				floor: loc.floor?.level,
				timestamp: loc.timestamp,
				sourceInfo: sourceInfo
			)
		} else {
			deviceLocation = nil
		}

		return UserDevice(
			deviceId: DeviceIdentifier.getDeviceId(),
			manufacturer: "Apple",
			model: deviceModel(),
			osVersion: device.systemVersion,
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
			screenWidth: Int(screen.bounds.width * screen.scale),
			screenHeight: Int(screen.bounds.height * screen.scale),
			adTrackingEnabled: isAdTrackingEnabled(),
			appInForeground: appInForeground,
			appUptimeMs: appUptimeMs(),
			coldStart: isColdStart,
			advertisingId: advertisingId(),
			lowPowerMode: isLowPowerModeEnabled(),
			locationAccuracy: locationAccuracyString(locationPermission),
			wifiSSID: wifiSSID(),
			connectionMetered: connectionMetered(),
			connectionExpensive: connectionExpensive(),
			os: "iOS",
			deviceLocation: deviceLocation,
			deviceName: deviceName(),
			carrierName: carrierName(),
			availableStorageMb: availableStorageMb(),
			systemLanguage: systemLanguage(),
			thermalState: thermalState(),
			systemUptimeMs: systemUptimeMs()
		)
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

	private func batteryLevel() -> Int {
		UIDevice.current.isBatteryMonitoringEnabled = true
		let level = UIDevice.current.batteryLevel
		return level >= 0 ? Int(level * 100) : 0
	}

	private func isCharging() -> Bool {
		UIDevice.current.isBatteryMonitoringEnabled = true
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
			let manager = CLLocationManager()
			switch manager.accuracyAuthorization {
			case .fullAccuracy: return "full"
			case .reducedAccuracy: return "reduced"
			@unknown default: return "unknown"
			}
		}

		return "full"
	}

	private func networkType() -> String {
		if #available(iOS 12.0, *) {
			let monitor = NWPathMonitor()
			let semaphore = DispatchSemaphore(value: 0)
			var result = "none"
			
			monitor.pathUpdateHandler = { path in
				if path.status == .satisfied {
					if path.usesInterfaceType(.cellular) {
						result = "cellular"
					} else if path.usesInterfaceType(.wifi) {
						result = "wifi"
					} else if path.usesInterfaceType(.wiredEthernet) {
						result = "wifi"
					} else {
						result = "wifi"
					}
				} else {
					result = "none"
				}
				semaphore.signal()
			}
			
			let queue = DispatchQueue(label: "com.bearound.network.monitor")
			monitor.start(queue: queue)
			_ = semaphore.wait(timeout: .now() + 0.5)
			monitor.cancel()
			
			return result
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

	private func wifiSSID() -> String? {
		guard let interfaces = CNCopySupportedInterfaces() as? [String] else {
			return nil
		}

		for interface in interfaces {
			if let interfaceInfo = CNCopyCurrentNetworkInfo(interface as CFString) as NSDictionary?
			{
				if let ssid = interfaceInfo[kCNNetworkInfoKeySSID as String] as? String {
					return ssid
				}
			}
		}

		return nil
	}

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

	private func isAdTrackingEnabled() -> Bool {
		if #available(iOS 14, *) {
			ATTrackingManager.trackingAuthorizationStatus == .authorized
		} else {
			ASIdentifierManager.shared().isAdvertisingTrackingEnabled
		}
	}

	private func advertisingId() -> String? {
		guard isAdTrackingEnabled() else {
			return nil
		}

		let idfa = ASIdentifierManager.shared().advertisingIdentifier
		return idfa.uuidString != "00000000-0000-0000-0000-000000000000" ? idfa.uuidString : nil
	}

	private func appUptimeMs() -> Int {
		Int(Date().timeIntervalSince(appStartTime) * 1000)
	}

	private func deviceName() -> String {
		UIDevice.current.name
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

