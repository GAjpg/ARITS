import UIKit
import CoreMotion

/// Outdoor executor. The coordinator retains the final room and owns manual indoor handoff.
final class OutdoorNavigationController:UIViewController {
    var onEnterIndoor:((OutdoorRoute,OutdoorTarget)->Void)?
    var onRouteReady:((OutdoorRoute)->Void)?
    var onEnd:(()->Void)?
    /// Before starting, tapping another building offers to navigate there instead
    /// (`chooseRoom`: pick its floor/room on the campus map first).
    var onRetarget:((_ building:OutdoorBuilding,_ chooseRoom:Bool)->Void)?
    /// Called once when "出发" is pressed, and on precise arrival at the door of a building-only trip.
    var onStarted:(()->Void)?
    var onArrived:((_ walkedM:Double)->Void)?
    /// Planning out of a building: the route page's round "出楼" button switches the start to a place
    /// indoors; pressing start then asks the coordinator to pick it (nil hides the button).
    var onPlanFromIndoor:(()->Void)?
    private var fromIndoor = false
    private let exitToggle = UIButton(type:.system)
    /// The outdoor leg after leaving a building: starts by itself once a precise fix arrives within
    /// 40 m of this door (satellites back near the exit), and plans from there.
    var autoStartNear:OutdoorCoordinate?
    /// Metres along the route covered so far.
    var walkedM:Double { progressHint ?? 0 }
    var canChooseRoom:((OutdoorBuilding)->Bool) = { _ in false }
    var entranceOfferRadiusM:Double = 12
    private let arView = OutdoorARView(),mapContainer = UIView()
    private let motion = CMMotionManager()
    private var miniDrag:UIPanGestureRecognizer?
    private var isAR = false,automaticMode = true,modeCandidate:Bool?,modeCandidateAt = Date.distantPast
    private var arStatus:NavigationShellState.Status?
    private var mapConstraints = [NSLayoutConstraint](),miniConstraints = [NSLayoutConstraint]()
    private let campus:OutdoorCampus,target:OutdoorTarget
    private let mapView = OutdoorCampusMapView(),shell = UnifiedNavigationShell(),location = OutdoorLocationService()
    private let compute = DispatchQueue(label:"outdoor.route",qos:.userInitiated)
    private var route:OutdoorRoute?,fix:OutdoorLocationService.Fix?,status:NavigationShellState.Status?
    private var generation = 0,searching = false,isClosing = false,started = false,arrived = false,handoffPending = false
    private var badSince:Date?,lastReroute = Date.distantPast
    private var timer:Timer?
    init(campus:OutdoorCampus,target:OutdoorTarget,initialFix:OutdoorLocationService.Fix? = nil) {
        self.campus = campus;self.target = target;fix = initialFix;super.init(nibName:nil,bundle:nil)
    }
    required init?(coder:NSCoder) { fatalError("init(coder:)") }
    override func viewDidLoad() {
        super.viewDidLoad();view.backgroundColor = NavigationPalette.canvas
        mapView.setCampus(campus);mapView.selectsBuildings = onRetarget != nil;mapView.highlightedBuildingID = target.buildingID
        mapView.onBuildingTapped = { [weak self] b in self?.offerRetarget(b) }
        for v in [arView,mapContainer,shell] { v.translatesAutoresizingMaskIntoConstraints = false;view.addSubview(v);NSLayoutConstraint.activate([v.leadingAnchor.constraint(equalTo:view.leadingAnchor),v.trailingAnchor.constraint(equalTo:view.trailingAnchor),v.topAnchor.constraint(equalTo:view.topAnchor),v.bottomAnchor.constraint(equalTo:view.bottomAnchor)]) }
        Style.round(exitToggle,symbol:"door.right.hand.open",label:"从楼内出发",size:48);exitToggle.addTarget(self,action:#selector(toggleFromIndoor),for:.touchUpInside)
        exitToggle.translatesAutoresizingMaskIntoConstraints = false;exitToggle.isHidden = onPlanFromIndoor == nil;view.addSubview(exitToggle)
        NSLayoutConstraint.activate([exitToggle.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:16),
                                     exitToggle.bottomAnchor.constraint(equalTo:view.safeAreaLayoutGuide.bottomAnchor,constant:-200)])
        // Capture the parent's full-screen constraints before replacing them for the mini map.
        mapConstraints = view.constraints.filter { ($0.firstItem as? UIView) === mapContainer || ($0.secondItem as? UIView) === mapContainer }
        // AR mini map: bottom-left, above the bottom sheet (index 2 = leading, 3 = bottom; dragged by dragMini).
        miniConstraints = [mapContainer.widthAnchor.constraint(equalToConstant:132),mapContainer.heightAnchor.constraint(equalToConstant:156),
                           mapContainer.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:16),mapContainer.bottomAnchor.constraint(equalTo:view.safeAreaLayoutGuide.bottomAnchor,constant:-150)]
        mapView.translatesAutoresizingMaskIntoConstraints = false;mapContainer.addSubview(mapView)
        NSLayoutConstraint.activate([mapView.leadingAnchor.constraint(equalTo:mapContainer.leadingAnchor),mapView.trailingAnchor.constraint(equalTo:mapContainer.trailingAnchor),mapView.topAnchor.constraint(equalTo:mapContainer.topAnchor),mapView.bottomAnchor.constraint(equalTo:mapContainer.bottomAnchor)])
        let drag = UIPanGestureRecognizer(target:self,action:#selector(dragMini(_:)));drag.maximumNumberOfTouches = 1;drag.isEnabled = false;miniDrag = drag;mapContainer.addGestureRecognizer(drag)
        arView.isHidden = true
        arView.onStatus = { [weak self] value in self?.arStatus = value;self?.render() }
        arView.onUnavailable = { [weak self] in self?.automaticMode = false;self?.setAR(false) }
        shell.onClose = { [weak self] in self?.confirmEnd() }
        shell.onMore = { [weak self] in self?.options() }
        shell.onPrimaryAction = { [weak self] in self?.primaryAction() }
        location.onFix = { [weak self] value in
            guard let self,!self.isClosing else { return };self.fix = value;self.arView.coordinate = value.coordinate;self.arView.locationUsable = value.preciseAuthorization && value.accuracyM <= 25 && value.isFresh();self.mapView.userCoordinate = value.coordinate;self.mapView.accuracyM = value.accuracyM
            if self.route == nil && !self.searching { self.plan(value) }
            else { self.updateProgress(value) };self.render()
        }
        location.onHeading = { [weak self] in self?.mapView.headingDegrees = $0;self?.arView.headingUsable = $0 != nil }
        location.onStatus = { [weak self] value in self?.status = value;self?.render() }
        if let fix,fix.isFresh() { mapView.userCoordinate = fix.coordinate;mapView.accuracyM = fix.accuracyM;mapView.recenter();plan(fix) }
        render()
    }
    override func viewWillAppear(_ animated:Bool) {
        super.viewWillAppear(animated);navigationController?.setNavigationBarHidden(true,animated:animated)
    }
    override func viewDidAppear(_ animated:Bool) {
        super.viewDidAppear(animated);guard !isClosing,!handoffPending else { return };location.start()
        startMotion();if isAR { arView.start() }
        timer?.invalidate();timer = Timer.scheduledTimer(withTimeInterval:1,repeats:true) { [weak self] _ in self?.render() }
    }
    override func viewWillDisappear(_ animated:Bool) {
        super.viewWillDisappear(animated);timer?.invalidate();timer = nil;location.stop();motion.stopDeviceMotionUpdates();arView.stop()
        navigationController?.setNavigationBarHidden(false,animated:animated)
    }
    deinit { timer?.invalidate() }
    /// Where the last failed plan started; a failed plan is retried only after moving or on request.
    private var failedAt:(coordinate:OutdoorCoordinate,time:Date)?
    private let runLog = OutdoorRunLog()
    private func plan(_ snapshot:OutdoorLocationService.Fix,force:Bool = false) {
        guard !searching,snapshot.isFresh(),!isClosing else { return }
        if !force,let f = failedAt,campus.frame.distance(f.coordinate,snapshot.coordinate) < 15,Date().timeIntervalSince(f.time) < 20 { return }
        searching = true;generation += 1;let token = generation,campus = campus,target = target
        status = .init("正在规划步行路线");render()
        compute.async { [weak self] in
            let result = OutdoorRouter(campus:campus).planDetailed(from:snapshot.coordinate,buildingID:target.buildingID,entrances:target.entrances)
            let route = result.route,nearest = result.nearestStartDistanceM
            DispatchQueue.main.async {
                guard let self,!self.isClosing,self.generation == token else { return }
                self.searching = false
                self.runLog.write(["event":route == nil ? "plan_failed" : "plan_ok","lat":snapshot.coordinate.latitude,"lon":snapshot.coordinate.longitude,
                                   "accuracy_m":snapshot.accuracyM,"precise":snapshot.preciseAuthorization,"building":target.buildingID,"title":target.title,
                                   "bound_entrances":target.entrances?.count ?? -1,"nearest_path_m":nearest ?? -1,"length_m":route?.lengthM ?? -1,
                                   "failure":result.failure?.rawValue ?? NSNull(),"start_candidates":result.startCandidateCount,"entrance_candidates":result.entranceCandidateCount])
                guard let route else {
                    self.failedAt = (snapshot.coordinate,Date())
                    let detail:String
                    if !snapshot.preciseAuthorization { detail = "当前只有大致位置。请在 设置 → LiDARProbe → 位置 中打开“精确位置”。" }
                    else {
                        switch result.failure {
                        case .startTooFar?:detail = String(format:"你距离校园步行路网约 %.0f 米（定位 ±%.0f 米），需在校园内或校门附近才能规划。",nearest ?? 0,snapshot.accuracyM)
                        case .noCandidateEdges?,.startBlocked?:detail = "你附近的路无法直接接入（可能隔着建筑），请走到路边再试。"
                        case .entranceNoAccess?:detail = "这栋楼的门还没有连到路网。请在建图工具“出入口室外坐标”中为门添加引路。"
                        case .noEntrances?:detail = "这栋楼没有可用的入口数据。"
                        case .disconnected?:detail = "你所在的路与这栋楼的入口不连通，请换一条路再试。"
                        default:detail = snapshot.accuracyM > 40 ? String(format:"定位误差约 ±%.0f 米，请到开阔处稍等再试。",snapshot.accuracyM) : "暂时无法规划，已记录本次情况。"
                        }
                    }
                    self.status = .init("无法生成到楼门的路线",detail:detail,level:.attention);self.render();return
                }
                self.failedAt = nil;self.progressHint = nil
                if !self.started { DispatchQueue.main.async { self.mapView.frameRoute(top:self.view.safeAreaInsets.top+250,bottom:self.shell.bottomInset+20) } }
                self.route = route;self.mapView.route = route;self.arView.route = route;self.badSince = nil;self.status = nil
                self.guideSteps = self.mergedSteps(route);self.arView.turns = self.guideSteps.filter { [.left,.right,.slightLeft,.slightRight,.sharpLeft,.sharpRight,.uTurn].contains($0.maneuver) }.map { ($0.distanceM,$0.maneuver) }
                self.onRouteReady?(route);if let fix = self.fix { self.updateProgress(fix) };self.render()
            }
        }
    }
    /// Progress along the route: matched only near the last progress (parallel or doubling-back paths
    /// cannot steal it), globally only for a new route.
    private var progressHint:Double?
    /// Guidance steps with turns closer than 15 m merged into one manoeuvre (net heading change),
    /// so "left then right" a few metres apart reads as one instruction; a net change under 25° drops out.
    struct GuideStep { let maneuver:NavigationManeuver;let distanceM:Double }
    private var guideSteps:[GuideStep] = []
    private func mergedSteps(_ route:OutdoorRoute) -> [GuideStep] {
        let turns:Set<NavigationManeuver> = [.left,.right,.slightLeft,.slightRight,.sharpLeft,.sharpRight,.uTurn]
        let p = route.points,f = campus.frame
        func bearing(_ i:Int,_ j:Int) -> Double { f.bearing(p[max(0,min(p.count-1,i))],p[max(0,min(p.count-1,j))]) }
        var out = [GuideStep](),i = 0,steps = route.steps
        while i < steps.count {
            let s = steps[i]
            guard turns.contains(s.maneuver) else { out.append(.init(maneuver:s.maneuver,distanceM:s.distanceFromStartM));i += 1;continue }
            var j = i
            while j+1 < steps.count,turns.contains(steps[j+1].maneuver),steps[j+1].distanceFromStartM-steps[j].distanceFromStartM < 15 { j += 1 }
            if j == i { out.append(.init(maneuver:s.maneuver,distanceM:s.distanceFromStartM)) }
            else {
                var turn = bearing(steps[j].pointIndex,steps[j].pointIndex+1)-bearing(s.pointIndex-1,s.pointIndex)
                if turn > 180 { turn -= 360 };if turn <= -180 { turn += 360 }
                let m:NavigationManeuver? = abs(turn) < 25 ? nil : abs(turn) >= 150 ? .uTurn : turn >= 100 ? .sharpRight : turn >= 45 ? .right : turn > 0 ? .slightRight
                                          : turn <= -100 ? .sharpLeft : turn <= -45 ? .left : .slightLeft
                if let m { out.append(.init(maneuver:m,distanceM:s.distanceFromStartM)) }
            }
            i = j+1
        }
        return out
    }
    private func progress(_ route:OutdoorRoute,_ c:OutdoorCoordinate) -> (alongM:Double,lateralM:Double) {
        if let h = progressHint,let p = route.projection(c,near:h,window:40) { return (p.alongM,p.lateralM) }
        let p = route.projection(c);return (p.alongM,p.lateralM)
    }
    private func updateProgress(_ fix:OutdoorLocationService.Fix) {
        guard let route,fix.isFresh() else { return }
        // Leaving a building: start on its own once satellites are back near the exit.
        if !started,let door = autoStartNear,fix.preciseAuthorization,fix.accuracyM <= 25,campus.frame.distance(fix.coordinate,door) <= 40 {
            started = true;onStarted?();exitToggle.isHidden = true;mapView.selectsBuildings = false;mapView.recenter();mapView.headingUp = true
            UINotificationFeedbackGenerator().notificationOccurred(.success);runLog.write(["event":"auto_started_after_exit","accuracy_m":fix.accuracyM])
        }
        let p = progress(route,fix.coordinate);progressHint = p.alongM;mapView.routeProgressM = p.alongM;arView.progressM = p.alongM
        if !started { return }
        if fix.accuracyM <= 40,p.lateralM > max(14,1.6*fix.accuracyM) {
            if badSince == nil { badSince = Date() }
            if Date().timeIntervalSince(badSince!) >= 4,Date().timeIntervalSince(lastReroute) >= 15,!searching {
                lastReroute = Date();plan(fix)
            }
        } else { badSince = nil }
        arrived = NavigationArrivalPolicy.reachedOutdoorDoor(distanceM:campus.frame.distance(fix.coordinate,route.entrance.coordinate),
                                                            accuracyM:fix.accuracyM,preciseAuthorization:fix.preciseAuthorization,fresh:fix.isFresh())
        // Building-only trip reached precisely: end with the summary.
        if arrived,onEnterIndoor == nil,let onArrived,!isClosing {
            runLog.write(["event":"arrived","walked_m":walkedM]);isClosing = true;generation += 1;arView.stop();motion.stopDeviceMotionUpdates();location.stop();timer?.invalidate()
            onArrived(route.lengthM)
        }
    }
    /// Offered near the door; the reach widens with GPS uncertainty (doors are where GNSS is worst).
    /// Entering only starts indoor recovery at that door, so a generous offer is safe.
    private var canEnterIndoor:Bool {
        guard started,onEnterIndoor != nil,let route,let fix,fix.isFresh() else { return false }
        let reach = max(entranceOfferRadiusM,25+min(fix.accuracyM,30))
        return campus.frame.distance(fix.coordinate,route.entrance.coordinate) <= reach
    }
    private var entranceUncertain:Bool { fix.map { !$0.preciseAuthorization || $0.accuracyM > 15 } ?? true }
    private func enterIndoorNow() {
        guard !isClosing,!handoffPending,let route,onEnterIndoor != nil else { return }
        runLog.write(["event":"enter_indoor","lat":fix?.coordinate.latitude ?? 0,"lon":fix?.coordinate.longitude ?? 0,"accuracy_m":fix?.accuracyM ?? -1,
                      "door_distance_m":fix.map { campus.frame.distance($0.coordinate,route.entrance.coordinate) } ?? -1])
        handoffPending = true;arView.stop();motion.stopDeviceMotionUpdates();render();onEnterIndoor?(route,target)
    }
    private func render() {
        guard isViewLoaded else { return }
        let live = fix?.isFresh() == true
        arView.locationUsable = live && fix?.preciseAuthorization == true && (fix?.accuracyM ?? .infinity) <= 25
        var value = NavigationShellState(destination:target.title,phase:started ? .outdoor : .preview,status:isAR ? (arStatus ?? status) : status)
        if !live {
            value.maneuver = .recover;value.status = status ?? .init("正在获取当前位置",detail:"定位就绪后显示步行指引；仍可浏览地图。",level:.attention)
            value.actionTitle = "重试定位"
        } else if let route,let fix {
            let p = progress(route,fix.coordinate),remaining = max(0,route.lengthM-p.alongM)
            let next = guideSteps.first { $0.distanceM > p.alongM+2 } ?? guideSteps.last
            value.maneuver = next?.maneuver ?? .straight
            value.maneuverDistanceM = max(0,(next?.distanceM ?? route.lengthM)-p.alongM)
            value.remainingDistanceM = remaining;value.durationSeconds = remaining/1.3;value.arrivalTime = Date().addingTimeInterval(remaining/1.3)
            if !started && autoStartNear != nil { value.actionTitle = nil;value.status = .init("走出大楼后自动开始",detail:"已到出入口，卫星定位在门口恢复后自动开始室外导航。") }
            else if !started { value.actionTitle = fromIndoor ? "从楼内位置出发" : "从当前位置出发"
                value.status = fromIndoor ? .init("从楼内出发",detail:"先在室内走到最近的大楼出入口，出门后自动接上室外导航。")
                                          : .init("目的地已选好",detail:target.destinationID == nil ? "本次指引到楼门口。" : "到楼门后手动进入室内导航。") }
            else if canEnterIndoor {
                value.maneuver = .enterIndoor;value.maneuverDistanceM = nil;value.actionTitle = "进入室内"
                value.status = entranceUncertain ? .init("请确认你已在楼门口",detail:"这里定位误差较大。到门口后点“进入室内”，从这扇门开始恢复室内位置。",level:.attention)
                                                 : .init("已到楼门口附近",detail:"进门后点“进入室内”，从这扇门开始恢复室内位置。")
            }
            else if arrived && onEnterIndoor == nil { value.phase = .arrived;value.maneuver = .arrive;value.status = .init("已到达楼门口",detail:"本次室外步行指引已完成。");value.actionTitle = "结束导航" }
            if (fix.accuracyM > 25 || !fix.preciseAuthorization) && !canEnterIndoor { value.status = status ?? .init("请核对当前位置",detail:"定位精度较弱，门口距离仅供参考。",level:.attention) }
        } else { value.maneuver = .recover;value.actionTitle = searching ? nil : "重新规划" }
        if !started && fromIndoor && autoStartNear == nil {
            value.maneuver = .start;value.actionTitle = "从楼内位置出发"
            value.status = .init("从楼内出发",detail:"先在室内走到最近的大楼出入口，出门后自动接上室外导航。")
        }
        if handoffPending { value.actionTitle = nil;value.status = .init("正在打开室内地图",detail:"目的地保持不变。") }
        shell.update(value)
        if let fix,live { shell.setChip(fix.preciseAuthorization ? String(format:"定位 ±%.0f 米",fix.accuracyM) : "大致位置",good:fix.preciseAuthorization && fix.accuracyM <= 15) }
        else { shell.setChip(nil,good:false) }
    }
    @objc private func toggleFromIndoor() {
        fromIndoor.toggle();UISelectionFeedbackGenerator().selectionChanged()
        UIView.animate(withDuration:0.2) {
            self.exitToggle.backgroundColor = self.fromIndoor ? WayfindingPalette.route : .white
            self.exitToggle.tintColor = self.fromIndoor ? .white : WayfindingPalette.ink
        }
        if !fromIndoor,!(fix?.isFresh() ?? false) { location.start() }
        render()
    }
    private func primaryAction() {
        guard !isClosing,!handoffPending else { return }
        if !started && fromIndoor { onPlanFromIndoor?();return }
        if !started,let fix,fix.isFresh(),route != nil { started = true;onStarted?();exitToggle.isHidden = true;mapView.selectsBuildings = false;mapView.recenter();mapView.headingUp = true;render();return }
        if canEnterIndoor { enterIndoorNow();return }
        if arrived,onEnterIndoor == nil { end();return }
        location.start()
        if let fix,fix.isFresh() { plan(fix,force:true) } else { status = .init("正在重新获取位置…",detail:"请稍候，拿到当前位置后会自动规划。");render() }
    }
    private func offerRetarget(_ b:OutdoorBuilding) {
        guard !started,let onRetarget,b.id != target.buildingID,!b.name.isEmpty else { mapView.highlightedBuildingID = target.buildingID;return }
        let sheet = UIAlertController(title:"改为前往「\(b.fullName)」？",message:nil,preferredStyle:.actionSheet)
        sheet.addAction(UIAlertAction(title:"导航到这栋楼",style:.default) { _ in onRetarget(b,false) })
        if canChooseRoom(b) { sheet.addAction(UIAlertAction(title:"选择楼层和教室…",style:.default) { _ in onRetarget(b,true) }) }
        sheet.addAction(UIAlertAction(title:"取消",style:.cancel) { [weak self] _ in self?.mapView.highlightedBuildingID = self?.target.buildingID })
        sheet.popoverPresentationController?.sourceView = view;sheet.popoverPresentationController?.sourceRect = CGRect(x:view.bounds.midX,y:view.bounds.midY,width:1,height:1)
        present(sheet,animated:true)
    }
    /// Coordinator entry point after indoor closes/fails, once its camera is paused.
    func resumeAfterIndoor() { resumeAfterIndoorHandoff() }
    /// Call after an unsuccessful/cancelled handoff, once the indoor camera is paused.
    func resumeAfterIndoorHandoff() {
        guard !isClosing else { return };handoffPending = false;location.start();startMotion();if isAR { arView.start() };render()
    }
    private func options() {
        let a = UIAlertController(title:"导航选项",message:nil,preferredStyle:.actionSheet)
        a.addAction(UIAlertAction(title:mapView.headingUp ? "地图正北朝上" : "地图随行旋转",style:.default) { [weak self] _ in self?.mapView.headingUp.toggle() })
        a.addAction(UIAlertAction(title:isAR ? "只看地图" : "查看实景",style:.default) { [weak self] _ in guard let self else { return };self.automaticMode = false;self.setAR(!self.isAR) })
        a.addAction(UIAlertAction(title:"自动切换地图与实景",style:.default) { [weak self] _ in self?.automaticMode = true })
        a.addAction(UIAlertAction(title:"回到当前位置",style:.default) { [weak self] _ in self?.mapView.recenter() })
        if onEnterIndoor != nil,route != nil {
            a.addAction(UIAlertAction(title:"我已到楼门口，进入室内",style:.default) { [weak self] _ in self?.started = true;self?.enterIndoorNow() })
        }
        a.addAction(UIAlertAction(title:"重新规划",style:.default) { [weak self] _ in if let self,let f = self.fix { self.plan(f,force:true) } })
        a.addAction(UIAlertAction(title:"实景箭头长度：\(Int(arView.chainLengthM)) 米",style:.default) { [weak self] _ in
            guard let self else { return }
            let pick = UIAlertController(title:"实景箭头显示多远",message:"地面箭头链从脚下向前延伸的长度，远端逐渐变淡。",preferredStyle:.actionSheet)
            for m in [5.0,10,15,20,30] { pick.addAction(UIAlertAction(title:"\(Int(m)) 米",style:.default) { [weak self] _ in self?.arView.chainLengthM = m }) }
            pick.addAction(UIAlertAction(title:"取消",style:.cancel))
            pick.popoverPresentationController?.sourceView = self.shell;pick.popoverPresentationController?.sourceRect = CGRect(x:self.view.bounds.midX,y:self.view.bounds.maxY-80,width:1,height:1)
            self.present(pick,animated:true)
        })
        a.addAction(UIAlertAction(title:"取消",style:.cancel));a.popoverPresentationController?.sourceView = shell;a.popoverPresentationController?.sourceRect = CGRect(x:view.bounds.maxX-40,y:view.safeAreaInsets.top+30,width:1,height:1);present(a,animated:true)
    }
    private func startMotion() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 0.1
        motion.startDeviceMotionUpdates(to:.main) { [weak self] data,_ in
            guard let self,!self.isClosing,self.automaticMode,self.started,let gravity = data?.gravity else { return }
            let raise = acos(min(1,abs(gravity.z)))*180 / Double.pi
            let want = self.isAR ? raise > 22 : raise >= 40
            if want == self.isAR { self.modeCandidate = nil;return }
            if self.modeCandidate != want { self.modeCandidate = want;self.modeCandidateAt = Date();return }
            if Date().timeIntervalSince(self.modeCandidateAt) >= 0.25 { self.modeCandidate = nil;self.setAR(want) }
        }
    }
    /// Map ⇄ AR: the map springs into (or out of) the corner window while the camera view fades.
    private func setAR(_ enabled:Bool) {
        guard enabled != isAR else { return };isAR = enabled
        NSLayoutConstraint.deactivate(enabled ? mapConstraints : miniConstraints)
        NSLayoutConstraint.activate(enabled ? miniConstraints : mapConstraints)
        mapView.twoFingerPan = enabled;miniDrag?.isEnabled = enabled
        mapContainer.layer.borderColor = UIColor.white.cgColor
        if enabled { arView.alpha = 0;arView.isHidden = false;arView.start() }
        let reduce = UIAccessibility.isReduceMotionEnabled
        UIView.animate(withDuration:reduce ? 0 : 0.55,delay:0,usingSpringWithDamping:0.86,initialSpringVelocity:0.3,options:[.beginFromCurrentState,.allowUserInteraction],animations:{
            self.mapContainer.layer.cornerRadius = enabled ? 20 : 0;self.mapContainer.layer.borderWidth = enabled ? 3 : 0
            self.arView.alpha = enabled ? 1 : 0;self.view.layoutIfNeeded()
        }) { _ in
            if !enabled && !self.isAR { self.arView.isHidden = true;self.arView.stop() }
        }
        mapContainer.clipsToBounds = true
        mapView.recenter();UISelectionFeedbackGenerator().selectionChanged();render()
    }
    @objc private func dragMini(_ recognizer:UIPanGestureRecognizer) {
        guard isAR else { return }
        let delta = recognizer.translation(in:view);recognizer.setTranslation(.zero,in:view)
        miniConstraints[2].constant = max(8,min(view.bounds.width-140,miniConstraints[2].constant+delta.x))
        miniConstraints[3].constant = min(-150,max(-(view.bounds.height-360),miniConstraints[3].constant+delta.y))
    }
    private func confirmEnd() {
        let a = UIAlertController(title:"结束本次室外导航？",message:"室内上次位置由室内导航单独保存。",preferredStyle:.alert)
        a.addAction(UIAlertAction(title:"继续导航",style:.cancel));a.addAction(UIAlertAction(title:"结束",style:.destructive) { [weak self] _ in self?.end() });present(a,animated:true)
    }
    private func end() {
        runLog.write(["event":"ended","started":started,"arrived":arrived])
        isClosing = true;generation += 1;arView.stop();motion.stopDeviceMotionUpdates();location.stop();timer?.invalidate();if let onEnd { onEnd();return }
        if navigationController?.viewControllers.first === self { dismiss(animated:true) } else { navigationController?.popViewController(animated:true) }
    }
}

/// Outdoor navigation events as JSON lines in Documents/OutdoorRuns (on this phone only), so a
/// failed route can be diagnosed afterwards.
final class OutdoorRunLog {
    private let url:URL?
    private let queue = DispatchQueue(label:"outdoor.runlog")
    init() {
        let dir = FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first?.appendingPathComponent("OutdoorRuns",isDirectory:true)
        if let dir { try? FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true) }
        let f = DateFormatter();f.dateFormat = "yyyyMMdd-HHmmss";f.locale = Locale(identifier:"en_US_POSIX")
        url = dir?.appendingPathComponent(f.string(from:Date())+".jsonl")
    }
    func write(_ fields:[String:Any]) {
        var record = fields;record["t"] = ISO8601DateFormatter().string(from:Date())
        guard let url,JSONSerialization.isValidJSONObject(record),let data = try? JSONSerialization.data(withJSONObject:record) else { return }
        queue.async {
            if let h = try? FileHandle(forWritingTo:url) { h.seekToEndOfFile();h.write(data+Data([10]));try? h.close() }
            else { try? (data+Data([10])).write(to:url) }
        }
    }
}
