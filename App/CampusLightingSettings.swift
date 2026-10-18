import UIKit
import CoreLocation

/// Main-thread settings. Approximate coordinates are local, per building, and never uploaded.
final class CampusLightingSettings:NSObject,CLLocationManagerDelegate {
    static let shared = CampusLightingSettings()
    private let defaults = UserDefaults.standard
    private var pending:((Result<CampusSunLocation,Error>)->Void)?
    private var pendingBuildingID:String?
    private var timeout:DispatchWorkItem?
    private lazy var manager:CLLocationManager = {
        let value = CLLocationManager();value.delegate = self;value.desiredAccuracy = kCLLocationAccuracyThreeKilometers;return value
    }()
    func preference(_ buildingID:String) -> CampusLightingPreference {
        guard let data = defaults.data(forKey:"campus.sunlight."+buildingID),let p = try? JSONDecoder().decode(CampusLightingPreference.self,from:data) else { return CampusLightingPreference() }
        return p
    }
    func save(_ p:CampusLightingPreference,buildingID:String) { if let data = try? JSONEncoder().encode(p) { defaults.set(data,forKey:"campus.sunlight."+buildingID) } }
    func preferredLighting(_ buildingID:String,at date:Date = Date()) -> CampusLighting { preference(buildingID).preferredLighting(at:date) }
    func summary(_ buildingID:String,at date:Date = Date()) -> String {
        let p = preference(buildingID),light = p.preferredLighting(at:date).title
        guard p.mode == .automatic else { return p.mode.title+"（手动）" }
        guard let location = p.location,let day = try? CampusDaylight.day(containing:date,location:location) else { return "\(light)优先 · 未设地点，暂按当地 06:00–18:00" }
        let formatter = DateFormatter();formatter.locale = Locale(identifier:"en_US_POSIX");formatter.timeZone = TimeZone(identifier:location.time_zone);formatter.dateFormat = "HH:mm"
        let rise = day.sunrise.map { formatter.string(from:$0) } ?? "无",set = day.sunset.map { formatter.string(from:$0) } ?? "无"
        return "\(light)优先 · 日出 \(rise) / 日落 \(set)"
    }
    func prepareForNavigation(_ buildingID:String,completion:@escaping()->Void) {
        let p = preference(buildingID)
        guard p.mode == .automatic,p.location?.isValid != true else { completion();return }
        requestCurrentLocation(buildingID:buildingID) { _ in completion() }
    }
    func requestCurrentLocation(buildingID:String,completion:@escaping(Result<CampusSunLocation,Error>)->Void) {
        guard pending == nil else { completion(.failure(CampusError.invalid("正在获取当地位置，请稍候。")));return }
        pending = completion;pendingBuildingID = buildingID
        switch manager.authorizationStatus {
        case .notDetermined:manager.requestWhenInUseAuthorization()
        case .authorizedAlways,.authorizedWhenInUse:requestFix()
        default:finish(.failure(CampusError.invalid("未获定位权限，可手动设置当地经纬度；自动模式暂用 06:00–18:00。")))
        }
    }
    func locationManagerDidChangeAuthorization(_ manager:CLLocationManager) {
        guard pending != nil else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways,.authorizedWhenInUse:requestFix()
        case .restricted,.denied:finish(.failure(CampusError.invalid("没有获取当地位置，可手动填写经纬度或选择白天／夜间优先。")))
        default:break
        }
    }
    private func requestFix() {
        guard timeout == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.finish(.failure(CampusError.invalid("获取当地位置超时，可手动填写经纬度。"))) }
        timeout = work;DispatchQueue.main.asyncAfter(deadline:.now()+8,execute:work)
        manager.requestLocation()
    }
    func locationManager(_ manager:CLLocationManager,didUpdateLocations locations:[CLLocation]) {
        guard pending != nil else { return }
        guard let value = locations.last(where: { $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy <= 50_000 && abs($0.timestamp.timeIntervalSinceNow) <= 300 && CLLocationCoordinate2DIsValid($0.coordinate) }) else { finish(.failure(CampusError.invalid("暂时无法获取有效的大致位置，可手动设置。")));return }
        let location = CampusSunLocation(latitude:(value.coordinate.latitude*100).rounded()/100,longitude:(value.coordinate.longitude*100).rounded()/100,timeZone:.current)
        if let buildingID = pendingBuildingID { var p = preference(buildingID);p.location = location;save(p,buildingID:buildingID) }
        finish(.success(location))
    }
    func locationManager(_ manager:CLLocationManager,didFailWithError error:Error) { finish(.failure(error)) }
    private func finish(_ result:Result<CampusSunLocation,Error>) {
        timeout?.cancel();timeout = nil;manager.stopUpdatingLocation()
        let callback = pending;pending = nil;pendingBuildingID = nil;callback?(result)
    }
}

final class CampusLightingSettingsController:UITableViewController {
    private let buildingID:String
    private var busy = false
    private let settings = CampusLightingSettings.shared
    init(buildingID:String) { self.buildingID = buildingID;super.init(style:.insetGrouped);title = "昼夜恢复偏好" }
    required init?(coder:NSCoder) { fatalError("init(coder:)") }
    override func numberOfSections(in tableView:UITableView) -> Int { 3 }
    override func tableView(_ tableView:UITableView,numberOfRowsInSection section:Int) -> Int { section == 0 ? 3 : section == 1 ? 3 : 1 }
    override func tableView(_ tableView:UITableView,titleForHeaderInSection section:Int) -> String? { ["恢复顺序","日出日落的当地位置","当前判断"][section] }
    override func tableView(_ tableView:UITableView,titleForFooterInSection section:Int) -> String? {
        section == 0 ? "先匹配附近节点的覆盖范围，再优先尝试当前光照，失败后仍尝试其他光照。手动指定某个子环境时按指定执行。" : section == 1 ? "只需要大致经纬度，在本机离线估算每天日出日落，不用于室内定位。按楼栋在本机保存；无地点时暂按设备当地 06:00–18:00。日光不代表室内实际照明，可手动切换偏好。" : nil
    }
    override func tableView(_ tableView:UITableView,cellForRowAt path:IndexPath) -> UITableViewCell {
        let c = UITableViewCell(style:.subtitle,reuseIdentifier:nil),p = settings.preference(buildingID)
        if path.section == 0 {
            let mode = CampusLightingMode.allCases[path.row];c.textLabel?.text = mode.title;c.accessoryType = p.mode == mode ? .checkmark : .none
        } else if path.section == 1 {
            c.textLabel?.text = ["使用当前位置设置","手动设置经纬度与时区","清除当地位置"][path.row]
            if path.row == 0 { c.detailTextLabel?.text = p.location.map { String(format:"纬度 %.2f，经度 %.2f · %@",$0.latitude,$0.longitude,$0.time_zone) } ?? "首次使用需允许获取大致位置" }
            c.accessoryType = .disclosureIndicator
        } else { c.textLabel?.text = settings.summary(buildingID);c.textLabel?.numberOfLines = 0 }
        c.isAccessibilityElement = true
        c.accessibilityLabel = (c.textLabel?.text ?? "")+(c.detailTextLabel?.text.map { "，"+$0 } ?? "")
        if path.section < 2 { c.accessibilityTraits = path.section == 0 && p.mode == CampusLightingMode.allCases[path.row] ? [.button,.selected] : .button }
        return c
    }
    override func tableView(_ tableView:UITableView,didSelectRowAt path:IndexPath) {
        tableView.deselectRow(at:path,animated:true);guard !busy else { return }
        if path.section == 0 { var p = settings.preference(buildingID);p.mode = CampusLightingMode.allCases[path.row];settings.save(p,buildingID:buildingID);tableView.reloadData() }
        else if path.section == 1 {
            switch path.row {
            case 0:
                busy = true;title = "正在获取当地位置…"
                settings.requestCurrentLocation(buildingID:buildingID) { [weak self] result in
                    guard let self else { return };self.busy = false;self.title = "昼夜恢复偏好";self.tableView.reloadData()
                    if case .failure(let error) = result { self.campusError(error) }
                }
            case 1:editLocation()
            default:var p = settings.preference(buildingID);p.location = nil;settings.save(p,buildingID:buildingID);tableView.reloadData()
            }
        }
    }
    private func editLocation() {
        let p = settings.preference(buildingID),a = UIAlertController(title:"当地经纬度与时区",message:"纬度北正南负，经度东正西负；时区使用系统标识，例如 Asia/Shanghai。",preferredStyle:.alert)
        a.addTextField { $0.placeholder = "纬度，例如 31.23";$0.text = p.location.map { String($0.latitude) };$0.keyboardType = .numbersAndPunctuation }
        a.addTextField { $0.placeholder = "经度，例如 121.47";$0.text = p.location.map { String($0.longitude) };$0.keyboardType = .numbersAndPunctuation }
        a.addTextField { $0.placeholder = "时区";$0.text = p.location?.time_zone ?? TimeZone.current.identifier;$0.autocapitalizationType = .none;$0.autocorrectionType = .no }
        a.addAction(UIAlertAction(title:"取消",style:.cancel))
        a.addAction(UIAlertAction(title:"保存",style:.default) { [weak self] _ in
            guard let self else { return }
            let fields = (a.textFields ?? []).map { ($0.text ?? "").trimmingCharacters(in:.whitespacesAndNewlines) }
            guard fields.count == 3,let lat = Double(fields[0]),let lon = Double(fields[1]),let zone = TimeZone(identifier:fields[2]) else { self.campusMessage("未保存","请输入有效经纬度和时区。");return }
            let location = CampusSunLocation(latitude:lat,longitude:lon,timeZone:zone)
            guard location.isValid else { self.campusMessage("未保存","纬度范围为 -90 到 90，经度为 -180 到 180。");return }
            var updated = self.settings.preference(self.buildingID);updated.location = location;self.settings.save(updated,buildingID:self.buildingID);self.tableView.reloadData()
        });present(a,animated:true)
    }
}
