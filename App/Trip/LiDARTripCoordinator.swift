import UIKit

/// One trip from the outdoor campus map into indoor navigation (stage P2: manual entry through a
/// bound door). It owns the destination for the whole trip; the outdoor and indoor screens are its
/// legs and never pick a new destination themselves.
///
/// - Floors and rooms shown for an outdoor building come from the indoor library: the building must
///   be bound to its OpenStreetMap id, and a room is listed only when its map is reachable (through
///   cross-map links) from a map with a bound entrance that has an outdoor position.
/// - Without that, the building has no floors here and outdoor navigation ends at its door.
/// - "Enter indoor" uses the bound entrance nearest the outdoor route's door as the start prior.
final class LiDARTripCoordinator {
    private weak var host:UINavigationController?
    private let campus:OutdoorCampus?
    /// A snapshot of the library taken when the campus screen opens.
    private struct Directory {
        var maps:[String:(URL,LiDARNavigationMap)] = [:]
        var placements:[String:LiDARMapPlacement] = [:]
        var catalog = LiDARCampusCatalog()
        var bindings = LiDARCampusBindings()
        var links:[LiDARMapLink] = []
    }
    private var directory = Directory()
    /// Destination ids handed to the outdoor screen → the indoor nodes they mean (this trip only).
    private var destinationNodes:[String:[LiDARNodeRef]] = [:]
    private var trip:(target:OutdoorTarget,revision:Int)?
    private var tripStarted:Date?,outdoorWalkedM:Double?
    private weak var outdoorScreen:OutdoorNavigationController?
    private weak var campusScreen:OutdoorCampusController?
    private var revision = 0

    init(host:UINavigationController,campus:OutdoorCampus? = LiDARTripCoordinator.bundledCampus()) { self.host = host;self.campus = campus }
    static func bundledCampus() -> OutdoorCampus? {
        let store = OutdoorCampusStorage(directory:ProbeIO.documents.appendingPathComponent("CampusMap",isDirectory:true))
        return try? store.current(bundled:OutdoorCampusStorage.packagedData()).campus
    }

    func makeCampusController() -> OutdoorCampusController {
        reloadDirectory()
        let c = OutdoorCampusController(campus:campus)
        c.floorsForBuilding = { [weak self] b in self?.floors(for:b) ?? [] }
        c.onTargetSelected = { [weak self] t in self?.startOutdoor(t) }
        c.doorsForBuilding = { [weak self] b in self?.doorMarkers(for:b) ?? [] }
        c.accessPathsForBuilding = { [weak self] b in
            guard let self,let id = self.directory.bindings.building(forOSM:b.id) else { return [] }
            return self.doors(id).compactMap { $0.access_path?.map { OutdoorCoordinate(latitude:$0.lat,longitude:$0.lon) } }
        }
        campusScreen = c
        return c
    }
    private func reloadDirectory() {
        var d = Directory()
        for (url,map) in LiDARNavigationStore.maps() {
            d.maps[map.map_id] = (url,map)
            if case .placed(let p) = LiDARMapPlacement.load(url,mapID:map.map_id) { d.placements[map.map_id] = p }
        }
        d.catalog = (try? LiDARCampusCatalog.load(root:LiDARLibrary.root)) ?? LiDARCampusCatalog()
        d.bindings = (try? LiDARCampusBindings.load(root:LiDARLibrary.root)) ?? LiDARCampusBindings()
        d.links = ((try? LiDARCampusLinks.load(root:LiDARLibrary.root)) ?? LiDARCampusLinks()).resolvingElevatorGroups().links.usable(maps:d.maps.mapValues(\.1))
        directory = d
    }
    /// Bound entrances of a catalog building that have an outdoor position and still resolve to an exit node.
    private func doors(_ buildingID:String) -> [LiDARCampusBindings.Entrance] {
        directory.bindings.entrances(ofBuilding:buildingID).filter { e in
            e.position != nil && directory.maps[e.node.map_id]?.1.nodes.contains { $0.id == e.node.node_id && $0.resolvedKind == .exit } == true
        }
    }
    /// Maps reachable from `start` through usable links (including itself).
    private func reachable(from start:Set<String>) -> Set<String> {
        var seen = start,frontier = Array(start)
        while let m = frontier.popLast() {
            for l in directory.links where l.a.map_id == m || (l.bidirectional && l.b.map_id == m) {
                let other = l.a.map_id == m ? l.b.map_id : l.a.map_id
                if seen.insert(other).inserted { frontier.append(other) }
            }
        }
        return seen
    }
    /// Named bound doors of an outdoor building, for the campus map.
    func doorMarkers(for b:OutdoorBuilding) -> [(name:String,coordinate:OutdoorCoordinate)] {
        guard let id = directory.bindings.building(forOSM:b.id) else { return [] }
        return doors(id).compactMap { e in
            guard let p = e.position else { return nil }
            let name = directory.maps[e.node.map_id]?.1.nodes.first { $0.id == e.node.node_id }?.name ?? "入口"
            return (name,OutdoorCoordinate(latitude:p.lat,longitude:p.lon))
        }
    }
    func floors(for b:OutdoorBuilding) -> [OutdoorFloorOption] {
        guard let id = directory.bindings.building(forOSM:b.id),let building = directory.catalog.building(id) else { return [] }
        let entrances = doors(id)
        // Each bound door with its drawn access path (door first), which routing follows to the door.
        let outdoorDoors = entrances.compactMap { e in e.position.map { p in
            OutdoorEntrance(coordinate:OutdoorCoordinate(latitude:p.lat,longitude:p.lon),nodeIndex:-1,bindingID:e.id,
                            accessPath:e.access_path?.map { OutdoorCoordinate(latitude:$0.lat,longitude:$0.lon) })
        } }
        let open = reachable(from:Set(entrances.map(\.node.map_id)))
        return building.sortedFloors.map { floor in
            var byName:[String:[LiDARNodeRef]] = [:],order:[String] = []
            let onFloor = directory.placements.filter { $0.value.floor_id == floor.id }.keys.sorted()
            for mapID in onFloor where open.contains(mapID) {
                guard let map = directory.maps[mapID]?.1 else { continue }
                for g in map.namedChoices().rooms {
                    if byName[g.name] == nil { order.append(g.name) }
                    byName[g.name,default:[]] += g.nodeIDs.map { LiDARNodeRef(map:mapID,node:$0) }
                }
            }
            let targets = order.map { name -> OutdoorTarget in
                let key = "\(floor.id)|\(name)";destinationNodes[key] = byName[name]
                return OutdoorTarget(buildingID:b.id,title:name,destinationID:key,floorID:floor.id,entrances:outdoorDoors)
            }
            return OutdoorFloorOption(id:floor.id,name:floor.name,indoorBound:!targets.isEmpty,destinations:targets)
        }
    }
    private func startOutdoor(_ target:OutdoorTarget,leavingAt door:OutdoorCoordinate? = nil,indoorSoFarM:Double? = nil,floorsSoFar:Int = 0) {
        guard let campus,let host else { return }
        var target = target
        // "Navigate to this building" of a bound building also uses its real doors and access paths.
        if target.entrances == nil,let id = directory.bindings.building(forOSM:target.buildingID) {
            let bound = doors(id).compactMap { e in e.position.map { p in
                OutdoorEntrance(coordinate:OutdoorCoordinate(latitude:p.lat,longitude:p.lon),nodeIndex:-1,bindingID:e.id,
                                accessPath:e.access_path?.map { OutdoorCoordinate(latitude:$0.lat,longitude:$0.lon) }) } }
            if !bound.isEmpty { target.entrances = bound }
        }
        revision += 1;trip = (target,revision)
        // Start from the campus screen's fix so planning does not wait for a new one.
        let nav = OutdoorNavigationController(campus:campus,target:target,initialFix:campusScreen?.latestFix)
        // Only a room target with a bound entrance can hand over; a building target ends at its door.
        if target.destinationID != nil {
            let token = revision
            nav.onEnterIndoor = { [weak self,weak nav] route,target in
                guard let self,let nav,self.trip?.revision == token else { nav?.resumeAfterIndoor();return }
                self.outdoorWalkedM = nav.walkedM
                self.enterIndoor(route:route,target:target,from:nav)
            }
        }
        // Ending outdoor navigation closes it and returns to the campus map.
        if door == nil { tripStarted = nil;exitIndoorM = nil;exitFloors = 0 } else { exitIndoorM = indoorSoFarM;exitFloors = floorsSoFar }
        outdoorWalkedM = nil
        nav.autoStartNear = door
        nav.onStarted = { [weak self] in if self?.tripStarted == nil { self?.tripStarted = Date() } }
        if door == nil { nav.onPlanFromIndoor = { [weak self] in self?.pickIndoorStart(for:target) } }
        nav.onArrived = { [weak self] walked in
            guard let self else { return };self.outdoorWalkedM = walked;self.trip = nil
            self.showSummary(destination:target.title,indoorM:self.exitIndoorM,floorChanges:self.exitFloors)
        }
        nav.onEnd = { [weak self,weak nav] in
            guard let self else { return };self.trip = nil
            if let campus = self.campusScreen,let host = self.host,host.viewControllers.contains(campus) { host.popToViewController(campus,animated:true) }
            else { nav?.navigationController?.popViewController(animated:true) }
        }
        // Before starting: tap another building to go there instead (or pick its room on the campus map).
        nav.canChooseRoom = { [weak self] b in self?.floors(for:b).contains { $0.indoorBound } ?? false }
        nav.onRetarget = { [weak self] b,chooseRoom in
            guard let self,let host = self.host,let campusScreen = self.campusScreen else { return }
            self.trip = nil;host.popToViewController(campusScreen,animated:!chooseRoom)
            if chooseRoom { campusScreen.open(b) } else { self.startOutdoor(.init(buildingID:b.id,title:b.fullName)) }
        }
        outdoorScreen = nav
        host.pushViewController(nav,animated:true)
    }
    private func enterIndoor(route:OutdoorRoute,target:OutdoorTarget,from outdoor:UIViewController) {
        guard let key = target.destinationID,let goal = destinationNodes[key],!goal.isEmpty,
              let id = directory.bindings.building(forOSM:target.buildingID) else { fail(outdoor,"这个目的地没有可用的室内入口绑定。");outdoorScreen?.resumeAfterIndoor();return }
        // The bound entrance nearest the door the outdoor route led to.
        let door = LiDARCampusBindings.GeoPoint(lat:route.entrance.coordinate.latitude,lon:route.entrance.coordinate.longitude)
        // The door the route led to (by its binding id), else the bound door nearest to it.
        let bound = doors(id)
        guard let entrance = bound.first(where: { $0.id == route.entrance.bindingID }) ?? bound.min(by: { door.distance(to:$0.position!) < door.distance(to:$1.position!) }),
              door.distance(to:entrance.position!) <= 25,let start = directory.maps[entrance.node.map_id] else {
            fail(outdoor,"室外路线的终点附近没有已绑定的出入口。请在地图工具“出入口室外坐标”中检查。");outdoorScreen?.resumeAfterIndoor();return
        }
        saveLastIndoor(.init(osm:target.buildingID,title:target.title,key:key,nodes:goal))
        let sameMap = goal.allSatisfy { $0.map_id == entrance.node.map_id }
        let cross = sameMap ? nil : LiDARNavigationStore.CrossTargets(targets:goal,maps:directory.maps,links:directory.links)
        let token = trip?.revision
        LiDARNavigationStore.openIndoor(start.0,destinations:sameMap ? goal.map(\.node_id) : [],name:target.title,start:entrance.node.node_id,cross:cross,resume:nil,
                                        onFinished:{ [weak self] arrived,walked,floors,_ in self?.indoorFinished(arrived:arrived,token:token,walkedM:walked,floorChanges:floors) }) { [weak self,weak outdoor] result in
            guard let self,let outdoor,self.trip?.revision == token else { return }
            switch result {
            case .success(let controller):
                let nav = UINavigationController(rootViewController:controller);nav.modalPresentationStyle = .fullScreen
                outdoor.present(nav,animated:true)
            case .failure(let error):self.fail(outdoor,error.localizedDescription);self.outdoorScreen?.resumeAfterIndoor()
            }
        }
    }
    /// Arrived: the trip is over, back to the campus map. Closed before arriving: this indoor leg is
    /// paused and outdoor guidance resumes (the indoor camera has already stopped). The destination stays.
    private func indoorFinished(arrived:Bool,token:Int?,walkedM:Double,floorChanges:Int) {
        guard trip?.revision == token else { return }
        if arrived {
            let title = trip?.target.title ?? "目的地";trip = nil
            showSummary(destination:title,indoorM:walkedM+(exitIndoorM ?? 0),floorChanges:floorChanges+exitFloors)
        } else { outdoorScreen?.resumeAfterIndoor() }
    }
    // MARK: planning out of a building
    private var exitIndoorM:Double?,exitFloors = 0
    struct LastIndoor:Codable { let osm:String,title:String,key:String,nodes:[LiDARNodeRef] }
    private func saveLastIndoor(_ v:LastIndoor) { if let d = try? JSONEncoder().encode(v) { UserDefaults.standard.set(d,forKey:"trip.lastIndoor") } }
    private func loadLastIndoor() -> LastIndoor? {
        UserDefaults.standard.data(forKey:"trip.lastIndoor").flatMap { try? JSONDecoder().decode(LastIndoor.self,from:$0) }
    }
    /// Picks where indoors the trip starts (last indoor destination, a room, or a whole floor).
    private func pickIndoorStart(for final:OutdoorTarget) {
        guard let campus,let host else { return }
        let picker = OutdoorCampusController(campus:campus);picker.pickStartMode = true;picker.automaticallyStartsLocation = false
        picker.floorsForBuilding = { [weak self] b in self?.floors(for:b) ?? [] }
        picker.doorsForBuilding = { [weak self] b in self?.doorMarkers(for:b) ?? [] }
        if let last = loadLastIndoor() {
            destinationNodes[last.key] = last.nodes
            picker.lastIndoor = (last.osm,last.title,OutdoorTarget(buildingID:last.osm,title:last.title,destinationID:last.key))
        }
        let nav = UINavigationController(rootViewController:picker);nav.modalPresentationStyle = .fullScreen
        picker.onTools = { [weak nav] in nav?.dismiss(animated:true) }
        picker.onStartPicked = { [weak self,weak nav] choice in nav?.dismiss(animated:true) { self?.startFromIndoor(choice,final:final) } }
        host.present(nav,animated:true)
    }
    /// Indoor navigation from the chosen place to the nearest bound exit; on arrival the outdoor leg
    /// to `final` opens and starts once satellites are back near that door.
    private func startFromIndoor(_ choice:OutdoorCampusController.StartChoice,final:OutdoorTarget) {
        guard let host else { return }
        let osm:String,startMap:String?,startNode:String?
        switch choice {
        case .room(let t):
            osm = t.buildingID;let ref = t.destinationID.flatMap { destinationNodes[$0] }?.first
            startMap = ref?.map_id;startNode = ref?.node_id
        case .floor(let b,let floorID):
            osm = b;startNode = nil
            let onFloor = directory.placements.filter { $0.value.floor_id == floorID }.keys.sorted()
            let withExit = onFloor.first { m in directory.maps[m]?.1.nodes.contains { $0.resolvedKind == .exit } == true }
            startMap = withExit ?? onFloor.first
        }
        guard let id = directory.bindings.building(forOSM:osm),let mapID = startMap,let start = directory.maps[mapID] else {
            fail(host,"没有找到这层的室内地图。");return
        }
        let exits = doors(id).map(\.node)
        guard !exits.isEmpty else { fail(host,"这栋楼还没有记录室外坐标的出入口，无法接上室外导航。");return }
        let here = exits.filter { $0.map_id == mapID }
        let cross = here.isEmpty ? LiDARNavigationStore.CrossTargets(targets:exits,maps:directory.maps,links:directory.links) : nil
        revision += 1;trip = (final,revision);let token = revision
        tripStarted = Date()
        LiDARNavigationStore.openIndoor(start.0,destinations:here.map(\.node_id),name:"最近的出入口",start:startNode,cross:cross,resume:nil,
                                        onFinished:{ [weak self] arrived,walked,floors,end in
            guard let self,self.trip?.revision == token else { return }
            guard arrived,let end,let door = self.directory.bindings.entrance(at:end)?.position else { return }
            // Out of the building: the outdoor leg from this door, auto-starting when GNSS recovers here.
            if let campusScreen = self.campusScreen { host.popToViewController(campusScreen,animated:false) }
            self.startOutdoor(final,leavingAt:OutdoorCoordinate(latitude:door.lat,longitude:door.lon),indoorSoFarM:walked,floorsSoFar:floors)
        }) { [weak self] result in
            guard let self,self.trip?.revision == token else { return }
            switch result {
            case .success(let controller):let nav = UINavigationController(rootViewController:controller);nav.modalPresentationStyle = .fullScreen;host.present(nav,animated:true)
            case .failure(let error):self.fail(host,error.localizedDescription)
            }
        }
    }
    /// Back to the campus map, then the trip summary over it.
    private func showSummary(destination:String,indoorM:Double?,floorChanges:Int) {
        guard let host else { return }
        if let campusScreen = host.viewControllers.last(where: { $0 is OutdoorCampusController }) { host.popToViewController(campusScreen,animated:true) }
        let summary = TripSummaryController(.init(destination:destination,started:tripStarted,outdoorM:outdoorWalkedM,indoorM:indoorM,floorChanges:floorChanges))
        DispatchQueue.main.asyncAfter(deadline:.now()+0.45) { host.present(summary,animated:true) }
    }
    private func fail(_ on:UIViewController,_ message:String) {
        let a = UIAlertController(title:"无法进入室内导航",message:message,preferredStyle:.alert)
        a.addAction(UIAlertAction(title:"知道了",style:.default));on.present(a,animated:true)
    }
}
