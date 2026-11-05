import CoreLocation
import Foundation
import UIKit

/// Dedicated manager: does not replace beacon or visit delegates or request authorization.
final class ForegroundLocationRequest: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var callback: ((DeviceLocation?) -> Void)?
    var onEligibilityLost: (() -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    func eligible() -> Bool {
        let status: CLAuthorizationStatus
        if #available(iOS 14.0, *) {
            status = manager.authorizationStatus
            guard manager.accuracyAuthorization == .fullAccuracy else { return false }
        } else { status = CLLocationManager.authorizationStatus() }
        return (status == .authorizedAlways || status == .authorizedWhenInUse) &&
            CLLocationManager.locationServicesEnabled() && UIApplication.shared.applicationState == .active &&
            !ProcessInfo.processInfo.isLowPowerModeEnabled && ProcessInfo.processInfo.thermalState.rawValue < ProcessInfo.ThermalState.serious.rawValue
    }

    func request(_ completion: @escaping (DeviceLocation?) -> Void) -> () -> Void {
        guard eligible() else { completion(nil); return {} }
        callback = completion
        manager.requestLocation()
        return { [weak self] in self?.callback = nil; self?.manager.stopUpdatingLocation() }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let completion = callback; callback = nil
        guard eligible(), let fix = locations.max(by: { $0.timestamp < $1.timestamp }) else { completion?(nil); return }
        if #available(iOS 15.0, *), fix.sourceInformation?.isSimulatedBySoftware == true {
            completion?(nil); return
        }
        completion?(DeviceLocation(fix, source: "gnss"))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let completion = callback; callback = nil
        completion?(nil)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        stopIfIneligible()
    }

    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        stopIfIneligible()
    }

    private func stopIfIneligible() {
        guard !eligible() else { return }
        let completion = callback; callback = nil
        manager.stopUpdatingLocation()
        onEligibilityLost?()
        completion?(nil)
    }
}
