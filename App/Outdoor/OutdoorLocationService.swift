import Foundation
import CoreLocation

/// Foreground system-fused location, not a claim of GPS-only or AR-precision positioning.
final class OutdoorLocationService: NSObject, CLLocationManagerDelegate {
    struct Fix {
        let coordinate:OutdoorCoordinate
        let accuracyM:Double
        let timestamp:Date
        let preciseAuthorization:Bool
        func isFresh(at now:Date = Date()) -> Bool { now.timeIntervalSince(timestamp) >= -2 && now.timeIntervalSince(timestamp) <= 10 }
        var canSuggestEntrance:Bool { preciseAuthorization && accuracyM <= 12 && isFresh() }
    }
    var onFix:((Fix)->Void)?
    var onHeading:((Double?)->Void)?
    var onStatus:((NavigationShellState.Status?)->Void)?
    private let manager = CLLocationManager()
    private(set) var latest:Fix?
    private(set) var heading:Double?
    private var wantsUpdates = false
    override init() {
        super.init();manager.delegate = self;manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        // Every fix, including while standing still: fixes older than 10 s count as stale, so a
        // distance filter would let the position expire whenever the person stops.
        manager.distanceFilter = kCLDistanceFilterNone;manager.activityType = .fitness
        // iOS pauses updates when it thinks the person stopped; that would let the fix go stale.
        manager.pausesLocationUpdatesAutomatically = false;manager.headingFilter = 2;manager.headingOrientation = .portrait
    }
    func start() {
        wantsUpdates = true
        switch manager.authorizationStatus {
        case .notDetermined:manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse,.authorizedAlways:beginUpdates()
        case .denied,.restricted:onStatus?(.init("定位权限未开启",detail:"仍可浏览校园；在系统设置中开启定位后再开始室外导航。",level:.attention))
        @unknown default:onStatus?(.init("定位暂不可用",level:.attention))
        }
    }
    func stop() { wantsUpdates = false;manager.stopUpdatingLocation();manager.stopUpdatingHeading() }
    private func beginUpdates() {
        guard wantsUpdates else { return }
        manager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() { manager.startUpdatingHeading() }
    }
    func locationManagerDidChangeAuthorization(_ manager:CLLocationManager) {
        guard wantsUpdates else { return }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse,.authorizedAlways:beginUpdates()
        case .denied,.restricted:latest = nil;onStatus?(.init("定位权限未开启",detail:"请在系统设置中允许定位。",level:.attention))
        default:break
        }
    }
    func locationManager(_ manager:CLLocationManager,didUpdateLocations locations:[CLLocation]) {
        guard wantsUpdates,let location = locations.last,location.horizontalAccuracy >= 0,location.horizontalAccuracy.isFinite else { return }
        let c = OutdoorCoordinate(latitude:location.coordinate.latitude,longitude:location.coordinate.longitude)
        let fix = Fix(coordinate:c,accuracyM:location.horizontalAccuracy,timestamp:location.timestamp,preciseAuthorization:manager.accuracyAuthorization == .fullAccuracy)
        guard c.isValid,fix.isFresh() else { return }
        latest = fix;onFix?(fix)
        if !fix.preciseAuthorization { onStatus?(.init("正在使用大致位置",detail:"开启精确位置可改善步行指引；请自行核对楼门。",level:.attention)) }
        else if fix.accuracyM > 25 { onStatus?(.init("当前位置精度较弱",detail:"请到开阔处等待定位改善。",level:.attention)) }
        else { onStatus?(nil) }
    }
    func locationManager(_ manager:CLLocationManager,didUpdateHeading newHeading:CLHeading) {
        guard wantsUpdates else { return }
        let value = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        heading = newHeading.headingAccuracy >= 0 && newHeading.headingAccuracy <= 25 && value.isFinite ? value : nil
        onHeading?(heading)
    }
    func locationManager(_ manager:CLLocationManager,didFailWithError error:Error) {
        guard wantsUpdates else { return };onStatus?(.init("暂时无法获取位置",detail:"可继续查看路线，请稍后重试。",level:.attention))
    }
}
