import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        let navigation = UINavigationController(rootViewController: LiDARHomeController())
        navigation.navigationBar.tintColor = .systemTeal
        window.rootViewController = navigation
        #if targetEnvironment(macCatalyst)
        scene.sizeRestrictions?.minimumSize = CGSize(width: 980, height: 720)
        scene.sizeRestrictions?.maximumSize = CGSize(width: 1800, height: 1200)
        #endif
        window.makeKeyAndVisible()
        self.window = window
        #if DEBUG
        UISnapshotHarness.runIfRequested(window:window,scene:scene,navigation:navigation)
        #endif
    }
}

#if DEBUG
/// Debug-only visual QA: `--ui-snapshot <screen> <png path> [zoom]` opens one screen at phone size,
/// waits for it to settle, writes a PNG and quits. Screens: `map` (the campus map view alone),
/// `campus` (the campus screen).
enum UISnapshotHarness {
    static func runIfRequested(window:UIWindow,scene:UIWindowScene,navigation:UINavigationController) {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of:"--ui-snapshot"),args.count > i+2 else { return }
        let screen = args[i+1],out = URL(fileURLWithPath:args[i+2]),zoom = args.count > i+3 ? Double(args[i+3]) ?? 1 : 1
        #if targetEnvironment(macCatalyst)
        scene.sizeRestrictions?.minimumSize = CGSize(width:390,height:844);scene.sizeRestrictions?.maximumSize = CGSize(width:390,height:844)
        #endif
        switch screen {
        case "campus-data":
            navigation.setViewControllers([CampusMapDataController(directory:FileManager.default.temporaryDirectory.appendingPathComponent("campus-data-snapshot-"+UUID().uuidString))],animated:false)

        case "transfer-nearby":
            let host = UIViewController();host.view.backgroundColor = UIColor(red:0.29,green:0.32,blue:0.30,alpha:1)
            let shell = UnifiedNavigationShell();shell.frame = host.view.bounds;shell.autoresizingMask = [.flexibleWidth,.flexibleHeight];host.view.addSubview(shell)
            var state = NavigationShellState(destination:"会议中心 · 305",phase:.indoor)
            state.maneuver = .straight;state.maneuverDistanceM = 12;state.remainingDistanceM = 12;state.floorLabel = "2F"
            state.actionTitle = "我已到达电梯厅"
            shell.update(state);shell.setChip("位置已确认",good:true)
            navigation.setViewControllers([host],animated:false);navigation.setNavigationBarHidden(true,animated:false)
        case "map":
            let host = UIViewController(),map = OutdoorCampusMapView()
            map.frame = host.view.bounds;map.autoresizingMask = [.flexibleWidth,.flexibleHeight];host.view.addSubview(map)
            if let campus = LiDARTripCoordinator.bundledCampus() { map.setCampus(campus) }
            navigation.setViewControllers([host],animated:false);navigation.setNavigationBarHidden(true,animated:false)
            DispatchQueue.main.asyncAfter(deadline:.now()+1) { map.zoom(CGFloat(zoom)) }
        case "campus":
            let trip = LiDARTripCoordinator(host:navigation);objc_setAssociatedObject(navigation,"trip",trip,.OBJC_ASSOCIATION_RETAIN)
            navigation.setViewControllers([trip.makeCampusController()],animated:false)
        case "outdoor":
            // A fixed test position on a campus path, so the route and cards render without GNSS.
            guard let campus = LiDARTripCoordinator.bundledCampus(),let b = campus.buildings.first(where: { $0.name.contains("图书馆") }) else { break }
            let n = campus.graph.nodes[campus.graph.nodes.count/3]
            let fix = OutdoorLocationService.Fix(coordinate:n,accuracyM:6,timestamp:Date().addingTimeInterval(2),preciseAuthorization:true)
            navigation.setViewControllers([OutdoorNavigationController(campus:campus,target:OutdoorTarget(buildingID:b.id,title:b.label),initialFix:fix)],animated:false)
        case "pick-access":
            // Access path editing with a sample door on 教学中心 and one bend drawn.
            guard let campus = LiDARTripCoordinator.bundledCampus(),let b = campus.buildings.first(where: { $0.name.contains("教学中心") }),let door = b.entrances.first?.coordinate else { break }
            let d = campus.frame.local(door)
            let bend = campus.frame.coordinate(east:d.east-18,north:d.north+6),end = campus.frame.coordinate(east:d.east-30,north:d.north+16)
            navigation.setViewControllers([CampusPickController(campus:campus,mode:.accessPath(door:door,doorName:"南门",buildingOSM:b.id,existing:[door,bend,end]))],animated:false)
        case "pick-building","pick-door":
            guard let campus = LiDARTripCoordinator.bundledCampus(),let b = campus.buildings.first(where: { $0.name.contains("教学中心") }) else { break }
            let mode:CampusPickController.Mode = screen == "pick-building" ? .building(currentOSM:b.id) : .door(buildingOSM:b.id,current:b.entrances.first?.coordinate)
            navigation.setViewControllers([CampusPickController(campus:campus,mode:mode)],animated:false)
        case "shell-collect","shell-indoor":
            // The shell's indoor states over a dark stand-in for the camera (layout check only).
            let host = UIViewController();host.view.backgroundColor = UIColor(red:0.29,green:0.32,blue:0.30,alpha:1)
            let shell = UnifiedNavigationShell();shell.frame = host.view.bounds;shell.autoresizingMask = [.flexibleWidth,.flexibleHeight];host.view.addSubview(shell)
            var v = NavigationShellState(destination:"示例 201",phase:screen == "shell-collect" ? .indoorRecovery : .indoor)
            if screen == "shell-collect" {
                v.maneuver = .recover;v.headline = "缓慢环顾四周";v.status = .init("正在识别周围环境",detail:"已采集 12/32 帧 · 墙角、门框和地面最有用");v.actionTitle = "结束采集并定位"
            } else {
                v.maneuver = .right;v.maneuverDistanceM = 12;v.remainingDistanceM = 38;v.durationSeconds = 32;v.arrivalTime = Date().addingTimeInterval(32);v.floorLabel = "2F · 全层"
            }
            shell.update(v);shell.setChip(screen == "shell-collect" ? nil : "位置已确认",good:true)
            navigation.setViewControllers([host],animated:false);navigation.setNavigationBarHidden(true,animated:false)
        case "elevator-card","turn-guide":
            // Indoor shell over a dark camera stand-in with the elevator card (grey: connecting) or the turn guide.
            let host = UIViewController();host.view.backgroundColor = UIColor(red:0.29,green:0.32,blue:0.30,alpha:1)
            let shell = UnifiedNavigationShell();shell.frame = host.view.bounds;shell.autoresizingMask = [.flexibleWidth,.flexibleHeight];host.view.addSubview(shell)
            var v = NavigationShellState(destination:"示例 305",phase:screen == "turn-guide" ? .indoorRecovery : .indoor)
            if screen == "turn-guide" { v.maneuver = .recover;v.headline = "缓慢环顾四周";v.status = .init("正在识别周围环境",detail:"已采集 6/32 帧");v.actionTitle = "结束采集并定位" }
            else { v.maneuver = .elevatorUp;v.headline = "乘电梯到 3F";v.remainingDistanceM = 12;v.durationSeconds = 10;v.arrivalTime = Date().addingTimeInterval(10);v.floorLabel = "2F" }
            shell.update(v)
            if screen == "turn-guide" {
                let guide = TurnGuideView();guide.translatesAutoresizingMaskIntoConstraints = false;host.view.addSubview(guide)
                NSLayoutConstraint.activate([guide.centerXAnchor.constraint(equalTo:host.view.centerXAnchor),guide.centerYAnchor.constraint(equalTo:host.view.centerYAnchor,constant:-20)])
                DispatchQueue.main.async { guide.setVisible(true) }
            } else {
                let ready = ElevatorCallCard(),grey = ElevatorCallCard()
                for (c,bottom) in [(grey,-150.0),(ready,-380.0)] {
                    c.translatesAutoresizingMaskIntoConstraints = false;host.view.addSubview(c)
                    NSLayoutConstraint.activate([c.trailingAnchor.constraint(equalTo:host.view.trailingAnchor,constant:-16),c.bottomAnchor.constraint(equalTo:host.view.safeAreaLayoutGuide.bottomAnchor,constant:bottom)])
                }
                grey.update(.init(elevatorName:"2 号电梯",carFloor:nil,direction:.up,phase:.connecting,canCall:false))
                ready.update(.init(elevatorName:"2 号电梯",carFloor:nil,direction:.up,phase:.ready,canCall:true))
                DispatchQueue.main.async { grey.setVisible(true);ready.setVisible(true) }
            }
            navigation.setViewControllers([host],animated:false);navigation.setNavigationBarHidden(true,animated:false)
        case "elevator-panel":
            // The Android-style elevator page over the indoor shell (sample floors; car shown on your floor).
            let host = UIViewController();host.view.backgroundColor = UIColor(red:0.29,green:0.32,blue:0.30,alpha:1)
            let shell = UnifiedNavigationShell();shell.frame = host.view.bounds;shell.autoresizingMask = [.flexibleWidth,.flexibleHeight];host.view.addSubview(shell)
            var v = NavigationShellState(destination:"示例 305",phase:.indoor);v.maneuver = .elevatorUp;v.headline = "乘电梯到 4F";v.floorLabel = "2F";shell.update(v)
            let panel = ElevatorPanel();panel.frame = host.view.bounds;panel.autoresizingMask = [.flexibleWidth,.flexibleHeight];host.view.addSubview(panel)
            panel.update(.init(elevatorName:"2 号电梯",floors:["1F","2F","3F","4F"].map { .init(name:$0,hasDevice:$0 == "2F" || $0 == "3F") },
                               current:1,destination:3,direction:.up,phase:.ready,canCall:true,deviceName:"ELEV-2F"))
            DispatchQueue.main.async { panel.setVisible(true) }
            navigation.setViewControllers([host],animated:false);navigation.setNavigationBarHidden(true,animated:false)
        case "exit-route":
            // Route page with planning out of a building switched on.
            guard let campus = LiDARTripCoordinator.bundledCampus(),let b = campus.buildings.first(where: { $0.name.contains("图书馆") }) else { break }
            let nav = OutdoorNavigationController(campus:campus,target:OutdoorTarget(buildingID:b.id,title:b.label))
            nav.onPlanFromIndoor = {}
            navigation.setViewControllers([nav],animated:false)
            DispatchQueue.main.asyncAfter(deadline:.now()+1) { nav.view.subviews.compactMap { $0 as? UIButton }.first?.sendActions(for:.touchUpInside) }
        case "start-picker":
            guard let campus = LiDARTripCoordinator.bundledCampus(),let b = campus.buildings.first(where: { $0.name.contains("会议中心") }) else { break }
            let page = OutdoorCampusController(campus:campus);page.pickStartMode = true;page.automaticallyStartsLocation = false
            page.floorsForBuilding = { b in [OutdoorFloorOption(id:"2F",name:"2F",indoorBound:true,destinations:["示例 201","示例 208"].map { OutdoorTarget(buildingID:b.id,title:$0,destinationID:$0) })] }
            page.lastIndoor = (b.id,"示例 208",OutdoorTarget(buildingID:b.id,title:"示例 208",destinationID:"x"))
            navigation.setViewControllers([page],animated:false)
            DispatchQueue.main.asyncAfter(deadline:.now()+1) { page.open(b) }
        case "summary":
            guard let campus = LiDARTripCoordinator.bundledCampus() else { break }
            navigation.setViewControllers([OutdoorCampusController(campus:campus)],animated:false)
            DispatchQueue.main.asyncAfter(deadline:.now()+0.6) {
                navigation.present(TripSummaryController(.init(destination:"会议中心 · 示例 208",started:Date().addingTimeInterval(-7*60),outdoorM:412,indoorM:38,floorChanges:1)),animated:false)
            }
        case "campus-card":
            // Sample floors and rooms for layout review only (never shown outside this debug option).
            guard let campus = LiDARTripCoordinator.bundledCampus(),let b = campus.buildings.first(where: { $0.name.contains("教学中心") }) else { break }
            let page = OutdoorCampusController(campus:campus);page.automaticallyStartsLocation = false
            page.floorsForBuilding = { b in
                ["1F","2F","3F"].map { f in OutdoorFloorOption(id:f,name:f,indoorBound:true,destinations:["示例 \(f.prefix(1))01","示例 \(f.prefix(1))05 报告厅","示例 \(f.prefix(1))12"].map { OutdoorTarget(buildingID:b.id,title:$0) }) }
                + [OutdoorFloorOption(id:"4F",name:"4F",indoorBound:false,destinations:[])]
            }
            // Two sample doors on the building's outline.
            page.doorsForBuilding = { b in b.entrances.prefix(2).enumerated().map { (["南门","东门"][$0.offset],$0.element.coordinate) } }
            navigation.setViewControllers([page],animated:false)
            DispatchQueue.main.asyncAfter(deadline:.now()+1) { page.open(b) }
        case "elevator-bindings","elevator-binding-edit":
            navigation.setViewControllers([ElevatorBindingController.snapshot(showEditor:screen == "elevator-binding-edit")],animated:false)
            navigation.setNavigationBarHidden(true,animated:false)
        case "floorplan-mini","floorplan-full":
            let root = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("work/space-workbench/space-projects")
            let projects = ((try? FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil)) ?? []).sorted { a,b in
                let ap = a.lastPathComponent.hasPrefix("B463D9B8"),bp = b.lastPathComponent.hasPrefix("B463D9B8")
                return ap != bp ? ap : a.lastPathComponent < b.lastPathComponent
            }
            var sample:(LiDARNavigationMap,LiDARSpaceGrid,[LiDARStructureLine],[ProbePoint],String)?
            for project in projects {
                let dir = project.appendingPathComponent("map")
                guard let (map,points) = try? LiDARNavigationArchive.load(dir) else { continue }
                let trajectory = try? JSONDecoder().decode(LiDARWalkedTrajectory.self,from:Data(contentsOf:dir.appendingPathComponent("walked-trajectory.json")))
                // The workbench saves edits beside map/, separately from its immutable imported map.
                let calibration = (try? LiDARPassageCalibration.load(project,mapID:map.map_id))
                    ?? (try? LiDARPassageCalibration.load(dir,mapID:map.map_id))
                guard let grid = try? LiDARSpaceGrid.build(points:points,trajectory:trajectory,calibration:calibration) else { continue }
                for a in map.nodes {
                    for b in map.nodes where b.id != a.id {
                        let route = LiDARSpacePlanner.route(grid,from:(a.position.x,a.position.z),to:(b.position.x,b.position.z))
                        if route.status == "ok",(route.length_m ?? 0) >= 12,route.points.count >= 3 {
                            sample = (map,grid,LiDARStructureLines.extract(points),route.points.map { ProbePoint($0[0],grid.floorY,$0[1]) },b.name);break
                        }
                    }
                    if sample != nil { break }
                }
                if sample != nil { break }
            }
            guard let sample else { print("floorplan snapshot: no real map with a connected sample route");break }
            let host = UIViewController();host.view.backgroundColor = WayfindingPalette.building
            let floor = IndoorFloorPlanView();floor.translatesAutoresizingMaskIntoConstraints = false;host.view.addSubview(floor)
            let mini = screen == "floorplan-mini"
            floor.compact = mini;floor.setFloor(grid:sample.1,walls:sample.2,rooms:sample.0.nodes);floor.route = sample.3
            guard let geometry = try? CampusRouteGeometry(points:sample.3) else { break };let progress = min(4,geometry.length*0.2)
            floor.progressM = progress;floor.position = geometry.point(at:progress);floor.destination = sample.3.last
            let ahead = geometry.point(at:progress+0.5),here = geometry.point(at:progress)
            floor.headingRad = atan2(ahead.x-here.x,-(ahead.z-here.z));floor.headingUp = mini
            let shell = UnifiedNavigationShell();shell.translatesAutoresizingMaskIntoConstraints = false;host.view.addSubview(shell)
            var value = NavigationShellState(destination:sample.4,phase:.indoor)
            if let turn = geometry.nextTurn(progress:progress) {
                value.maneuver = turn.direction == .right ? .right : turn.direction == .left ? .left : .uTurn
                value.maneuverDistanceM = max(0,turn.distance-progress)
            } else { value.maneuver = .straight;value.maneuverDistanceM = geometry.length-progress }
            value.remainingDistanceM = geometry.length-progress;value.floorLabel = "楼层地图"
            shell.update(value);shell.setChip("位置已确认",good:true)
            NSLayoutConstraint.activate([shell.leadingAnchor.constraint(equalTo:host.view.leadingAnchor),shell.trailingAnchor.constraint(equalTo:host.view.trailingAnchor),shell.topAnchor.constraint(equalTo:host.view.topAnchor),shell.bottomAnchor.constraint(equalTo:host.view.bottomAnchor)])
            var miniBottom:NSLayoutConstraint?
            if mini {
                let bottom = floor.bottomAnchor.constraint(equalTo:host.view.bottomAnchor,constant:-130);miniBottom = bottom
                NSLayoutConstraint.activate([floor.widthAnchor.constraint(equalToConstant:132),floor.heightAnchor.constraint(equalToConstant:156),floor.leadingAnchor.constraint(equalTo:host.view.safeAreaLayoutGuide.leadingAnchor,constant:16),bottom])
            } else {
                NSLayoutConstraint.activate([floor.leadingAnchor.constraint(equalTo:host.view.leadingAnchor),floor.trailingAnchor.constraint(equalTo:host.view.trailingAnchor),floor.topAnchor.constraint(equalTo:host.view.topAnchor),floor.bottomAnchor.constraint(equalTo:host.view.bottomAnchor)])
            }
            navigation.setViewControllers([host],animated:false);navigation.setNavigationBarHidden(true,animated:false)
            DispatchQueue.main.asyncAfter(deadline:.now()+0.2) {
                host.view.layoutIfNeeded();miniBottom?.constant = -(shell.bottomInset+16);host.view.layoutIfNeeded()
                if !mini { floor.frameRoute(top:host.view.safeAreaInsets.top+200,bottom:shell.bottomInset+24) }
            }
            print("floorplan snapshot source: \(sample.0.map_id), \(sample.1.spec.width)×\(sample.1.spec.height), route \(geometry.length)m")
        default:break
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+3) {
            let image = UIGraphicsImageRenderer(bounds:window.bounds).image { _ in window.drawHierarchy(in:window.bounds,afterScreenUpdates:true) }
            try? image.pngData()?.write(to:out);exit(0)
        }
    }
}
#endif
