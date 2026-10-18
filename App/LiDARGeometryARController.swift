#if !targetEnvironment(macCatalyst) && !targetEnvironment(simulator)
import UIKit
import ARKit
import RealityKit
import AVFoundation
import ImageIO
import CryptoKit
import CoreLocation
import CoreMotion

final class LiDARGeometryARController:UIViewController,ARSessionDelegate,CLLocationManagerDelegate {
    static var supported:Bool { ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) }
    var onSaved:(() -> Void)?
    /// Called after the indoor screen has closed; `arrived` when the destination was reached.
    var onFinished:((_ arrived:Bool,_ walkedM:Double,_ floorChanges:Int,_ endNode:LiDARNodeRef?) -> Void)?
    /// Metres actually walked while navigating (camera movement in map space) and floor changes, for the summary.
    private var walkedM = 0.0,lastWalkPosition:ProbePoint?,floorChanges = 0,tripStarted:Date?
    private enum Phase { case idle,collecting,solving,review,navigation,suspended,finished }
    private var isMapping:Bool
    /// Supplement capture of an existing map: localize and confirm first, then capture in map coordinates.
    private var supplementDirectory:URL?
    /// map_from_session confirmed before supplement capture; nil for a new map.
    private var supplementTransform:[[Double]]?
    private var supplementConfirmation:(generation:Int,attempt:String,candidate:Int?)?
    /// Map points newly accepted in this supplement (map coordinates), for the overlay.
    private var supplementNew = [LiDARVoxelKey:ProbePoint]()
    /// Early stop for queries: background trial solves decide when enough frames are in; the
    /// reviewed result always comes from the normal final solve.
    private var trialRunning = false,lastTrialFrames = 0,earlyStopRequested = false
    /// Status of the latest trial; ambiguous or rejected at 12 frames extends collection up to 24 frames / 20 s.
    private var lastTrialStatus:String?,extensionAnnounced = false
    /// Query capture settings: frames to collect (16…64, default 32) and whether a unique trial may stop early (default off).
    private var queryFrameTarget:Int { let v = UserDefaults.standard.integer(forKey:"lidar.queryFrames");return [16,24,32,48,64].contains(v) ? v : 32 }
    private var autoEarlyStop:Bool { UserDefaults.standard.bool(forKey:"lidar.queryAutoStop") }
    /// "No progress" guard: frames stop increasing (poor depth or tracking, phone held still).
    private var lastQueryProgress = 0.0,lastQueryFrameCount = 0,stallPrompted = false
    /// Compass: map reference (from the map's sidecars), readings paired during the query window,
    /// and the screen of the latest result. The structure grid is built lazily on `compute`.
    private var magneticReference:LiDARMagnetic.Reference?
    private var querySamples = [LiDARMagneticSample]()
    private var magneticScreen:LiDARMagnetic.Screen?
    private var structureGrid:LiDARStructureGrid?
    /// Plate-guided query: windows at every entrance of the confirmed room text.
    private struct PlateSearch { let text:String;let centers:[LiDARPlateSearch.Center];let pose:[[Double]]?;let point:ProbePoint?;let session:String;let generation:Int }
    private var plateSearch:PlateSearch?
    /// Automatic recognition of known plates in navigation frames: a text must match a stored
    /// plate exactly (normalized) in 2 of the last 3 reads before a chip offers it.
    private let ocrQueue = DispatchQueue(label:"lidar.geometry.plate-watch",qos:.utility)
    private var plateWatchBusy = false,lastPlateWatch = -Double.infinity,lastPlateWatchLog = -Double.infinity
    private var plateWatchHistory = [Set<String>]()
    private var plateWatchSeen = [String:(raw:String,last:Double,samples:[LiDARLandmarkSample])]()
    private let plateChips = UIStackView()
    /// Navigation refresh (prompt-only): a short local re-localization when the phone is held up.
    private var refreshActive = false,refreshBusy = false,refreshStarted = 0.0,lastRefreshAt = -Double.infinity
    private var lastRefreshPosition:ProbePoint?,refreshPose:simd_float4x4?
    private var refreshCloud = [LiDARVoxelKey:ProbePoint](),refreshFrames = 0,refreshSamples = [LiDARMagneticSample]()
    /// A suggestion is only valid for the map, session, AR generation and alignment it was computed against.
    private struct RefreshSuggestion { let transform:[[Double]]?;let decision:LiDARRefreshDecision;let mapID:String;let session:String;let arGeneration:Int;let base:[[Double]] }
    /// Smooth 1.5 s move of everything drawn in AR from the old to the new alignment (target applies at once).
    private var alignmentTransition:(from:[[Double]],to:[[Double]],start:Double)?
    /// Undo for the last automatic correction, and metres of silent micro-adjustment since the last full confirmation.
    private var lastAutoCorrection:(before:[[Double]],after:[[Double]],at:Double,source:String)?
    private var microSoFar = 0.0
    private var refreshBlockedFrames = 0,refreshCheckedFrames = 0
    /// Quick provisional correction from the first refresh frames' wall feet (corridor / corner), shown
    /// until the full result decides. `quickChainBase` is the last formally decided alignment: quick
    /// corrections never stack beyond their limits from it.
    private var quickTried = false,quickBusy = false,quickApplied:(before:[[Double]],after:[[Double]])?,quickChainBase:[[Double]]?
    private var quickCorrectionOn:Bool { UserDefaults.standard.object(forKey:"lidar.quickCorrection") as? Bool ?? true }
    private var largeCorrectionMode:String { UserDefaults.standard.string(forKey:"lidar.largeCorrection.v2") ?? "direct" }   // direct (default) | ask
    private var refreshSuggestion:RefreshSuggestion?
    private var agreementSample:(mapID:String,points:[ProbePoint])?
    private var refreshMode:String { UserDefaults.standard.string(forKey:"lidar.refreshMode") ?? "prompt" }   // prompt | off
    /// Wall-foot / corner lines: the map's (computed once on compute) and the live capture's (io).
    private var mapLines = [LiDARStructureLine](),liveLines = [LiDARStructureLine]()
    private var linesRoot:AnchorEntity?
    private var lastLinesUpdate = -Double.infinity,linesBusy = false
    private var lineComparison:LiDARStructureLines.Comparison?
    private var linesVisible:Bool { UserDefaults.standard.object(forKey:"lidar.structureLines") as? Bool ?? true }
    private var shownChips = [String]()
    private let name:String,lighting:String
    private var captureBuilding:LiDARCampusCatalog.Building?,captureFloor:LiDARCampusCatalog.Floor?
    private var map:LiDARNavigationMap?
    private var referencePoints:[ProbePoint] = []
    private var destinations:[String],destinationName:String
    /// Cross-floor / cross-region navigation: final targets, the maps and links, the current plan.
    /// Each leg is navigated on its own map; at a link the person confirms arrival and the next map
    /// is loaded and relocalized from the linked node.
    private struct CrossMap {
        var targets:[LiDARNodeRef];var directories:[String:URL];var maps:[String:LiDARNavigationMap];var links:[LiDARMapLink]
        var plan:LiDARMultiMapRoute?
    }
    private var crossMap:CrossMap?
    private var transitionReady = false
    /// At the elevator lobby or stairs: the camera is off until "我已到达" on the next floor.
    private var parkedAtTransfer = false
    /// After "在本层重新定位" the lobby does not park again until you have walked 5 m away from it.
    private var parkSuppressed = false
    private var chosenDestinationID:String?
    private var startNodeID:String?
    /// "Start from where I last was" on this map: a search prior like a start node, never a pose.
    private var resumePrior:ProbePoint?
    private var startPrior:LiDARRouteNode? {
        map?.nodes.first { $0.id == startNodeID } ?? resumePrior.map { LiDARRouteNode(name:"上次位置",position:$0,id:"resume") }
    }
    private var lastResumeSave = -Double.infinity
    /// Product navigation UI: the shared shell over AR with the ground arrow chain. The older
    /// panel (all diagnostics) is the debug view, switchable from the "…" menu.
    private let navShell = UnifiedNavigationShell()
    private let floorMini = IndoorFloorPlanView(),floorPlan = IndoorFloorPlanView()
    private var floorMiniBottom:NSLayoutConstraint?
    private var floorMapID:String?,floorLineCount = -1
    private var floorFull = false,floorModeCandidate:Bool?,floorModeSince = 0.0,lastFloorUpdate = -Double.infinity
    private var floorTransition = 0,floorPresentationActive = false
    private var floorMiniMapOn:Bool { UserDefaults.standard.object(forKey:"nav.floorMiniMap") as? Bool ?? true }
    private var panelView:UIView?,chipsTop:NSLayoutConstraint?
    private var debugPanelOn:Bool { UserDefaults.standard.bool(forKey:"lidar.debugPanel") }
    private var usesShell:Bool { !isMapping && supplementDirectory == nil && !debugPanelOn }
    private var chain:GroundArrowChain?,chainAnchor:AnchorEntity?
    private var chainGeometry:CampusRouteGeometry?,chainProgress = 0.0,shownChainProgress:Double?
    private var guide:(maneuver:NavigationManeuver,distance:Double?,remaining:Double)?
    /// What renderNavigation last wrote as guidance; any other status text is a message to show.
    private var guideStatus:String?
    private var arrowChainM:Double { UserDefaults.standard.object(forKey:"nav.arrowChainM") as? Double ?? 10 }
    /// Capture guidance: shown while collecting until the person turns fast enough, again after a still pause.
    private let turnGuide = TurnGuideView()
    private var lastYaw:(yaw:Float,t:Double)?,yawRate:Double = 0,turningSince:Double?,stillSince:Double?
    /// Elevator hall call for the current leg (bound device, within range).
    private let elevatorCard = ElevatorCallCard()
    /// The Android-style elevator page, floating over navigation (the AR session keeps running).
    private let elevatorPanel = ElevatorPanel()
    private var elevatorFloors:(floors:[ElevatorPanel.Floor],current:Int?,destination:Int?,name:String) = ([],nil,nil,"电梯")
    private var elevatorService:ElevatorBLEService?,elevatorTarget:ElevatorCallTarget?,elevatorLinkID:String?,planRevision = 0
    private let pointOverlay = LiDARPointOverlay()
    private var lastOverlayUpdate = -Double.infinity
    private var diagnosticOverlayPoints = [ProbePoint]()
    private var overlayDepthColors = UserDefaults.standard.bool(forKey:"lidar.overlay.depthColors")
    private var overlayContext:String { supplementTransform != nil ? "supplement" : isMapping ? "mapping" : phase == .review ? "review" : "navigation" }
    private var overlayVisible:Bool {
        let key = "lidar.overlay."+overlayContext
        return UserDefaults.standard.object(forKey:key) as? Bool ?? (phase == .review || supplementTransform != nil)
    }
    private let scene = ARView(frame:.zero,cameraMode:.ar,automaticallyConfigureSession:false)
    private let status = UILabel(),detail = UILabel(),reticle = UILabel()
    private let primary = UIButton(type:.system),secondary = UIButton(type:.system),tertiary = UIButton(type:.system)
    private let io = DispatchQueue(label:"lidar.geometry.capture",qos:.userInitiated)
    private let compute = DispatchQueue(label:"lidar.geometry.solve",qos:.userInitiated)
    private let headingManager = CLLocationManager()
    private let motionManager = CMMotionManager()
    private var configurationRevision = 0,depthRequested = false
    private var depthOnDemand = UserDefaults.standard.object(forKey:"lidar.depthOnDemand") as? Bool ?? true
    private enum DepthAction { case query,plate }
    private var depthAction:DepthAction?
    private var depthGate = LiDARDepthRequestGate()
    private var depthTimeout:DispatchWorkItem?
    private var depthRequestID:UUID?

    private var lastHeadingLog = -Double.infinity
    private let context = CIContext(options:[.cacheIntermediates:false])
    private var phase:Phase = .idle
    private var sessionID = UUID().uuidString,generation = 0
    private var arSessionGeneration = 0
    private var attemptID = UUID().uuidString
    private var diagnosticError:String?
    private var geometrySHA256:String?
    private var confirmedAlignment:LiDARConfirmedAlignment?
    private var consistencyReport:LiDARConsistencyReport?
    private let consistencyStatus = UILabel()
    private let recordingStatus = UILabel(),budgetStatus = UILabel()
    private var refusedSamples = 0,refusedVoxelObservations = 0
    private var alignment = LiDARSessionAlignment(sessionID:"")
    private var cancellation = LiDARWorkCancellation()
    private var writer:LiDARScanWriter?
    private var recorder:RunRecorder?
    private var normal = false,hasDepth = false,started = false,working = false,savePending = false,closing = false
    private var oldIdle = false,recordingPaused = false,readinessAnnounced = false
    private var frames = 0,skipped = 0
    private var lastCapture = -Double.infinity,lastRender = -Double.infinity,lastLog = -Double.infinity
    private var captureStarted:Double?,requestStarted:Double?,previousTime:Double?,previousPosition:SIMD3<Float>?,unhealthySince:Double?
    private var cloud = [LiDARVoxelKey:ProbePoint]()
    private var nodes = [LiDARRouteNode](),edges = [LiDARRouteEdge](),selectedNode:String?
    private var result:LiDARLocalizationResult?,candidateIndex = 0
    private var root:AnchorEntity?
    private var progress = 0.0
    private var completed = false
    private var thermalGate = LiDARThermalCaptureGate()
    private var thermalResumeAnnounced = false
    private var lastSafetyCheck = -Double.infinity,lastUIRefresh = -Double.infinity
    private var motionSamples:[(Double,SIMD3<Float>)] = []
    private var fastSince:Double?,nearSince:Double?
    private var lastAdvice = ""
    private let safetyStatus = UILabel()
    private var routeEditor:LiDARRouteEditor = { var e = LiDARRouteEditor();e.spaceMode = true;return e }()
    /// Space routing (experimental): suggested paths drawn on the phone this session, the map's
    /// existing calibration (kept as is, paths appended), and the path being drawn.
    private var phonePaths = [LiDARSuggestedPath]()
    private var existingCalibration:LiDARPassageCalibration?
    private var pathDraft:[ProbePoint]?
    private var pathsRoot:AnchorEntity?
    /// Navigation: walkable space of the map (built off the main thread before opening) and the space route.
    private var spaceGrid:LiDARSpaceGrid?
    /// Cross-map in-map lengths; the instance is only used on `compute`. Rebuilt per map and per cross-map request.
    private var crossDistances:LiDARSpaceDistances?,crossDistancesMap:String?
    private var spacePlanned = [ProbePoint](),spacePlanning = false,lastSpacePlan:ProbePoint?,spaceFailure:String?
    /// Metres outside the walkable area when the route starts from the nearest walkable place.
    private var offMapDistance:Double?
    private var lastAcceptedForMark:(index:Int,timestamp:Double)?
    // These stores are confined to io, never accessed directly from UI callbacks.
    private var mappingBudget = LiDARBlockBudget(settings:.init(globalCap:LiDARScanLimits.mapVoxelsV3))
    private var keyframePolicy = LiDARKeyframePolicy()
    // A single suspect isolates one frame; only a flagged streak is sticky (LiDARRevisitGate).
    private var revisitGate = LiDARRevisitGate()
    private var acceptedFrameIDs = [Int](),diagnosticFrameIDs = [Int](),frameForBatch = [Int:Int]()
    private var ioLastRevisit = -Double.infinity
    private var ioLastRevisitPose:[[Double]]?
    private var skippedByReason = [String:Int]()
    private var budgetSnapshot:LiDARBudgetSnapshot?
    private var geometryUncertain = false,diagnosticSegment = false,rawLimitReached = false
    private var baselineEditor:LiDARRouteEditor?
    private var rawBytesRecorded = 0
    private var manualEvidenceBytes = 0 // io queue only; included in the map storage budget
    private var manualKeyframeRequested = false
    private var lastSkipLog = -Double.infinity
    private struct CaptureResult {
        var stored = false,committed = false,flagged = false,quarantined = false,captureBaseline = false
        var points = [ProbePoint](),diagnosticPoints = [ProbePoint]()
        /// Full accepted cloud after a rollback; replaces the main-thread preview cloud.
        var resetCloud:[ProbePoint]?
        var snapshot:LiDARBudgetSnapshot?
        var revisit:LiDARRevisitReport?
        var skip:String?,limit:String?
        var reasons = [String](),skips = [String:Int]()
        var rawBytes = 0,blocked = 0,refused = 0
    }
    private struct PendingMark {
        var point:ProbePoint
        var session:String
        var coordinateGeneration:Int
        var timestamp:Double
        var camera:[[Double]]
        var keyframeIndex:Int?
        var keyframeDelta:Double?
        var invalid = false
    }
    private var pendingMark:PendingMark?
    private var plateRecords = [LiDARLandmark](),knownPlates = [LiDARLandmark]()
    private var plateToken:UUID?,platePackets = [PlatePacket](),plateLastFrame = -Double.infinity
    private var entranceMarker:AnchorEntity?
    private struct EntranceDraft {
        let name:String,token:UUID,session:String,coordinateGeneration:Int
        var landmark:LiDARLandmark?
        let files:[String:Data]
        var position:ProbePoint?,capture:LiDARNodeCaptureContext?
    }
    private var entranceDraft:EntranceDraft?
    private var entranceChecking = false
    private var plateCollecting = false
    private struct PlatePacket {
        var frame:LiDARFrame
        var image:CVPixelBuffer,depth:CVPixelBuffer,confidence:CVPixelBuffer
    }
    private struct PlateObservation {
        var frame:LiDARFrame
        var jpeg:Data,depth:Data,confidence:Data
        var image:CGImage,text:[LiDARTextObservation]
    }



    init(name:String,lighting:String,building:LiDARCampusCatalog.Building? = nil,floor:LiDARCampusCatalog.Floor? = nil) {
        captureBuilding = building;captureFloor = floor
        isMapping = true;self.name = name;self.lighting = lighting;destinations = [];destinationName = ""
        super.init(nibName:nil,bundle:nil)
    }
    init(map:LiDARNavigationMap,points:[ProbePoint],destinations:[String],destinationName:String,startNodeID:String? = nil,landmarks:LiDARLandmarkSet? = nil,supplementOf directory:URL? = nil,magneticReference:LiDARMagnetic.Reference? = nil,
         calibration:LiDARPassageCalibration? = nil,spaceGrid:LiDARSpaceGrid? = nil,resumePosition:ProbePoint? = nil) {
        existingCalibration = calibration;self.spaceGrid = spaceGrid;resumePrior = resumePosition
        isMapping = false;supplementDirectory = directory;self.magneticReference = magneticReference;self.map = map;referencePoints = points;name = map.name;lighting = "query";self.destinations = destinations;self.destinationName = destinationName;self.startNodeID = startNodeID;knownPlates = landmarks?.landmarks ?? []
        super.init(nibName:nil,bundle:nil)
        if let bytes = try? LiDARPointFile.encode(points) { geometrySHA256 = Self.digest(bytes) }
    }
    required init?(coder:NSCoder) { fatalError("init(coder:)") }
    override func viewDidLoad() {
        super.viewDidLoad();view.backgroundColor = .black;title = name
        navigationItem.leftBarButtonItem = UIBarButtonItem(title:"结束",style:.plain,target:self,action:#selector(close))
        navigationItem.rightBarButtonItems = [UIBarButtonItem(title:"工具",style:.plain,target:self,action:#selector(tools)),UIBarButtonItem(title:isMapping ? "标记门牌" : "扫门牌辅助",style:.plain,target:self,action:#selector(startPlate))]
        scene.translatesAutoresizingMaskIntoConstraints = false;view.addSubview(scene)
        NSLayoutConstraint.activate([scene.leadingAnchor.constraint(equalTo:view.leadingAnchor),scene.trailingAnchor.constraint(equalTo:view.trailingAnchor),scene.topAnchor.constraint(equalTo:view.topAnchor),scene.bottomAnchor.constraint(equalTo:view.bottomAnchor)])
        pointOverlay.translatesAutoresizingMaskIntoConstraints = false;pointOverlay.isHidden = true;view.addSubview(pointOverlay)
        NSLayoutConstraint.activate([pointOverlay.leadingAnchor.constraint(equalTo:scene.leadingAnchor),pointOverlay.trailingAnchor.constraint(equalTo:scene.trailingAnchor),pointOverlay.topAnchor.constraint(equalTo:scene.topAnchor),pointOverlay.bottomAnchor.constraint(equalTo:scene.bottomAnchor)])
        reticle.text = "＋";reticle.textColor = .white;reticle.font = .systemFont(ofSize:38,weight:.light);reticle.translatesAutoresizingMaskIntoConstraints = false
        reticle.isHidden = !isMapping;view.addSubview(reticle)
        plateChips.axis = .vertical;plateChips.spacing = 8;plateChips.alignment = .trailing;plateChips.translatesAutoresizingMaskIntoConstraints = false;view.addSubview(plateChips)
        let top = plateChips.topAnchor.constraint(equalTo:view.safeAreaLayoutGuide.topAnchor,constant:12);chipsTop = top
        NSLayoutConstraint.activate([plateChips.trailingAnchor.constraint(equalTo:view.safeAreaLayoutGuide.trailingAnchor,constant:-12),top])
        NSLayoutConstraint.activate([reticle.centerXAnchor.constraint(equalTo:view.centerXAnchor),reticle.centerYAnchor.constraint(equalTo:view.centerYAnchor,constant:-70)])
        let panel = UIVisualEffectView(effect:UIBlurEffect(style:.systemMaterial));panel.translatesAutoresizingMaskIntoConstraints = false;panel.layer.cornerRadius = 22;panel.clipsToBounds = true;view.addSubview(panel);panelView = panel
        navShell.translatesAutoresizingMaskIntoConstraints = false;view.insertSubview(navShell,belowSubview:plateChips)
        NSLayoutConstraint.activate([navShell.leadingAnchor.constraint(equalTo:view.leadingAnchor),navShell.trailingAnchor.constraint(equalTo:view.trailingAnchor),
                                     navShell.topAnchor.constraint(equalTo:view.topAnchor),navShell.bottomAnchor.constraint(equalTo:view.bottomAnchor)])
        installFloorPlans()
        navShell.onClose = { [weak self] in self?.close() }
        navShell.onMore = { [weak self] in self?.productMenu() }
        navShell.onPrimaryAction = { [weak self] in self?.act() }
        turnGuide.translatesAutoresizingMaskIntoConstraints = false;view.insertSubview(turnGuide,aboveSubview:navShell)
        elevatorCard.translatesAutoresizingMaskIntoConstraints = false;view.insertSubview(elevatorCard,aboveSubview:navShell)
        NSLayoutConstraint.activate([turnGuide.centerXAnchor.constraint(equalTo:view.centerXAnchor),turnGuide.centerYAnchor.constraint(equalTo:view.centerYAnchor,constant:-20),
                                     elevatorCard.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-16),
                                     elevatorCard.bottomAnchor.constraint(equalTo:view.safeAreaLayoutGuide.bottomAnchor,constant:-150)])
        elevatorCard.onCall = { [weak self] in self?.callElevator() }
        elevatorCard.onDetails = { [weak self] in self?.elevatorDetails() }
        elevatorPanel.translatesAutoresizingMaskIntoConstraints = false;view.addSubview(elevatorPanel)
        NSLayoutConstraint.activate([elevatorPanel.leadingAnchor.constraint(equalTo:view.leadingAnchor),elevatorPanel.trailingAnchor.constraint(equalTo:view.trailingAnchor),
                                     elevatorPanel.topAnchor.constraint(equalTo:view.topAnchor),elevatorPanel.bottomAnchor.constraint(equalTo:view.bottomAnchor)])
        elevatorPanel.onCall = { [weak self] in self?.callElevator() }
        elevatorPanel.onClose = { [weak self] in self?.elevatorPanel.setVisible(false) }
        for label in [status,detail] { label.numberOfLines = 0 }
        status.font = .preferredFont(forTextStyle:.headline);detail.font = .preferredFont(forTextStyle:.subheadline)
        primary.configuration = .filled();primary.configuration?.baseBackgroundColor = .systemTeal
        secondary.configuration = .bordered();tertiary.configuration = .bordered()
        for button in [primary,secondary,tertiary] { button.heightAnchor.constraint(greaterThanOrEqualToConstant:44).isActive = true }
        primary.addTarget(self,action:#selector(act),for:.touchUpInside);secondary.addTarget(self,action:#selector(second),for:.touchUpInside);tertiary.addTarget(self,action:#selector(third),for:.touchUpInside)
        let buttons = UIStackView(arrangedSubviews:[secondary,tertiary]);buttons.spacing = 10;buttons.distribution = .fillEqually
        recordingStatus.font = .preferredFont(forTextStyle:.caption1);recordingStatus.textColor = .secondaryLabel;recordingStatus.numberOfLines = 0
        budgetStatus.font = .preferredFont(forTextStyle:.caption1);budgetStatus.numberOfLines = 0
        consistencyStatus.font = .preferredFont(forTextStyle:.caption1);consistencyStatus.numberOfLines = 0
        safetyStatus.font = .preferredFont(forTextStyle:.caption1);safetyStatus.textColor = .systemOrange;safetyStatus.numberOfLines = 0
        let stack = UIStackView(arrangedSubviews:[status,detail,safetyStatus,consistencyStatus,budgetStatus,recordingStatus,primary,buttons]);stack.axis = .vertical;stack.spacing = 12;stack.translatesAutoresizingMaskIntoConstraints = false;panel.contentView.addSubview(stack)
        NSLayoutConstraint.activate([panel.leadingAnchor.constraint(equalTo:view.safeAreaLayoutGuide.leadingAnchor,constant:12),panel.trailingAnchor.constraint(equalTo:view.safeAreaLayoutGuide.trailingAnchor,constant:-12),panel.bottomAnchor.constraint(equalTo:view.safeAreaLayoutGuide.bottomAnchor,constant:-10),stack.leadingAnchor.constraint(equalTo:panel.contentView.leadingAnchor,constant:16),stack.trailingAnchor.constraint(equalTo:panel.contentView.trailingAnchor,constant:-16),stack.topAnchor.constraint(equalTo:panel.contentView.topAnchor,constant:16),stack.bottomAnchor.constraint(equalTo:panel.contentView.bottomAnchor,constant:-16)])
        scene.session.delegate = self;scene.session.delegateQueue = .main
        oldIdle = UIApplication.shared.isIdleTimerDisabled;UIApplication.shared.isIdleTimerDisabled = true
        NotificationCenter.default.addObserver(self,selector:#selector(background),name:UIApplication.didEnterBackgroundNotification,object:nil)
        NotificationCenter.default.addObserver(self,selector:#selector(thermalChanged),name:ProcessInfo.thermalStateDidChangeNotification,object:nil)
        do {
            recorder = try RunRecorder(sessionID:sessionID,configuration:["geometry_navigation":true,"mode":isMapping ? "mapping" : "navigation","map_id":map?.map_id ?? "new","initial_world_map":false,"matching":"on_device_gravity_correlative_3d_icp","requires_physical_confirmation":true],device:["platform":"iOS","hardware":ProbeIO.hardwareIdentifier()],rootDirectory:LiDARNavigationStore.runs,additionalLogs:["geometry-events.jsonl","camera-poses.jsonl","magnetic-heading.jsonl"])
            recorder?.onFailure = { [weak self] message in self?.diagnosticError = message;self?.refresh() }
        } catch { diagnosticError = error.localizedDescription }
        alignment.reset(sessionID:sessionID);status.text = "正在启动相机…";thermalChanged();refresh()
        if !referencePoints.isEmpty {
            let points = referencePoints
            compute.async { [weak self] in
                let lines = LiDARStructureLines.extract(points)
                DispatchQueue.main.async { self?.mapLines = lines;self?.log("map_structure_lines",["lines":lines.count]) }
            }
        }
    }
    override func viewWillAppear(_ animated:Bool) { super.viewWillAppear(animated);applyChrome() }
    /// Product shell or debug panel; navigation bar only in the debug/mapping views.
    private func applyChrome() {
        let shell = usesShell
        navShell.isHidden = !shell;panelView?.isHidden = shell
        navigationController?.setNavigationBarHidden(shell,animated:false)
        chipsTop?.constant = shell ? 150 : 12
        if shell { updateShell() } else { hideFloorPlans() }
    }
    private func installFloorPlans() {
        floorMini.compact = true
        for mapView in [floorPlan,floorMini] {
            mapView.translatesAutoresizingMaskIntoConstraints = false;mapView.isHidden = true
            view.insertSubview(mapView,belowSubview:navShell)
        }
        let bottom = floorMini.bottomAnchor.constraint(equalTo:view.bottomAnchor,constant:-140);floorMiniBottom = bottom
        NSLayoutConstraint.activate([
            floorPlan.leadingAnchor.constraint(equalTo:view.leadingAnchor),floorPlan.trailingAnchor.constraint(equalTo:view.trailingAnchor),
            floorPlan.topAnchor.constraint(equalTo:view.topAnchor),floorPlan.bottomAnchor.constraint(equalTo:view.bottomAnchor),
            floorMini.leadingAnchor.constraint(equalTo:view.safeAreaLayoutGuide.leadingAnchor,constant:16),
            floorMini.widthAnchor.constraint(equalToConstant:132),floorMini.heightAnchor.constraint(equalToConstant:156),bottom
        ])
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bottom = -max(16,navShell.bottomInset+16)
        if floorMiniBottom?.constant != bottom { floorMiniBottom?.constant = bottom }
    }
    private func hideFloorPlans() {
        floorTransition += 1;floorModeCandidate = nil;floorFull = false;floorPresentationActive = false
        floorMini.layer.removeAllAnimations();floorPlan.layer.removeAllAnimations()
        floorMini.isHidden = true;floorPlan.isHidden = true
    }
    /// Pure presentation: the camera session and world tracking keep running in either size.
    private func setFloorPlanMode(_ full:Bool,animated:Bool) {
        let changed = full != floorFull
        floorFull = full;floorTransition += 1;let token = floorTransition
        let incoming = full ? floorPlan : floorMini,outgoing = full ? floorMini : floorPlan
        let show = full || floorMiniMapOn
        if show { if incoming.isHidden { incoming.alpha = 0 };incoming.isHidden = false }
        if full && changed { view.layoutIfNeeded();floorPlan.frameRoute(top:view.safeAreaInsets.top+200,bottom:navShell.bottomInset+24) }
        UIView.animate(withDuration:UIAccessibility.isReduceMotionEnabled || !animated ? 0 : 0.25,delay:0,
                       options:[.beginFromCurrentState,.allowUserInteraction],animations:{ incoming.alpha = show ? 1 : 0;outgoing.alpha = 0 }) { [weak self] _ in
            guard let self,self.floorTransition == token else { return };outgoing.isHidden = true;incoming.isHidden = !show
        }
    }
    private func updateFloorPlans(_ frame:ARFrame) {
        guard usesShell,phase == .navigation,normal,!closing,plateToken == nil,
              let map,let grid = spaceGrid,let transform = displayedAlignment(ProcessInfo.processInfo.systemUptime) else {
            if floorPresentationActive { hideFloorPlans() };return
        }
        let first = !floorPresentationActive;floorPresentationActive = true
        if floorMapID != map.map_id || floorLineCount != mapLines.count {
            for mapView in [floorMini,floorPlan] { mapView.setFloor(grid:grid,walls:mapLines,rooms:map.nodes) }
            floorMapID = map.map_id;floorLineCount = mapLines.count
        }
        // Same 40°/22° hysteresis and 250 ms dwell as the outdoor view. AR's vertical
        // axis gives the screen's inclination without starting a second motion stream.
        let raise = acos(min(1,abs(Double(frame.camera.transform.columns.2.y))))*180/Double.pi
        let wantFull = floorFull ? raise < 40 : raise <= 22
        var switchTo:Bool?
        if wantFull == floorFull { floorModeCandidate = nil }
        else if floorModeCandidate != wantFull { floorModeCandidate = wantFull;floorModeSince = frame.timestamp }
        else if frame.timestamp-floorModeSince >= 0.25 { floorModeCandidate = nil;switchTo = wantFull }
        guard first || switchTo != nil || frame.timestamp-lastFloorUpdate >= 0.1 else { return }
        lastFloorUpdate = frame.timestamp
        let camera = CampusMapGeometry.multiply(transform,matrixRows(frame.camera.transform))
        let targetView = (switchTo ?? floorFull) ? floorPlan : floorMini
        targetView.route = spacePlanned;targetView.progressM = chainProgress
        targetView.destination = spacePlanned.last ?? map.nodes.first { $0.id == chosenDestinationID }?.position
        targetView.position = ProbePoint(camera[0][3],camera[1][3],camera[2][3])
        let fx = -camera[0][2],fz = -camera[2][2]
        targetView.headingRad = hypot(fx,fz) > 0.1 ? atan2(fx,-fz) : nil
        if first { setFloorPlanMode(false,animated:false) }
        if let full = switchTo { setFloorPlanMode(full,animated:true) }
    }
    private func productMenu() {
        var items:[(String,() -> Void)] = []
        switch phase {
        case .navigation:
            items.append(("楼层小地图：\(floorMiniMapOn ? "开" : "关")",{ [weak self] in
                guard let self else { return };UserDefaults.standard.set(!self.floorMiniMapOn,forKey:"nav.floorMiniMap")
                if self.floorPresentationActive { self.setFloorPlanMode(self.floorFull,animated:true) }
            }))
            if parkedAtTransfer { items.append(("在本层重新定位",{ [weak self] in self?.relocateOnThisFloor() })) } else {
                items.append(("重新定位",{ [weak self] in self?.beginCapture() }))
                items.append(("扫门牌辅助定位",{ [weak self] in self?.startPlate() }))
                items.append(("报告路线错位",{ [weak self] in self?.second() }))
            }
        case .review:
            items.append(("换下一个候选",{ [weak self] in self?.second() }))
            items.append(("重新扫描",{ [weak self] in self?.third() }))
        case .idle,.collecting:
            items.append(("扫门牌辅助定位",{ [weak self] in self?.startPlate() }))
        default:break
        }
        items.append(("实景箭头长度：\(Int(arrowChainM)) 米",{ [weak self] in
            self?.campusChoices("实景箭头显示多远",message:"地面箭头链从脚下向前延伸的长度，远端逐渐变淡。",choices:[5.0,10,15,20,30].map { m in
                ("\(Int(m)) 米",{ UserDefaults.standard.set(m,forKey:"nav.arrowChainM") }) })
        }))
        items.append(("显示调试界面",{ [weak self] in UserDefaults.standard.set(true,forKey:"lidar.debugPanel");self?.applyChrome();self?.refresh() }))
        items.append(("更多工具",{ [weak self] in self?.tools() }))
        campusChoices("导航选项",choices:items)
    }
    /// The shell's state from the current phase (indoor localisation steps, guidance, messages).
    private func updateShell() {
        if !usesShell,!isMapping,phase == .navigation {
            let title = nearbyTransferTitle ?? (transitionReady ? arrivedTitle : "重新定位")
            if primary.title(for:.normal) != title { primary.setTitle(title,for:.normal) }
        }
        guard usesShell else { return }
        var v = NavigationShellState(destination:destinationName,phase:.indoorRecovery)
        v.maneuver = .recover
        let message = (status.text?.isEmpty == false) ? NavigationShellState.Status(status.text!,detail:detail.text,level:Self.isWarning(status.text!) ? .attention : .information) : nil
        switch phase {
        case .idle:
            v.headline = "缓慢观察周围"
            v.status = .init(startPrior.map { "从「\($0.name)」附近恢复位置" } ?? "恢复你的位置",detail:"对准附近的墙和地面，点“开始定位”后缓慢环顾。")
            v.actionTitle = "开始定位"
        case .collecting:
            v.headline = "缓慢环顾四周"
            v.status = .init("正在识别周围环境",detail:"已采集 \(frames)/\(queryFrameTarget) 帧 · 墙角、门框和地面最有用")
            v.actionTitle = frames >= 3 ? "结束采集并定位" : nil
        case .solving:
            v.headline = "正在确认位置…";v.status = message;v.actionTitle = "取消"
        case .review:
            v.headline = "核对墙角线";v.maneuver = .recover
            v.status = .init("观察墙角线与现实墙角是否对齐",detail:"白色线是地图记录的墙脚和墙角。对齐就开始导航；明显错开可在“…”中换下一个候选或重新扫描。")
            v.actionTitle = supplementDirectory != nil ? "确认对齐" : "确认，开始导航"
        case .navigation:
            v.phase = .indoor
            if let g = guide { v.maneuver = g.maneuver;v.maneuverDistanceM = g.distance;v.remainingDistanceM = g.remaining
                v.durationSeconds = g.remaining/1.2;v.arrivalTime = Date().addingTimeInterval(g.remaining/1.2) }
            else { v.headline = "正在规划路线…" }
            if let title = nearbyTransferTitle {
                v.actionTitle = title
                if status.text != guideStatus,let message { v.status = message }
            } else if transitionReady,let link = currentLeg?.link {
                v.maneuver = link.kind == .elevator ? .elevatorUp : link.kind == .stairs ? .stairsUp : .straight
                v.headline = status.text;v.status = .init(detail.text ?? "",level:.information);v.actionTitle = arrivedTitle
            } else if status.text != guideStatus,let message { v.status = message }
            if completed { v.maneuver = .arrive;v.phase = .arrived }
        case .suspended:
            v.headline = "相机已暂停";v.status = message;v.actionTitle = "重启会话"
        case .finished:
            v.headline = "导航已结束"
        }
        if plateToken != nil { v.actionTitle = nil }
        if let label = crossMap.flatMap({ _ in map.map { self.label($0.map_id) } }) { v.floorLabel = label }
        navShell.update(v)
        navShell.setChip(phase == .navigation ? (alignmentTransition != nil ? "正在修正位置" : "位置已确认") : phase == .review ? "待确认" : nil,good:phase == .navigation)
    }
    private static func isWarning(_ text:String) -> Bool {
        ["失败","不可达","失准","偏","不足","暂停","不稳定","离开","无法","异常","错"].contains { text.contains($0) }
    }
    override func viewDidAppear(_ animated:Bool) {
        super.viewDidAppear(animated);guard !started else { return };started = true
        switch AVCaptureDevice.authorizationStatus(for:.video) {
        case .authorized:runSession()
        case .notDetermined:AVCaptureDevice.requestAccess(for:.video) { [weak self] allowed in DispatchQueue.main.async { if allowed { self?.runSession() } else { self?.status.text = "请在系统设置中允许相机访问" } } }
        default:status.text = "请在系统设置中允许相机访问"
        }
    }
    override func viewDidDisappear(_ animated:Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || navigationController?.isBeingDismissed == true {
            headingManager.stopUpdatingHeading();motionManager.stopDeviceMotionUpdates();depthTimeout?.cancel();scene.session.pause();cancellation.cancel();UIApplication.shared.isIdleTimerDisabled = oldIdle
        }
    }
    deinit { motionManager.stopDeviceMotionUpdates();depthTimeout?.cancel();NotificationCenter.default.removeObserver(self) }
    private func runSession() {
        readinessAnnounced = false;invalidateRefresh("session_restarted")
        let config = ARWorldTrackingConfiguration();config.worldAlignment = .gravity
        depthRequested = isMapping || !depthOnDemand;config.frameSemantics = depthRequested ? [.sceneDepth] : []
        configurationRevision += 1;depthGate.cancel();depthAction = nil;depthRequestID = nil;depthTimeout?.cancel()
        config.initialWorldMap = nil;config.planeDetection = [.horizontal];config.sceneReconstruction = []
        recorder?.beginARSession(sessionID,generation:arSessionGeneration)
        startMagneticRecording()
        scene.session.run(config,options:[.resetTracking,.removeExistingAnchors]);normal = false;hasDepth = false
        status.text = depthRequested ? "等待跟踪与深度就绪…" : "等待跟踪就绪 · 定位时再开启深度";refresh();log("session_started",["ar_session_id":sessionID])
    }
    private func startMagneticRecording() {
        // No location request. Query readings feed only the compass screen of ambiguous results.
        headingManager.delegate = self;headingManager.headingFilter = kCLHeadingFilterNone
        headingManager.headingOrientation = .portrait;lastHeadingLog = -.infinity
        let available = CLLocationManager.headingAvailable()
        log("magnetic_recording_available",["available":available,"provider":"CLHeading","used_for_localization":!isMapping && magneticReference != nil,"map_reference":magneticReference != nil])
        if available { headingManager.startUpdatingHeading() }
        if motionManager.isDeviceMotionAvailable && !motionManager.isDeviceMotionActive {
            motionManager.deviceMotionUpdateInterval = 0.05
            motionManager.startDeviceMotionUpdates(using:.xArbitraryZVertical)
        }
    }
    func locationManagerShouldDisplayHeadingCalibration(_ manager:CLLocationManager) -> Bool { false }
    func locationManager(_ manager:CLLocationManager,didFailWithError error:Error) {
        log("magnetic_recording_unavailable",["reason":error.localizedDescription,"used_for_localization":false])
    }
    func locationManager(_ manager:CLLocationManager,didUpdateHeading heading:CLHeading) {
        guard !closing,phase != .suspended,phase != .finished else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let interval = isMapping || phase == .collecting || depthAction != nil || refreshActive ? 0.2 : 1.0
        guard now-lastHeadingLog >= interval else { return };lastHeadingLog = now
        let signedAge = Date().timeIntervalSince(heading.timestamp),age = abs(signedAge)
        let measurementUptime = now-signedAge
        guard [heading.magneticHeading,heading.headingAccuracy,heading.x,heading.y,heading.z,age].allSatisfy(\.isFinite) else {
            log("magnetic_recording_invalid",["reason":"nonfinite_heading_sample"]);return
        }
        var fields:[String:Any] = ["schema_version":2,"ar_session_id":sessionID,"generation":arSessionGeneration,
            "attempt_id":attemptID,"timestamp":now,"configuration_revision":configurationRevision,
            "measurement_utc":ISO8601DateFormatter().string(from:heading.timestamp),"measurement_age_s":age,
            "heading_timestamp_uptime_estimate":measurementUptime,"pairing_clock":"wall_to_uptime_estimate_at_callback",
            "provider":"CLHeading","heading_reference":"device_top_portrait_magnetic_north","heading_orientation":"portrait",
            "reference_axis_device":[0,1,0],"camera_heading_derived":false,
            "axis_mapping_id":"portrait_view_up_v1","axis_mapping_verified":false,
            "magnetic_heading_deg":heading.magneticHeading,"heading_accuracy_deg":heading.headingAccuracy,
            "measurement_valid":heading.headingAccuracy >= 0 && age <= 0.25,
            "magnetic_field_uT":[heading.x,heading.y,heading.z],
            "device_orientation_raw":UIDevice.current.orientation.rawValue,
            "interface_orientation_raw":view.window?.windowScene?.interfaceOrientation.rawValue ?? 0,
            "source_scan_id":writer?.manifest.scan_id as Any? ?? NSNull(),"used_for_localization":!isMapping && magneticReference != nil,"compass_method":LiDARMagnetic.method,
            "camera_pairing_valid":false,"motion_pairing_valid":false,"paired_sample_valid":false,
            "reference_axis_status":"unknown","reference_axis_yaw_session_deg":NSNull(),
            "ar_timestamp":NSNull(),"camera_to_session":NSNull(),"camera_pairing_age_s":NSNull(),
            "portrait_camera_to_session":NSNull(),"reference_axis_in_session":NSNull(),"reference_axis_projection_length":NSNull(),
            "motion_timestamp":NSNull(),"motion_pairing_age_s":NSNull(),"attitude_quaternion_xyzw":NSNull(),
            "attitude_rotation_rows":NSNull(),"gravity_device":NSNull(),"rotation_rate_device_rad_s":NSNull(),
            "user_acceleration_g":NSNull(),"motion_magnetic_field_uT":NSNull(),"motion_magnetic_accuracy_raw":NSNull(),
            "depth_requested":depthRequested,"depth_available":hasDepth]
        var reasons = [String](),cameraValid = false,motionValid = false,axisValid = false
        if heading.headingAccuracy < 0 { reasons.append("heading_accuracy_invalid") }
        if age > 0.25 { reasons.append("heading_stale") }
        if let frame = scene.session.currentFrame {
            let pairedAge = abs(measurementUptime-frame.timestamp)
            fields["camera_to_session"] = matrixRows(frame.camera.transform);fields["ar_timestamp"] = frame.timestamp
            fields["camera_pairing_age_s"] = pairedAge
            cameraValid = pairedAge <= 0.25 && normal
            if cameraValid,!isMapping,refreshActive,heading.headingAccuracy >= 0,age <= 0.25 {
                refreshSamples.append(LiDARMagneticSample(timestamp:now,heading:heading.magneticHeading,accuracy:heading.headingAccuracy,cameraToSession:matrixRows(frame.camera.transform)))
            }
            if cameraValid,!isMapping,phase == .collecting,heading.headingAccuracy >= 0,age <= 0.25 {
                querySamples.append(LiDARMagneticSample(timestamp:now,heading:heading.magneticHeading,accuracy:heading.headingAccuracy,cameraToSession:matrixRows(frame.camera.transform)))
            }
            let portrait = simd_inverse(frame.camera.viewMatrix(for:.portrait))
            let axis = portrait.columns.1,projection = hypot(Double(axis.x),Double(axis.z))
            fields["portrait_camera_to_session"] = matrixRows(portrait)
            fields["reference_axis_in_session"] = [Double(axis.x),Double(axis.y),Double(axis.z)]
            fields["reference_axis_projection_length"] = projection
            fields["axis_yaw_convention"] = "degrees_atan2_X_minusZ_clockwise_from_session_minusZ"
            axisValid = projection.isFinite && projection >= 0.3 && cameraValid
            if axisValid {
                fields["reference_axis_yaw_session_deg"] = atan2(Double(axis.x),-Double(axis.z))*180/Double.pi
                fields["reference_axis_status"] = "paired_unverified_mapping"
            } else { reasons.append(projection < 0.3 ? "reference_axis_near_vertical" : "ar_pair_invalid") }
        } else { reasons.append("ar_frame_missing") }
        if let motion = motionManager.deviceMotion {
            let pairedAge = abs(measurementUptime-motion.timestamp),q = motion.attitude.quaternion,r = motion.attitude.rotationMatrix
            let numbers = [q.x,q.y,q.z,q.w,motion.gravity.x,motion.gravity.y,motion.gravity.z,
                           motion.rotationRate.x,motion.rotationRate.y,motion.rotationRate.z,r.m11,r.m12,r.m13,r.m21,r.m22,r.m23,r.m31,r.m32,r.m33,
                           motion.userAcceleration.x,motion.userAcceleration.y,motion.userAcceleration.z,
                           motion.magneticField.field.x,motion.magneticField.field.y,motion.magneticField.field.z]
            motionValid = pairedAge <= 0.25 && numbers.allSatisfy(\.isFinite)
            if motionValid {
                fields["motion_timestamp"] = motion.timestamp;fields["motion_pairing_age_s"] = pairedAge
                fields["motion_reference_frame"] = "xArbitraryZVertical"
                fields["motion_matrix_convention"] = "CMAttitude.rotationMatrix_unmodified"
                fields["attitude_quaternion_xyzw"] = [q.x,q.y,q.z,q.w]
                fields["attitude_rotation_rows"] = [[r.m11,r.m12,r.m13],[r.m21,r.m22,r.m23],[r.m31,r.m32,r.m33]]
                fields["gravity_device"] = [motion.gravity.x,motion.gravity.y,motion.gravity.z]
                fields["rotation_rate_device_rad_s"] = [motion.rotationRate.x,motion.rotationRate.y,motion.rotationRate.z]
                fields["user_acceleration_g"] = [motion.userAcceleration.x,motion.userAcceleration.y,motion.userAcceleration.z]
                fields["motion_magnetic_field_uT"] = [motion.magneticField.field.x,motion.magneticField.field.y,motion.magneticField.field.z]
                fields["motion_magnetic_accuracy_raw"] = motion.magneticField.accuracy.rawValue
            } else { reasons.append("motion_pair_stale_or_invalid") }
        } else { reasons.append("motion_unavailable") }
        fields["camera_pairing_valid"] = cameraValid;fields["motion_pairing_valid"] = motionValid
        fields["paired_sample_valid"] = cameraValid && motionValid && axisValid && heading.headingAccuracy >= 0 && age <= 0.25
        fields["axis_rejection_reasons"] = reasons
        recorder?.append("magnetic-heading.jsonl",fields)
    }
    private func log(_ event:String,_ fields:[String:Any] = [:]) {
        var context:[String:Any] = ["event":event,"timestamp":ProcessInfo.processInfo.systemUptime,
            "ar_session_id":sessionID,"generation":arSessionGeneration,"request_generation":generation,
            "attempt_id":attemptID,"map_id":map?.map_id ?? "new","configuration_revision":configurationRevision,
            "depth_requested":depthRequested,"depth_available":hasDepth]
        if let writer { context["query_scan_id"] = writer.manifest.scan_id }
        if let candidate {
            context["candidate_index"] = selectedCandidateResultIndex
            context["candidate_selection_index"] = candidateIndex
            context["map_from_session"] = candidate.transform_query_to_map
        }
        recorder?.append("geometry-events.jsonl",context.merging(fields) { _,new in new })
    }
    private func synchronizeDepth(reason:String) {
        guard started,!closing,!parkedAtTransfer,phase != .suspended,phase != .finished,
              let current = scene.session.configuration as? ARWorldTrackingConfiguration,
              let config = current.copy() as? ARWorldTrackingConfiguration else { return }
        let required = isMapping || !depthOnDemand || depthGate.waiting || plateToken != nil || refreshActive || [.collecting,.solving,.review].contains(phase)
        guard depthRequested != required else { return }
        if required { config.frameSemantics.insert(.sceneDepth) } else { config.frameSemantics.remove(.sceneDepth) }
        depthRequested = required;configurationRevision += 1;hasDepth = false
        scene.session.run(config,options:[])
        log("depth_configuration_changed",["reason":reason,"reset_tracking":false,"remove_anchors":false,
            "confirmed_alignment_preserved":alignment.mapFromSession != nil])
    }
    private func requestDepth(for action:DepthAction) {
        guard normal,!working,depthAction == nil,plateToken == nil,!closing,[.idle,.review,.navigation].contains(phase) else { return }
        let requestID = UUID();depthRequestID = requestID
        depthAction = action;depthGate.begin(now:ProcessInfo.processInfo.systemUptime)
        synchronizeDepth(reason:action == .query ? "query_requested" : "plate_requested")
        status.text = "正在请求深度 · 等待新鲜深度帧";refresh();log("depth_request_started",["purpose":action == .query ? "query" : "plate"])
        let timeout = DispatchWorkItem { [weak self] in
            guard let self,self.depthAction != nil,self.depthRequestID == requestID else { return }
            self.cancelDepthRequest("深度请求超时，可重试；原定位保持不变")
        }
        depthTimeout?.cancel();depthTimeout = timeout;DispatchQueue.main.asyncAfter(deadline:.now()+6,execute:timeout)
    }
    private func cancelDepthRequest(_ message:String) {
        depthGate.cancel();depthAction = nil;depthRequestID = nil;depthTimeout?.cancel();depthTimeout = nil
        status.text = message;log("depth_request_cancelled",["reason":message]);synchronizeDepth(reason:"request_ended");refresh()
    }
    private func acceptDepthFrame(_ frame:ARFrame) {
        guard let action = depthAction else { return }
        let state = depthGate.update(frameTimestamp:frame.timestamp,now:ProcessInfo.processInfo.systemUptime,
            hasDepth:frame.sceneDepth?.confidenceMap != nil,trackingNormal:normal)
        switch state {
        case .ready:
            depthAction = nil;depthRequestID = nil;depthTimeout?.cancel();depthTimeout = nil;hasDepth = true
            log("depth_request_ready",["frame_timestamp":frame.timestamp])
            if action == .query { beginCaptureWithDepth() } else { beginPlateWithDepth() }
        case .timedOut:cancelDepthRequest("深度请求超时，可重试；原定位保持不变")
        default:break
        }
    }
    @objc private func thermalChanged() {
        guard Thread.isMainThread else { DispatchQueue.main.async { [weak self] in self?.thermalChanged() };return }
        updateThermal(now:ProcessInfo.processInfo.systemUptime)
        refresh()
    }
    private func updateThermal(now:Double) {
        guard isMapping else { return }
        let wasPaused = thermalGate.paused,oldState = thermalGate.rawState
        thermalGate.update(rawState:ProcessInfo.processInfo.thermalState.rawValue,now:now)
        if thermalGate.paused && !wasPaused {
            thermalResumeAnnounced = false
            log("thermal_capture_paused",["thermal_state":thermalGate.rawState,"coordinate_session_retained":true])
        }
        if oldState != thermalGate.rawState { log("thermal_state_changed",["thermal_state":thermalGate.rawState]) }
        if thermalGate.paused && thermalGate.mayResume(now:now,trackingValid:normal) && !thermalResumeAnnounced {
            thermalResumeAnnounced = true;log("thermal_resume_available",["manual_resume_required":true])
        }
    }
    private func updateSafety(_ frame:ARFrame,position:SIMD3<Float>) {
        let now = frame.timestamp
        guard now-lastSafetyCheck >= 0.5 else { return };lastSafetyCheck = now
        updateThermal(now:ProcessInfo.processInfo.systemUptime)
        var advice = [String]()
        if normal {
            motionSamples.append((now,position));motionSamples.removeAll { now-$0.0 > 1.1 }
            if let first = motionSamples.first,now-first.0 >= 0.5 {
                let speed = Double(simd_distance(first.1,position))/(now-first.0)
                if speed > 0.8 { if fastSince == nil { fastSince = now };if now-(fastSince ?? now) >= 0.75 { advice.append("移动较快，请放慢并缓慢转动手机") } }
                else if speed < 0.6 { fastSince = nil }
            }
            if !thermalGate.paused,let depth = frame.sceneDepth,Self.centralNearFraction(depth) > 0.6 {
                if nearSince == nil { nearSince = now };if now-(nearSince ?? now) >= 0.75 { advice.append("画面中央多数表面过近，请离墙稍远") }
            } else { nearSince = nil }
        } else { motionSamples = [];fastSince = nil;nearSince = nil }
        if thermalGate.paused {
            advice.append(thermalGate.mayResume(now:ProcessInfo.processInfo.systemUptime,trackingValid:normal) ? "温度已降低，请手动恢复；AR坐标仍需保持正常" : "设备过热，已暂停新采集；可直接保存地图，或降温后手动恢复")
        } else if isMapping && thermalGate.throttled {
            advice.append("设备较热，已降低采集频率；可随时保存")
        }
        let text = advice.joined(separator:"\n")
        if text != lastAdvice { lastAdvice = text;log("capture_advice",["message":text,"thermal_state":ProcessInfo.processInfo.thermalState.rawValue]) }
        safetyStatus.text = text;safetyStatus.isHidden = text.isEmpty
    }
    private static func centralNearFraction(_ data:ARDepthData) -> Double {
        let depth = data.depthMap
        guard let confidence = data.confidenceMap,CVPixelBufferGetPixelFormatType(depth) == kCVPixelFormatType_DepthFloat32 else { return 0 }
        CVPixelBufferLockBaseAddress(depth,.readOnly);CVPixelBufferLockBaseAddress(confidence,.readOnly)
        defer { CVPixelBufferUnlockBaseAddress(confidence,.readOnly);CVPixelBufferUnlockBaseAddress(depth,.readOnly) }
        let w = CVPixelBufferGetWidth(depth),h = CVPixelBufferGetHeight(depth)
        guard w == CVPixelBufferGetWidth(confidence),h == CVPixelBufferGetHeight(confidence),
              let base = CVPixelBufferGetBaseAddress(depth),let conf = CVPixelBufferGetBaseAddress(confidence) else { return 0 }
        var count = 0,near = 0
        for y in stride(from:h*3/10,to:h*7/10,by:max(1,h/20)) {
            let row = base.advanced(by:y*CVPixelBufferGetBytesPerRow(depth)).assumingMemoryBound(to:Float.self)
            let c = conf.advanced(by:y*CVPixelBufferGetBytesPerRow(confidence)).assumingMemoryBound(to:UInt8.self)
            for x in stride(from:w*3/10,to:w*7/10,by:max(1,w/20)) where c[x] >= 1 && c[x] <= 2 {
                let v = row[x];if v.isFinite && v >= 0.2 && v <= 4.5 { count += 1;if v < 0.5 { near += 1 } }
            }
        }
        return count >= 20 ? Double(near)/Double(count) : 0
    }
    private func refresh() {
        synchronizeDepth(reason:"phase_or_workflow_changed")
        consistencyStatus.isHidden = consistencyReport?.available != true
        if let report = consistencyReport,report.available {
            let distance = report.camera_correction_m ?? report.origin_mapping_delta_m ?? 0
            consistencyStatus.text = String(format:"%@ · 修正 %.2f 米 / %.1f°（仅诊断）",report.consistent == false ? "与上次人工确认不一致，请核对" : "接近上次人工确认，仍需核对",distance,report.yaw_delta_deg ?? 0)
            consistencyStatus.textColor = report.consistent == false ? .systemOrange : .secondaryLabel
        }
        recordingStatus.text = diagnosticError.map { "诊断记录异常：\($0)。请结束后重试；本次记录可能不完整。" } ?? "诊断记录中 · 相机会话 \(arSessionGeneration+1)"
        recordingStatus.textColor = diagnosticError == nil ? .secondaryLabel : .systemOrange
        let mappingCap = LiDARScanLimits.mapFramesV2
        budgetStatus.text = isMapping ? "关键帧 \(frames)/\(mappingCap)（安全上限） · 体素 \(budgetSnapshot?.voxels ?? cloud.count)/\(LiDARScanLimits.mapVoxelsV3)\n原始数据 \(rawBytesRecorded/1_000_000)/\(LiDARScanLimits.rawBytesV2/1_000_000) MB" : "查询帧 \(frames)/\(queryFrameTarget) · 体素 \(cloud.count)/\(LiDARScanLimits.mapVoxelsV3)"
        if let snapshot = budgetSnapshot { budgetStatus.text! += " · \(snapshot.blocks.count) 个2米块（预算非完整度）" }
        if isMapping,supplementTransform != nil,let text = lineCheckText { budgetStatus.text! += "\n"+text }
        if diagnosticSegment { budgetStatus.text! += "\n异常段仅保留原始数据，未并入导航点云；暂停新增路点。" }
        else if geometryUncertain { budgetStatus.text! += "\n重访数据疑似不一致，已隔离新几何；可点主按钮处理。" }
        if refusedSamples > 0 {
            budgetStatus.text! += "\n局部预算拒收：\(refusedVoxelObservations) 次体素观测（逐批累计）。原始关键帧仍按配额保存。"
        } else if cloud.count >= LiDARScanLimits.mapVoxelsV3 { budgetStatus.text! += "\n点云已满，新区域可能无法加入；原始帧仍按配额保存。" }
        budgetStatus.textColor = cloud.count >= LiDARScanLimits.mapVoxelsV3 || refusedSamples > 0 ? .systemOrange : .secondaryLabel
        navigationItem.leftBarButtonItem?.isEnabled = !(isMapping && phase == .solving)
        navigationItem.rightBarButtonItems?.last?.isEnabled = plateToken == nil && normal && ((!isMapping && [.idle,.review,.navigation].contains(phase)) || (isMapping && phase == .collecting && !geometryUncertain && !diagnosticSegment && !thermalGate.paused)) && ![.solving,.suspended,.finished].contains(phase)
        if isMapping {
            let thermalReady = thermalGate.mayResume(now:ProcessInfo.processInfo.systemUptime,trackingValid:normal)
            primary.setTitle(geometryUncertain && !diagnosticSegment ? "处理疑似偏移" : thermalGate.paused ? (thermalReady ? "已降温 · 手动恢复" : "热暂停 · 等待降温") : phase == .idle ? "开始扫描" : recordingPaused ? "继续扫描" : "暂停扫描",for:.normal)
            primary.isEnabled = plateToken == nil && normal && hasDepth && [.idle,.collecting].contains(phase) && frames < LiDARScanLimits.mapFramesV2 && !rawLimitReached && (!thermalGate.paused || thermalReady)
            secondary.setTitle("标记位置",for:.normal);secondary.isEnabled = normal && phase == .collecting && frames >= 3 && !working && plateToken == nil && pendingMark == nil && !geometryUncertain && !diagnosticSegment
            tertiary.setTitle(diagnosticSegment || geometryUncertain ? "保存异常前部分" : "保存地图",for:.normal);tertiary.isEnabled = [.collecting,.suspended].contains(phase) && nodes.count >= (routeEditor.spaceMode ? 1 : 2) && !working && plateToken == nil
            if phase == .idle { detail.text = "扫描墙角、门框和地面；＋对准地面标点。新节点自动连接所选节点，可在工具中改名或建立分支。" }
        } else {
            switch phase {
            case .idle:primary.setTitle("开始定位",for:.normal)
            case .collecting:primary.setTitle("结束采集并定位",for:.normal)
            case .solving:primary.setTitle("取消定位",for:.normal)
            case .review:primary.setTitle(supplementDirectory != nil ? "确认对齐，开始补采" : "确认该候选，开始导航",for:.normal)
            case .navigation:primary.setTitle(nearbyTransferTitle ?? (transitionReady ? arrivedTitle : "重新定位"),for:.normal)
            case .suspended:primary.setTitle("重启会话",for:.normal)
            case .finished:primary.setTitle("已结束",for:.normal)
            }
            primary.isEnabled = plateToken == nil && (phase == .solving || phase == .suspended || (normal && phase != .finished && (phase != .collecting || (hasDepth && frames >= 3))))
            secondary.setTitle(phase == .review ? "下一个候选" : "报告错位",for:.normal)
            secondary.isEnabled = phase == .review ? (result?.candidates.filter(\.quality_gate).count ?? 0) > 1 : phase == .navigation
            tertiary.setTitle("重新扫描",for:.normal);tertiary.isEnabled = normal && [.idle,.review,.navigation].contains(phase)
            if phase == .idle { detail.text = "起点：\(startPrior?.name ?? "未知，使用全图匹配")\n目的地：\(destinationName)\(destinations.count > 1 ? "（按步行距离选择入口）" : "")\n观察近处固定结构与部分地面；采满设定帧数后计算（默认 32 帧，可在工具中修改）；也可随时手动结束。手机本地计算，不加载旧 ARWorldMap。" }
        }
        if plateToken != nil { primary.isEnabled = false;secondary.isEnabled = false;tertiary.isEnabled = false }
        if let draft = entranceDraft {
            let valid = normal && phase == .collecting && !geometryUncertain && !diagnosticSegment && !thermalGate.paused && !entranceChecking
            primary.setTitle(entranceChecking ? "正在检查接入线…" : "采用这个入口",for:.normal);primary.isEnabled = valid && draft.position != nil
            secondary.setTitle("准星重新点地面",for:.normal);secondary.isEnabled = valid
            tertiary.setTitle(draft.landmark == nil ? "取消添加房间" : "暂不设置入口，仅记录",for:.normal);tertiary.isEnabled = !entranceChecking
            status.text = "设置入口 · \(draft.name)"
            detail.text = draft.position == nil ? "把＋对准走廊一侧的门口地面，点击“准星重新点地面”。没有可靠的门牌三维位置，因此未生成建议点。" : "青色标记为待确认入口；连线是接入预览。请确认位于走廊一侧的门口地面。建议点不是已确认入口，可用准星重新选择。"
            entranceMarker?.isEnabled = valid
        }
        if let draft = pathDraft {
            let valid = normal && phase == .collecting && !geometryUncertain && !diagnosticSegment
            primary.setTitle("完成这条路径（\(draft.count) 点）",for:.normal);primary.isEnabled = valid && draft.count >= 2
            secondary.setTitle("准星加一个路径点",for:.normal);secondary.isEnabled = valid
            tertiary.setTitle(draft.isEmpty ? "取消画路径" : "撤销上一个点",for:.normal);tertiary.isEnabled = true
            status.text = "画建议通行路径"
            detail.text = "把＋对准地面，沿着希望行走的通道逐点加入；路径上必须没有障碍物，导航会贴着这条线走。"
        }
        if depthAction != nil {
            primary.setTitle("取消深度请求",for:.normal);primary.isEnabled = true
            secondary.isEnabled = false;tertiary.isEnabled = false
            navigationItem.rightBarButtonItems?.last?.isEnabled = false
        }
        navigationItem.rightBarButtonItems?.first?.isEnabled = plateToken == nil && depthAction == nil
        updateShell()
        if phase != .navigation || !usesShell { hideFloorPlans() }
    }
    @objc private func act() {
        if depthAction != nil { cancelDepthRequest("已取消深度请求，原定位保持不变");return }
        if pathDraft != nil { finishPathDraft();return }
        if entranceDraft != nil { adoptEntrance();return }
        guard plateToken == nil else { return }
        if isMapping {
            if geometryUncertain && !diagnosticSegment { presentRevisitReview();return }
            if thermalGate.paused {
                if thermalGate.resume(now:ProcessInfo.processInfo.systemUptime,trackingValid:normal) {
                    thermalResumeAnnounced = false;log("thermal_capture_resumed",["manual_pause_retained":recordingPaused])
                    status.text = recordingPaused ? "热暂停已解除 · 仍处于手动暂停" : "热暂停已解除 · 可继续扫描";refresh()
                }
                return
            }
            if phase == .idle { beginCapture() }
            else if phase == .collecting { recordingPaused.toggle();status.text = recordingPaused ? "扫描已暂停 · 可继续标点" : "继续扫描";refresh() }
            return
        }
        if phase == .navigation,nearbyTransferTitle != nil { confirmTransferArrival();return }
        if phase == .navigation && transitionReady { switchToNextLeg();return }
        switch phase {
        case .idle,.navigation:beginCapture()
        case .collecting:finishQuery()
        case .solving:log("localization_cancelled");cancellation.cancel();generation += 1;phase = .idle;status.text = "已取消定位";refresh()
        case .review:confirm()
        case .suspended:
            clearConfirmedReference("session_restart");log("session_restart_requested");sessionID = UUID().uuidString;arSessionGeneration += 1;generation += 1;alignment.reset(sessionID:sessionID);previousTime = nil;previousPosition = nil;unhealthySince = nil
            phase = .idle;runSession()
        default:break
        }
    }
    @objc private func second() {
        if pathDraft != nil { addPathPoint();return }
        if entranceDraft != nil { placeEntranceAtReticle();return }
        guard plateToken == nil else { return }
        if isMapping { mark();return }
        if phase == .review {
            let candidates = result?.candidates.filter(\.quality_gate) ?? []
            if !candidates.isEmpty { candidateIndex = (candidateIndex+1)%candidates.count;spacePlanned = [];lastSpacePlan = nil;spaceFailure = nil;lineComparison = nil;liveLines = [];lastLinesUpdate = -.infinity;log("candidate_selected");showCandidate() }
        } else if phase == .navigation {
            log("physical_alignment_rejected");clearConfirmedReference("reported_misalignment");root?.isEnabled = false;status.text = "已记录错位，路线已隐藏";phase = .idle;alignment.reset(sessionID:sessionID);refresh()
        }
    }
    @objc private func third() {
        if var draft = pathDraft { if draft.isEmpty { pathDraft = nil } else { draft.removeLast();pathDraft = draft };renderPaths();refresh();return }
        if entranceDraft != nil { skipEntrance();return };if isMapping { saveMap() } else { beginCapture() } }
    private func beginCapture() {
        if !isMapping { requestDepth(for:.query);return }
        beginCaptureWithDepth()
    }
    private func beginCaptureWithDepth() {
        guard normal,hasDepth,!working,phase != .solving,!(isMapping && thermalGate.paused) else { return }
        do {
            var info = LiDARScanManifest(role:isMapping ? .map : .query,label:name,buildingID:captureBuilding?.id ?? "geometry",regionID:map?.map_id ?? "standalone",regionName:name,lighting:lighting,hardware:ProbeIO.hardwareIdentifier(),appVersion:Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "0.2.0")
            info.session_id = sessionID
            info.schema_version = 2
            if isMapping,let transform = supplementTransform,let map {
                info.supplement_of_map_id = map.map_id;info.map_from_session = transform;info.label = "补采 · "+name
            }
            writer = try LiDARScanWriter(root:LiDARLibrary.root,manifest:info)
            consistencyReport = nil
            refusedSamples = 0;refusedVoxelObservations = 0
            attemptID = UUID().uuidString
            frames = 0;skipped = 0;result = nil;candidateIndex = 0;recordingPaused = false
            lastTrialFrames = 0;earlyStopRequested = false;lastTrialStatus = nil;extensionAnnounced = false;lastQueryPose = nil
            lastQueryProgress = ProcessInfo.processInfo.systemUptime;lastQueryFrameCount = 0;stallPrompted = false
            querySamples = [];magneticScreen = nil
            if supplementTransform == nil { cloud = [:] }
            lastCapture = -.infinity;captureStarted = nil;requestStarted = ProcessInfo.processInfo.systemUptime
            generation += 1;cancellation.cancel();cancellation = LiDARWorkCancellation();phase = .collecting
            root?.isEnabled = isMapping;status.text = "采集中 · 缓慢观察固定结构";refresh();log("query_or_mapping_started",["scan_id":info.scan_id,"role":info.role.rawValue])
        } catch { campusError(error) }
    }
    func session(_ session:ARSession,didUpdate frame:ARFrame) {
        guard !closing,phase != .finished else { return }
        if case .normal = frame.camera.trackingState { normal = true } else { normal = false }
        hasDepth = depthRequested && frame.sceneDepth?.confidenceMap != nil
        let t = frame.timestamp,p = SIMD3(frame.camera.transform.columns.3.x,frame.camera.transform.columns.3.y,frame.camera.transform.columns.3.z)
        if let previousTime,let previousPosition,t > previousTime,
           (t-previousTime > 0.75 || (t-previousTime < 0.2 && simd_distance(previousPosition,p) > 0.8)) {
            suspend("检测到帧间隔或位置突变，坐标已停用；过快、过近或高温可能相关");return
        }
        previousTime = t;previousPosition = p
        updateSafety(frame,position:p)
        if !normal {
            if entranceDraft != nil { cancelPlate("跟踪发生变化，入口选择已取消，请重新设置") }
            pendingMark?.invalid = true
            clearConfirmedReference("tracking_unavailable")
            root?.isEnabled = false
            if unhealthySince == nil { unhealthySince = t }
            if t-(unhealthySince ?? t) > 3 { suspend("跟踪持续不可用，请重新启动会话");return }
        } else { unhealthySince = nil }
        acceptDepthFrame(frame)
        if plateCollecting { feedPlate(frame) }
        if !isMapping { watchPlates(frame);refreshTick(frame) }
        if normal && phase == .idle && !readinessAnnounced {
            readinessAnnounced = true;status.text = isMapping ? "已就绪 · 可开始建图" : "已就绪 · 独立几何定位"
        }
        if normal,phase == .collecting,plateToken == nil,!recordingPaused,!(isMapping && thermalGate.paused) {
            if captureStarted == nil { captureStarted = t }
            let elapsed = t-(captureStarted ?? t)
            if isMapping && (frames >= LiDARScanLimits.mapFramesV2 || rawLimitReached) {
                recordingPaused = true;status.text = "扫描已达到上限 · 请完成标点并保存";refresh()
            } else if !isMapping && queryShouldStop(elapsed:elapsed) {
                if !working {
                    if frames < 3 {
                        phase = .idle;status.text = "有效深度不足，已停止本次查询，请观察近处结构后重试"
                        if let writer { io.async { _ = try? writer.finish(reason:"insufficient_depth_frames",valid:false) } }
                        log("query_insufficient_depth",["frames":frames]);refresh()
                    } else { finishQuery() }
                }
            } else if isMapping ? t-lastCapture >= (thermalGate.throttled ? 0.6 : 0.25) : queryFrameDue(frame),!working,let depth = frame.sceneDepth,let confidence = depth.confidenceMap {
                capture(frame,depth:depth.depthMap,confidence:confidence)
            }
            if !isMapping,!(earlyStopRequested && autoEarlyStop),!trialRunning,frames >= 4,frames-lastTrialFrames >= 2,frames < queryFrameTarget,
               ProcessInfo.processInfo.thermalState.rawValue < 2 { startEarlyStopTrial(frame) }
        }
        if normal,t-lastRender > (alignmentTransition != nil ? 0 : isMapping && thermalGate.paused ? 1 : isMapping && thermalGate.throttled ? 0.7 : 0.35) {
            lastRender = t
            if isMapping { root?.isEnabled = true }
            else if phase == .review || phase == .navigation { renderNavigation(frame) }
        }
        if !isMapping { updateChain(frame);updateFloorPlans(frame);updateTurnGuide(frame);updateElevator() }
        updatePointOverlay(frame)
        updateStructureLines(frame)
        if t-lastLog > 0.5 {
            lastLog = t
            recorder?.append("camera-poses.jsonl",["timestamp":t,"ar_session_id":sessionID,"generation":arSessionGeneration,"request_generation":generation,"attempt_id":attemptID,"camera_to_session":matrixRows(frame.camera.transform),"tracking_normal":normal,"thermal_state":ProcessInfo.processInfo.thermalState.rawValue,"phase":String(describing:phase),"configuration_revision":configurationRevision,"depth_requested":depthRequested,"depth_available":hasDepth])
        }
        if t-lastUIRefresh >= 0.2 { lastUIRefresh = t;refresh() }
    }
    /// Query frames by new view, not by clock: moved 0.15 m or turned 8° since the last one
    /// (at most every 0.15 s); a still phone still gets one frame per second.
    private var lastQueryPose:simd_float4x4?
    private func queryFrameDue(_ frame:ARFrame) -> Bool {
        let dt = frame.timestamp-lastCapture
        guard dt >= 0.15 else { return false }
        guard let last = lastQueryPose,dt < 1.0 else { return true }
        let moved = simd_distance(SIMD3(last.columns.3.x,last.columns.3.y,last.columns.3.z),SIMD3(frame.camera.transform.columns.3.x,frame.camera.transform.columns.3.y,frame.camera.transform.columns.3.z))
        let a = -SIMD3(last.columns.2.x,last.columns.2.y,last.columns.2.z),b = -SIMD3(frame.camera.transform.columns.2.x,frame.camera.transform.columns.2.y,frame.camera.transform.columns.2.z)
        let turned = acos(max(-1,min(1,simd_dot(simd_normalize(a),simd_normalize(b)))))*180/Float.pi
        return moved >= 0.15 || turned >= 8
    }
    private func capture(_ frame:ARFrame,depth:CVPixelBuffer,confidence:CVPixelBuffer) {
        guard let writer else { return };working = true;lastCapture = frame.timestamp
        if !isMapping { lastQueryPose = frame.camera.transform }
        let index = frames,token = generation,t = frame.timestamp,cancel = cancellation,manual = manualKeyframeRequested
        let calibration = LiDARCalibration(width:CVPixelBufferGetWidth(depth),height:CVPixelBufferGetHeight(depth),imageWidth:CVPixelBufferGetWidth(frame.capturedImage),imageHeight:CVPixelBufferGetHeight(frame.capturedImage),fx:Double(frame.camera.intrinsics[0][0]),fy:Double(frame.camera.intrinsics[1][1]),cx:Double(frame.camera.intrinsics[2][0]),cy:Double(frame.camera.intrinsics[2][1]))
        let pose = matrixRows(frame.camera.transform),image = frame.capturedImage
        // Geometry, budget and keyframe decisions use map coordinates; the raw scan keeps session poses.
        let geometryPose = toMapPose(pose)
        io.async { [self] in
            let outcome = Result { () -> CaptureResult in
                var output = CaptureResult()
                let bytes = try Self.pack(depth,format:kCVPixelFormatType_DepthFloat32,bytesPerPixel:4)
                let conf = try Self.pack(confidence,format:kCVPixelFormatType_OneComponent8,bytesPerPixel:1)
                guard CVPixelBufferGetWidth(confidence) == calibration.width,CVPixelBufferGetHeight(confidence) == calibration.height else { throw LiDARScanError.invalid("深度和置信度尺寸不符") }
                var metadata = LiDARFrame(index:index,timestamp:t,transform:pose,calibration:calibration,validFraction:0)
                var geometryFrame = metadata;geometryFrame.camera_to_session = geometryPose
                let observations = try LiDARGeometry.observations(depth:bytes,confidence:conf,frame:geometryFrame,pixelStride:4)
                let points = observations.map(\.point)
                metadata.valid_fraction = Double(points.count)/Double(((calibration.width+3)/4)*((calibration.height+3)/4))
                guard metadata.valid_fraction >= 0.05 else { output.skip = "low_depth";return output }
                if isMapping {
                    let preview = mappingBudget.preview(observations)
                    output.blocked = preview.blocked
                    let decision = keyframePolicy.decide(.init(timestamp:t,cameraToSession:geometryPose,trackingNormal:true,validDepthFraction:metadata.valid_fraction,preview:preview,manual:manual))
                    output.reasons = decision.reasons
                    // Revisit separately from storage: a saturated region may have no novel voxels.
                    let movedForRevisit:Bool
                    if let old = ioLastRevisitPose {
                        let distance = sqrt((0..<3).reduce(0.0) { $0+pow(geometryPose[$1][3]-old[$1][3],2) })
                        let dot = (0..<3).reduce(0.0) { $0+geometryPose[$1][2]*old[$1][2] }
                        movedForRevisit = distance >= 0.2 || acos(max(-1,min(1,dot)))*180/Double.pi >= 10
                    } else { movedForRevisit = true }
                    if revisitGate.mode != .diagnostic_segment,t-ioLastRevisit >= 1,movedForRevisit {
                        let report = mappingBudget.revisitCheck(observations)
                        ioLastRevisit = t;ioLastRevisitPose = geometryPose;output.revisit = report
                    }
                    let gate = revisitGate.step(output.revisit,batchBeforeCommit:mappingBudget.batch)
                    output.quarantined = !gate.commitGeometry;output.flagged = gate.newlyFlagged;output.captureBaseline = gate.captureBaseline
                    if output.quarantined { output.diagnosticPoints = LiDARSampling.voxel(observations.map(\.point),size:0.15,limit:1500) }
                    if gate.newlyFlagged,let boundary = gate.rollbackToBatch {
                        // Undo geometry committed since the suspect streak began; those frames become diagnostic.
                        mappingBudget.rollback(toBatch:boundary)
                        let undone = frameForBatch.filter { $0.key > boundary }.map(\.value)
                        acceptedFrameIDs.removeAll { undone.contains($0) };diagnosticFrameIDs.append(contentsOf:undone)
                        frameForBatch = frameForBatch.filter { $0.key <= boundary }
                        for observation in observations { mappingBudget.markSuspect(observation.point) }
                        output.resetCloud = mappingBudget.points
                    }
                    guard decision.accept || output.revisit?.status == "suspect" else {
                        let reason = decision.skip_reason ?? "not_selected";skippedByReason[reason,default:0] += 1
                        output.skip = reason;output.skips = skippedByReason;output.snapshot = mappingBudget.snapshot()
                        return output
                    }
                }
                guard !cancel.isCancelled else { output.skip = "cancelled";return output }
                guard let jpeg = context.jpegRepresentation(of:CIImage(cvPixelBuffer:image),colorSpace:CGColorSpaceCreateDeviceRGB(),options:[kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption:0.55]) else { throw LiDARScanError.invalid("保存照片失败") }
                if isMapping,writer.rawBytes+manualEvidenceBytes+bytes.count+conf.count+jpeg.count > LiDARScanLimits.rawBytesV2 {
                    output.limit = "已达到原始数据空间上限；仍可保存已接受的路网";return output
                }
                let free = (try? FileManager.default.attributesOfFileSystem(forPath:writer.directory.path)[.systemFreeSize] as? NSNumber)?.int64Value
                if let free,free < Int64(bytes.count+conf.count+jpeg.count)+100_000_000 {
                    output.limit = "可用存储空间不足，已暂停新采集；请先保存或导出";return output
                }
                _ = try writer.append(frame:metadata,depth:bytes,confidence:conf,jpeg:jpeg)
                output.stored = true;output.rawBytes = writer.rawBytes+manualEvidenceBytes
                if isMapping {
                    if !cancel.isCancelled && !output.quarantined {
                        let commit = mappingBudget.commit(observations)
                        output.refused = commit.refused_block+commit.refused_global;output.points = commit.updated_points;output.committed = true
                        acceptedFrameIDs.append(index);frameForBatch[commit.batch] = index
                    } else { diagnosticFrameIDs.append(index) }
                    keyframePolicy.didAccept(timestamp:t,cameraToSession:geometryPose)
                    output.snapshot = mappingBudget.snapshot()
                    // Small metadata checkpoint: geometry itself remains in the batch store.
                    try LiDARNavigationStore.write(output.snapshot!,to:writer.directory.appendingPathComponent("budget-summary.json"))
                    try writer.event(output.committed ? "keyframe_geometry_accepted" : "keyframe_diagnostic_only",timestamp:t,details:"frame=\(index);batch=\(mappingBudget.batch);reasons=\(output.reasons.joined(separator:","))")
                } else { output.points = points;output.committed = true }
                return output
            }
            DispatchQueue.main.async { [self] in
                working = false
                guard token == generation,phase == .collecting else {
                    if savePending,phase == .suspended,!closing { savePending = false;saveMap() }
                    return
                }
                switch outcome {
                case .success(let value):
                    if let snapshot = value.snapshot { budgetSnapshot = snapshot }
                    if !value.diagnosticPoints.isEmpty { diagnosticOverlayPoints = value.diagnosticPoints }
                    if let report = value.revisit { log("revisit_diagnostic",Self.jsonFields(report)) }
                    // Snapshot the route at the first suspect of a streak; forget it once the streak ends.
                    if value.captureBaseline && !geometryUncertain { baselineEditor = routeEditor }
                    else if value.revisit?.status == "ok" && !geometryUncertain && !diagnosticSegment { baselineEditor = nil }
                    if let reset = value.resetCloud {
                        cloud = [:];for point in reset { cloud[LiDARVoxelKey(point,size:0.10)] = point }
                        if supplementTransform != nil {
                            let base = Set(referencePoints.map { LiDARVoxelKey($0,size:0.10) })
                            supplementNew = cloud.filter { !base.contains($0.key) }
                        }
                    }
                    if value.flagged { geometryUncertain = true;pendingMark?.invalid = true }
                    if let limit = value.limit { rawLimitReached = true;recordingPaused = true;status.text = limit;log("capture_storage_limit",["reason":limit]) }
                    if value.stored {
                        frames += 1;rawBytesRecorded = value.rawBytes;manualKeyframeRequested = false
                        if value.committed { lastAcceptedForMark = (index,t) }
                        if isMapping {
                            for point in value.points { cloud[LiDARVoxelKey(point,size:0.10)] = point }
                            if supplementTransform != nil { for point in value.points { supplementNew[LiDARVoxelKey(point,size:0.10)] = point } }
                        } else { _ = LiDARCaptureBudget.ingest(value.points,into:&cloud) }
                        refusedSamples += value.refused;refusedVoxelObservations += value.refused
                        log("keyframe_stored",["frame_index":index,"geometry_accepted":value.committed,"reasons":value.reasons,"budget_refused_observations":value.refused])
                        status.text = geometryUncertain || diagnosticSegment ? "诊断采集中 · 新几何尚未并入" : value.quarantined ? "这一帧与已存表面不一致，未并入 · 继续采集" : "\(isMapping ? "建图" : "定位采集") · \(frames) 帧"
                        detail.text = isMapping ? "\(nodes.count) 个节点 · \(edges.count) 条连接\n连接起点：\(nodes.first(where:{$0.id == selectedNode})?.name ?? "未选择（下一点不连线）")。重复视角会跳过，可暂停后标点。" : "观察不同方向的墙面、转角和部分地面；采满设定帧数后计算（默认 32 帧，可在工具中修改）；也可随时手动结束。"
                    } else if let reason = value.skip {
                        skipped += 1
                        if t-lastSkipLog >= 3 { lastSkipLog = t;log("keyframe_skipped_summary",["reason":reason,"counts":value.skips,"blocked_observations":value.blocked]);status.text = "观察中 · 已保留 \(frames) 帧，等待新信息" }
                    }
                    if value.flagged,presentedViewController == nil { presentRevisitReview() }
                    if savePending { savePending = false;saveMap() }
                case .failure(let error):suspend("采集写入未完成：\(error.localizedDescription)")
                }
                refresh()
            }
        }
    }
    private static func jsonFields<T:Encodable>(_ value:T) -> [String:Any] {
        guard let bytes = try? JSONEncoder().encode(value),let object = try? JSONSerialization.jsonObject(with:bytes) as? [String:Any] else { return [:] }
        return object
    }
    private func presentRevisitReview() {
        guard isMapping,presentedViewController == nil else { return }
        recordingPaused = true;refresh()
        let alert = UIAlertController(title:"疑似偏移或重影",message:"连续多次新观测与已保留表面不一致，可能来自测量、场景变化或坐标偏移。从第一次不一致开始的新几何已撤回并隔离，期间标的节点保存时也会撤回。这不是精度测量。",preferredStyle:.alert)
        alert.addAction(UIAlertAction(title:"暂停检查",style:.cancel) { [weak self] _ in self?.log("revisit_user_paused") })
        alert.addAction(UIAlertAction(title:"保存异常前已接受部分并结束",style:.default) { [weak self] _ in
            guard let self else { return };if let baselineEditor { self.routeEditor = baselineEditor;self.syncRouteEditor() };self.saveMap()
        })
        alert.addAction(UIAlertAction(title:"标记异常后继续（仅诊断）",style:.default) { [weak self] _ in
            guard let self else { return };if let baselineEditor { self.routeEditor = baselineEditor;self.syncRouteEditor() }
            self.diagnosticSegment = true;self.geometryUncertain = false;self.recordingPaused = false
            self.io.async { [self] in self.revisitGate.continueAsDiagnostic() }
            self.log("revisit_diagnostic_segment_started");self.refresh()
        })
        present(alert,animated:true)
    }
    private static func pack(_ buffer:CVPixelBuffer,format:OSType,bytesPerPixel:Int) throws -> Data {
        guard CVPixelBufferGetPixelFormatType(buffer) == format else { throw LiDARScanError.invalid("深度格式不受支持") }
        CVPixelBufferLockBaseAddress(buffer,.readOnly);defer { CVPixelBufferUnlockBaseAddress(buffer,.readOnly) }
        let stride = CVPixelBufferGetBytesPerRow(buffer),height = CVPixelBufferGetHeight(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw LiDARScanError.invalid("无法读取深度") }
        return try LiDARGeometry.packedRows(Data(bytes:base,count:stride*height),rowBytes:CVPixelBufferGetWidth(buffer)*bytesPerPixel,height:height,stride:stride)
    }
    /// 12 frames / 10 s as before, unless the trials still see several or no acceptable
    /// candidates: then keep collecting (new views add constraints) up to 24 frames / 20 s.
    /// Collect until the chosen frame count (no time cut-off). A unique trial stops early only when
    /// the person enabled it; otherwise it is announced and the person may end the capture by hand.
    private func queryShouldStop(elapsed:Double) -> Bool {
        if earlyStopRequested && autoEarlyStop { return true }
        if frames >= min(queryFrameTarget,LiDARScanLimits.queryFramesV2) { return true }
        // No progress for 8 s: say why and let the person choose; never stop silently.
        let now = ProcessInfo.processInfo.systemUptime
        if frames != lastQueryFrameCount { lastQueryFrameCount = frames;lastQueryProgress = now }
        else if now-lastQueryProgress > 8 && !stallPrompted && presentedViewController == nil {
            stallPrompted = true
            let why = !normal ? "跟踪不正常" : !hasDepth ? "没有可用深度（离墙太远或太近、玻璃反光）" : "画面没有新视角（请缓慢转动或移动手机）"
            log("query_stalled",["frames":frames,"reason":why])
            let alert = UIAlertController(title:"采集没有进展",message:"已采 \(frames) 帧，\(why)。",preferredStyle:.alert)
            alert.addAction(UIAlertAction(title:"继续等待",style:.cancel) { [weak self] _ in self?.stallPrompted = false;self?.lastQueryProgress = ProcessInfo.processInfo.systemUptime })
            if frames >= 3 { alert.addAction(UIAlertAction(title:"用已有数据定位",style:.default) { [weak self] _ in self?.finishQuery() }) }
            alert.addAction(UIAlertAction(title:"取消定位",style:.destructive) { [weak self] _ in
                guard let self else { return };self.cancellation.cancel();self.generation += 1;self.phase = .idle;self.status.text = "已取消定位";self.log("localization_cancelled");self.refresh()
            })
            present(alert,animated:true)
        }
        return false
    }
    private func structureGridForCompute(_ reference:LiDARMagnetic.Reference?) -> LiDARStructureGrid? {
        if reference != nil && structureGrid == nil && !referencePoints.isEmpty { structureGrid = LiDARStructureGrid(points:referencePoints) }
        return structureGrid
    }
    /// compute queue only.
    private func magneticScreenFor(_ result:LiDARLocalizationResult,query:[LiDARMagneticSample],reference:LiDARMagnetic.Reference?) -> LiDARMagnetic.Screen {
        if reference != nil && structureGrid == nil && !referencePoints.isEmpty { structureGrid = LiDARStructureGrid(points:referencePoints) }
        return LiDARMagnetic.screen(candidateTransforms:result.candidates.map(\.transform_query_to_map),decisionReasons:result.decision_reasons ?? [],
                                    query:query,reference:reference,structure:structureGrid)
    }
    private var currentPlateSearch:PlateSearch? {
        guard let p = plateSearch,p.session == sessionID,p.generation == arSessionGeneration else { return nil };return p
    }
    private func watchPlates(_ frame:ARFrame) {
        let now = frame.timestamp
        // Watch before, during and after relocalization; a tap re-localizes from the plate's room.
        let phases:[Phase] = [.idle,.collecting,.review,.navigation],heat = ProcessInfo.processInfo.thermalState.rawValue
        if !shownChips.isEmpty,plateWatchSeen.values.allSatisfy({ now-$0.last > 5 }) || !phases.contains(phase) { updatePlateChips([]) }
        guard normal,!plateWatchBusy,now-lastPlateWatch >= (heat >= 2 ? 1.6 : 0.8),plateToken == nil,depthAction == nil,!closing,!knownPlates.isEmpty,
              phases.contains(phase) else { return }   // never stopped by heat; only slowed above
        plateWatchBusy = true;lastPlateWatch = now
        let known = Dictionary(knownPlates.map { (LiDARText.normalize($0.text.raw),$0.text.raw) },uniquingKeysWith:{ a,_ in a })
        let image = frame.capturedImage,depth = frame.sceneDepth,pose = matrixRows(frame.camera.transform)   // query session coordinates
        let calibration = LiDARCalibration(width:depth.map { CVPixelBufferGetWidth($0.depthMap) } ?? 0,height:depth.map { CVPixelBufferGetHeight($0.depthMap) } ?? 0,
            imageWidth:CVPixelBufferGetWidth(image),imageHeight:CVPixelBufferGetHeight(image),fx:Double(frame.camera.intrinsics[0][0]),fy:Double(frame.camera.intrinsics[1][1]),cx:Double(frame.camera.intrinsics[2][0]),cy:Double(frame.camera.intrinsics[2][1]))
        let sid = sessionID,generation = arSessionGeneration
        ocrQueue.async { [self] in
            var matched = [String:(raw:String,sample:LiDARLandmarkSample?)](),read = [String]()
            let ci = CIImage(cvPixelBuffer:image)
            // No minimum text height: room numbers seen from 1–1.5 m are only ~2% of the frame (same as manual plate capture).
            if let cg = context.createCGImage(ci,from:ci.extent),let texts = try? LiDAROCR.recognize(cg,orientation:.right) {
                read = texts.prefix(8).map(\.text)
                for t in texts {
                    for candidate in [t.text]+t.candidates.map(\.text) {
                        let key = LiDARText.normalize(candidate)
                        guard let raw = known[key],matched[key] == nil else { continue }
                        var sample:LiDARLandmarkSample?
                        if let depth,let conf = depth.confidenceMap,
                           let d = try? Self.pack(depth.depthMap,format:kCVPixelFormatType_DepthFloat32,bytesPerPixel:4),
                           let c = try? Self.pack(conf,format:kCVPixelFormatType_OneComponent8,bytesPerPixel:1) {
                            let box = LiDARLandmarkGeometry.nativeBox(visionBox:t.vision_box,imageWidth:calibration.image_width,imageHeight:calibration.image_height)
                            sample = LiDARLandmarkSample(frame:LiDARFrame(index:0,timestamp:now,transform:pose,calibration:calibration,validFraction:0),depth:d,confidence:c,nativeBox:box)
                        }
                        matched[key] = (raw,sample)
                    }
                }
            }
            DispatchQueue.main.async { [self] in
                plateWatchBusy = false
                guard sid == sessionID,generation == arSessionGeneration,!closing else { return }
                plateWatchHistory.append(Set(matched.keys));if plateWatchHistory.count > 3 { plateWatchHistory.removeFirst() }
                // Diagnostics: what was read when nothing matched (throttled), so misses can be explained from the export.
                if matched.isEmpty && !read.isEmpty && now-lastPlateWatchLog >= 3 {
                    lastPlateWatchLog = now;log("plate_watch_unmatched",["read":read,"known":Array(known.keys).sorted()])
                }
                for (key,m) in matched {
                    var entry = plateWatchSeen[key] ?? (m.raw,now,[])
                    entry.last = now
                    if let sample = m.sample { entry.samples.append(sample);if entry.samples.count > 3 { entry.samples.removeFirst() } }
                    plateWatchSeen[key] = entry
                }
                let stable = plateWatchSeen.keys.filter { key in plateWatchHistory.filter { $0.contains(key) }.count >= 2 && now-(plateWatchSeen[key]?.last ?? 0) <= 5 }.sorted()
                if stable != shownChips { updatePlateChips(stable) }
            }
        }
    }
    private func updatePlateChips(_ keys:[String]) {
        if keys.count > shownChips.count { log("plate_auto_recognized",["texts":keys.compactMap { plateWatchSeen[$0]?.raw }]) }
        shownChips = keys
        plateChips.arrangedSubviews.forEach { $0.removeFromSuperview() }
        defer { if refreshSuggestion != nil { showRefreshChip() } }
        for key in keys.prefix(3) {
            guard let entry = plateWatchSeen[key],let map else { continue }
            let centers = LiDARPlateSearch.centers(text:entry.raw,landmarks:knownPlates,map:map).count
            var config = UIButton.Configuration.filled();config.baseBackgroundColor = .systemIndigo;config.cornerStyle = .capsule
            config.title = "识别到「\(plateDisplayName(key,fallback:entry.raw))」· 点此定位";config.subtitle = centers > 0 ? "\(centers) 处入口/门牌位置" : "地图中没有可搜索的位置"
            let button = UIButton(configuration:config,primaryAction:UIAction { [weak self] _ in self?.useRecognizedPlate(key) })
            button.isEnabled = centers > 0;button.accessibilityLabel = "识别到门牌 \(entry.raw)，点按用于定位"
            plateChips.addArrangedSubview(button)
        }
    }
    /// Shown name of a recognised plate text (its display name when it has one).
    private func plateDisplayName(_ key:String,fallback:String) -> String {
        guard let plate = knownPlates.first(where:{ LiDARText.normalize($0.text.raw) == key }) else { return fallback }
        return plate.displayName == plate.text.raw ? plate.text.raw : "\(plate.displayName)（\(plate.text.raw)）"
    }
    private func useRecognizedPlate(_ key:String) {
        guard let entry = plateWatchSeen[key] else { return }
        // The tap is the person's confirmation of the room. Geometry comes from the frames that
        // read it with depth; the mount is taken from the map's plates of that text.
        let mapPlates = knownPlates.filter { LiDARText.normalize($0.text.raw) == key }
        var query = LiDARLandmark(category:.room_plate,trigger:.auto,text:LiDARLandmarkText(raw:entry.raw,candidates:[],confirmedByUser:true,edited:false),
            destination:LiDARLandmarkDestination(enabled:false,node_id:nil),geometry:LiDARLandmarkGeometry.measure(entry.samples),evidence:[])
        query.mount = mapPlates.allSatisfy { $0.mount == .wall } ? .wall : .unknown
        log("plate_auto_selected",["text":entry.raw,"depth_samples":entry.samples.count,"geometry_status":query.geometry.status])
        updatePlateChips([]);plateWatchHistory = [];plateWatchSeen = [:]
        beginPlateSearch(entry.raw,query:query)
    }
    private func beginPlateSearch(_ text:String,query:LiDARLandmark) {
        guard let map else { return }
        let centers = LiDARPlateSearch.centers(text:text,landmarks:knownPlates,map:map)
        guard !centers.isEmpty else { campusMessage("没有可搜索的位置","地图中「\(text)」没有入口或已测量的门牌位置。");return }
        let key = LiDARText.normalize(text)
        let mapPlates = knownPlates.filter { $0.usableForPose && LiDARText.normalize($0.text.raw) == key }
        let pose = query.usableForPose && mapPlates.count == 1 ? LiDARPlateSearch.poseFromPlate(query:query.geometry,map:mapPlates[0].geometry) : nil
        plateSearch = PlateSearch(text:text,centers:centers,pose:pose,point:query.geometry.center,session:sessionID,generation:arSessionGeneration)
        log("plate_search_started",["text":text,"centers":centers.count,"plate_pose":pose != nil])
        status.text = "门牌定位 · 在「\(text)」的 \(centers.count) 处位置附近搜索";refresh()
        if phase == .collecting { lastTrialFrames = 0;return }   // the running query uses the plate windows
        beginCapture()
    }
    /// One search for the current scope (plate windows, start-node windows, or the whole map,
    /// tiled when large), optionally restricted to a compass yaw prior. compute queue only.
    private static func search(reference:[ProbePoint],points:[ProbePoint],sid:String,referenceCamera:ProbePoint?,startNode:LiDARRouteNode?,
                               plate:PlateSearch?,prior:(center:Double,halfWidth:Double)?,seconds:Double,cancel:LiDARWorkCancellation,near:ProbePoint?) -> [LiDARLocalizationResult] {
        if let plate,let referenceCamera {
            return [LiDARPlateSearch.solve(map:reference,query:points,sessionID:sid,referenceCamera:referenceCamera,centers:plate.centers,
                maxSeconds:seconds,cancellation:cancel,platePose:plate.pose,platePoint:plate.point,yawPrior:prior)]
        }
        if let startNode,let referenceCamera {
            return LiDARLocalizer.solveWindowed(map:reference,query:points,sessionID:sid,referenceCamera:referenceCamera,
                center:startNode.position,centerNodeID:startNode.id,radii:[10,15,25],maxSeconds:seconds,cancellation:cancel,yawPrior:prior).tiers
        }
        if let referenceCamera {
            return [LiDARLocalizer.solveGlobal(map:reference,query:points,sessionID:sid,referenceCamera:referenceCamera,maxSeconds:seconds,cancellation:cancel,yawPrior:prior,near:near)]
        }
        return [LiDARLocalizer.solve(map:reference,query:points,sessionID:sid,maxSeconds:seconds,cancellation:cancel,yawPrior:prior)]
    }
    /// Compass first (when the map has a reference and the readings are steady); without a passing
    /// candidate inside the prior, search every direction. compute queue only.
    private func searchWithCompass(reference:[ProbePoint],points:[ProbePoint],sid:String,referenceCamera:ProbePoint?,startNode:LiDARRouteNode?,
                                   plate:PlateSearch?,magnetic:[LiDARMagneticSample],magneticRef:LiDARMagnetic.Reference?,seconds:Double,
                                   cancel:LiDARWorkCancellation,near:ProbePoint?) -> [LiDARLocalizationResult] {
        if let prior = LiDARMagnetic.yawPrior(query:magnetic,reference:magneticRef,near:plate?.centers.first?.position ?? startNode?.position ?? near,structure:structureGridForCompute(magneticRef)) {
            var guided = Self.search(reference:reference,points:points,sid:sid,referenceCamera:referenceCamera,startNode:startNode,plate:plate,
                                     prior:(prior.center,prior.halfWidth),seconds:seconds*0.6,cancel:cancel,near:near)
            if guided.last?.candidates.contains(where:\.quality_gate) == true {
                guided[guided.count-1].decision_reasons = (guided[guided.count-1].decision_reasons ?? [])+["compass_yaw_prior_"+prior.scope]
                return guided
            }
            return guided+Self.search(reference:reference,points:points,sid:sid,referenceCamera:referenceCamera,startNode:startNode,plate:plate,
                                      prior:nil,seconds:seconds*0.4,cancel:cancel,near:near)
        }
        return Self.search(reference:reference,points:points,sid:sid,referenceCamera:referenceCamera,startNode:startNode,plate:plate,prior:nil,seconds:seconds,cancel:cancel,near:near)
    }
    /// Map position of the camera under the alignment confirmed earlier in this session, if any.
    private var lastKnownCamera:ProbePoint? {
        guard let t = alignment.mapFromSession,let frame = scene.session.currentFrame else { return nil }
        let c = CampusMapGeometry.multiply(t,matrixRows(frame.camera.transform));return ProbePoint(c[0][3],c[1][3],c[2][3])
    }
    // MARK: Navigation refresh (prompt-only)
    private func refreshTick(_ frame:ARFrame) {
        guard refreshMode != "off",phase == .navigation,!parkedAtTransfer,normal,!closing,plateToken == nil,depthAction == nil,
              let t = alignment.mapFromSession else { if refreshActive { endRefresh("interrupted") };return }
        let c = CampusMapGeometry.multiply(t,matrixRows(frame.camera.transform)),position = ProbePoint(c[0][3],c[1][3],c[2][3])
        if refreshActive {
            // Collect new views with depth (and check the route ahead in each), then solve.
            if quickCorrectionOn && !quickTried && refreshFrames >= 3 && !refreshBusy { startQuickCorrection(position:position) }
            if frame.timestamp-refreshStarted > 4.5 || refreshFrames >= 8 { if !refreshBusy && !quickBusy { solveRefresh(frame,position:position) };return }
            if let depth = frame.sceneDepth,let confidence = depth.confidenceMap,!refreshBusy,newView(frame,since:refreshPose) {
                if let blocked = routeAheadBlocked(frame,mapFromSession:t,from:position) { refreshCheckedFrames += 1;if blocked { refreshBlockedFrames += 1 } }
                collectRefresh(frame,depth:depth.depthMap,confidence:confidence)
            }
            return
        }
        // Held up: lens within 45° of horizontal and device upright; not while a correction is moving or pending.
        let f = -frame.camera.transform.columns.2,up = -frame.camera.transform.columns.0
        guard abs(f.y) < 0.71,up.y > 0.4,refreshSuggestion == nil,alignmentTransition == nil else { return }
        let walked = lastRefreshPosition.map { hypot(position.x-$0.x,position.z-$0.z) } ?? 0
        if lastRefreshPosition == nil { lastRefreshPosition = position;lastRefreshAt = frame.timestamp;return }
        guard walked >= 5 || frame.timestamp-lastRefreshAt >= 15 else { return }
        refreshActive = true;refreshStarted = frame.timestamp;refreshFrames = 0;refreshCloud = [:];refreshSamples = [];refreshPose = nil
        refreshBlockedFrames = 0;refreshCheckedFrames = 0;quickTried = false;quickApplied = nil
        lastRefreshAt = frame.timestamp;lastRefreshPosition = position
        synchronizeDepth(reason:"navigation_refresh");log("refresh_started",["walked_m":walked])
    }
    private func newView(_ frame:ARFrame,since last:simd_float4x4?) -> Bool {
        guard let last else { return true }
        let a = SIMD3(last.columns.3.x,last.columns.3.y,last.columns.3.z),b = SIMD3(frame.camera.transform.columns.3.x,frame.camera.transform.columns.3.y,frame.camera.transform.columns.3.z)
        let fa = -SIMD3(last.columns.2.x,last.columns.2.y,last.columns.2.z),fb = -SIMD3(frame.camera.transform.columns.2.x,frame.camera.transform.columns.2.y,frame.camera.transform.columns.2.z)
        return simd_distance(a,b) >= 0.15 || acos(max(-1,min(1,simd_dot(simd_normalize(fa),simd_normalize(fb)))))*180/Float.pi >= 8
    }
    /// Body-height volume (0.5/1.0/1.5 m above the local floor) along the next 0.5–3 m of the route:
    /// blocked when live depth shows a surface clearly in front of it. Unseen samples are unknown.
    /// Returns nil when nothing could be compared in this frame. Wording stays "something ahead".
    private func routeAheadBlocked(_ frame:ARFrame,mapFromSession:[[Double]],from position:ProbePoint) -> Bool? {
        let route = spacePlanned
        guard route.count >= 2,let depth = frame.sceneDepth,let conf = depth.confidenceMap else { return nil }
        // Samples every 0.5 m from the closest route point.
        var bestI = 0,bestD = Double.infinity
        for (i,p) in route.enumerated() { let d = hypot(p.x-position.x,p.z-position.z);if d < bestD { bestD = d;bestI = i } }
        var samples = [ProbePoint](),walked = 0.0,i = bestI
        var prev = route[bestI]
        while i+1 < route.count && walked < 3 {
            let next = route[i+1],seg = hypot(next.x-prev.x,next.z-prev.z)
            if seg < 1e-6 { i += 1;prev = next;continue }
            let step = min(0.5,seg),dx = (next.x-prev.x)/seg*step,dz = (next.z-prev.z)/seg*step
            prev = ProbePoint(prev.x+dx,prev.y,prev.z+dz);walked += step
            if hypot(prev.x-next.x,prev.z-next.z) < 1e-3 { i += 1 }
            if walked >= 0.5 { samples.append(prev) }
        }
        let sessionFromMap = matrixFromRows(CampusMapGeometry.inverse(mapFromSession)),inverse = simd_inverse(frame.camera.transform)
        CVPixelBufferLockBaseAddress(depth.depthMap,.readOnly);CVPixelBufferLockBaseAddress(conf,.readOnly)
        defer { CVPixelBufferUnlockBaseAddress(conf,.readOnly);CVPixelBufferUnlockBaseAddress(depth.depthMap,.readOnly) }
        guard let db = CVPixelBufferGetBaseAddress(depth.depthMap),let cb = CVPixelBufferGetBaseAddress(conf) else { return nil }
        let w = CVPixelBufferGetWidth(depth.depthMap),h = CVPixelBufferGetHeight(depth.depthMap),k = frame.camera.intrinsics,res = frame.camera.imageResolution
        var blocked = 0,clear = 0
        for p in samples {
            let floorY = spaceGrid?.floorField?.floor(p.x,p.z) ?? spaceGrid?.floorY ?? p.y
            for lift in [0.5,1.0,1.5] {
                let cam = inverse*(sessionFromMap*SIMD4(Float(p.x),Float(floorY+lift),Float(p.z),1))
                guard cam.z < -0.3 else { continue }
                let d = -Double(cam.z)
                let u = (Double(k[0][0])*Double(cam.x)/d+Double(k[2][0]))*Double(w)/Double(res.width),v = (Double(k[2][1])-Double(k[1][1])*Double(cam.y)/d)*Double(h)/Double(res.height)
                guard u >= 0,v >= 0,u < Double(w),v < Double(h) else { continue }
                let measured = Double(db.advanced(by:Int(v)*CVPixelBufferGetBytesPerRow(depth.depthMap)).assumingMemoryBound(to:Float.self)[Int(u)])
                let c = cb.advanced(by:Int(v)*CVPixelBufferGetBytesPerRow(conf)).assumingMemoryBound(to:UInt8.self)[Int(u)]
                guard c >= 1,measured.isFinite,measured > 0.2,measured < 5 else { continue }
                if measured < d-0.3 { blocked += 1 } else { clear += 1 }
            }
        }
        guard blocked+clear >= 3 else { return nil }
        return blocked >= 3 && Double(blocked) >= 0.5*Double(blocked+clear)
    }
    private func collectRefresh(_ frame:ARFrame,depth:CVPixelBuffer,confidence:CVPixelBuffer) {
        refreshBusy = true;refreshPose = frame.camera.transform
        let calibration = LiDARCalibration(width:CVPixelBufferGetWidth(depth),height:CVPixelBufferGetHeight(depth),imageWidth:CVPixelBufferGetWidth(frame.capturedImage),imageHeight:CVPixelBufferGetHeight(frame.capturedImage),fx:Double(frame.camera.intrinsics[0][0]),fy:Double(frame.camera.intrinsics[1][1]),cx:Double(frame.camera.intrinsics[2][0]),cy:Double(frame.camera.intrinsics[2][1]))
        let metadata = LiDARFrame(index:0,timestamp:frame.timestamp,transform:matrixRows(frame.camera.transform),calibration:calibration,validFraction:0),token = generation
        io.async { [weak self] in
            let points = (try? LiDARGeometry.observations(depth:Self.pack(depth,format:kCVPixelFormatType_DepthFloat32,bytesPerPixel:4),
                confidence:Self.pack(confidence,format:kCVPixelFormatType_OneComponent8,bytesPerPixel:1),frame:metadata,pixelStride:4).map(\.point)) ?? []
            DispatchQueue.main.async {
                guard let self else { return };self.refreshBusy = false
                guard self.refreshActive,self.generation == token else { return }
                for p in points { self.refreshCloud[LiDARVoxelKey(p,size:0.10)] = p };self.refreshFrames += 1
            }
        }
    }
    private func solveRefresh(_ frame:ARFrame,position:ProbePoint) {
        guard let current = alignment.mapFromSession,refreshCloud.count >= 300 else { endRefresh("too_little_depth");return }
        // A quick correction is provisional: the full result is judged against the alignment before it.
        let base = quickApplied?.before ?? current
        refreshBusy = true
        let points = Array(refreshCloud.values),reference = referencePoints,sid = sessionID,token = generation,cancel = cancellation
        let c = frame.camera.transform.columns.3,camera = ProbePoint(Double(c.x),Double(c.y),Double(c.z))
        let samples = refreshSamples,magneticRef = magneticReference
        // Persistently blocked ahead (at least 2 frames): that only triggers this search; it never lowers the bar.
        let blocked = refreshBlockedFrames >= 2,microBudget = microSoFar
        compute.async { [weak self] in
            guard let self else { return }
            let prior = LiDARMagnetic.yawPrior(query:samples,reference:magneticRef,near:position,structure:self.structureGridForCompute(magneticRef))
            let result = LiDARLocalizer.solveWindowed(map:reference,query:points,sessionID:sid,referenceCamera:camera,center:position,radii:blocked ? [3,5,10] : [3,5],
                                                      maxSeconds:blocked ? 6 : 3,cancellation:cancel,yawPrior:prior.map { ($0.center,$0.halfWidth) }).tiers.last!
            let compass = result.candidates.first.map { LiDARMagnetic.check(samples,transform:$0.transform_query_to_map,reference:magneticRef,structure:self.structureGrid) }
            DispatchQueue.main.async {
                self.refreshBusy = false
                guard self.refreshActive,self.generation == token,self.phase == .navigation,self.alignment.mapFromSession == current,
                      let live = self.scene.session.currentFrame,let mapID = self.map?.map_id else { self.endRefresh("superseded");return }
                let agreement = result.candidates.first.flatMap { self.agreementPair(live,current:base,candidate:$0.transform_query_to_map) }
                let decision = LiDARRefreshPolicy.decide(result,current:base,camera:camera,compass:compass,agreement:agreement,blocked:blocked,microSoFar:microBudget)
                self.log("refresh_decision",Self.jsonFields(decision).merging(["status":result.status,"frames":self.refreshFrames,"points":points.count,
                    "blocked_frames":self.refreshBlockedFrames,"checked_frames":self.refreshCheckedFrames,"agreement":agreement.map { Self.jsonFields($0) } ?? NSNull(),
                    "compass":compass?.status ?? "none","compass_reason":compass?.reason ?? NSNull(),"compass_samples":samples.count,"yaw_prior":prior != nil,
                    "quick_applied":self.quickApplied != nil]) { a,_ in a })
                let target = result.candidates.first?.transform_query_to_map
                switch decision.action {
                case "micro":if let target { self.applyCorrection(target,source:"auto_micro",decision:decision,undoTo:base) }
                case "keep":
                    // The full search confirms the earlier alignment: take the quick correction back.
                    if let quick = self.quickApplied,(try? self.alignment.accept(base,sessionID:self.sessionID)) != nil {
                        self.alignmentTransition = (quick.after,base,ProcessInfo.processInfo.systemUptime);self.quickChainBase = nil
                        self.spacePlanned = [];self.lastSpacePlan = nil;self.spaceFailure = nil;self.log("quick_correction_reverted")
                    }
                case "large":
                    if let target {
                        if self.largeCorrectionMode == "direct" { self.applyCorrection(target,source:"auto_large",decision:decision,undoTo:base) }
                        else { self.refreshSuggestion = RefreshSuggestion(transform:target,decision:decision,mapID:mapID,session:self.sessionID,arGeneration:self.arSessionGeneration,base:current);self.showRefreshChip() }
                    }
                case "lost":
                    // Prompt only; the current route stays until the person chooses.
                    self.refreshSuggestion = RefreshSuggestion(transform:nil,decision:decision,mapID:mapID,session:self.sessionID,arGeneration:self.arSessionGeneration,base:current);self.showRefreshChip()
                default:break
                }
                self.endRefresh(decision.action)
            }
        }
    }
    /// From the first refresh frames: wall-foot lines → corridor/corner correction within limits, applied at
    /// once (shown over 1.5 s) and judged later by the full result. Needs regular walls on both sides,
    /// must not contradict the compass, and stays within its limits of the last decided alignment.
    private func startQuickCorrection(position:ProbePoint) {
        quickTried = true
        guard let current = alignment.mapFromSession,!mapLines.isEmpty,refreshCloud.count >= 150 else { log("quick_correction",["outcome":"not_enough_data"]);return }
        quickBusy = true
        let points = Array(refreshCloud.values),lines = mapLines,route = spacePlanned,token = generation,chainBase = quickChainBase ?? current
        let floorMap = spaceGrid?.floorField?.floor(position.x,position.z) ?? spaceGrid?.floorY
        let samples = refreshSamples,magneticRef = magneticReference
        compute.async { [weak self] in
            guard let self else { return }
            let live = LiDARStructureLines.extract(points,floorY:floorMap.map { $0-current[1][3] }).map { $0.moved(current) }
            let estimate = LiDARQuickCorrection.estimate(map:lines,live:live,position:position,route:route)
            var outcome = estimate.reason,target = estimate.result.map { CampusMapGeometry.multiply($0.correction,current) }
            // Size relative to the current and to the last decided alignment, at the person's position.
            func moved(_ a:[[Double]],_ b:[[Double]]) -> (m:Double,deg:Double) {
                let local = CampusMapGeometry.point([position.x,position.y,position.z],through:CampusMapGeometry.inverse(current))
                let pa = CampusMapGeometry.point(local,through:a),pb = CampusMapGeometry.point(local,through:b)
                return (hypot(pa[0]-pb[0],pa[2]-pb[2]),abs(remainder(atan2(a[0][2],a[0][0])-atan2(b[0][2],b[0][0]),2*Double.pi))*180/Double.pi)
            }
            if let t = target {
                let step = moved(t,current),total = moved(t,chainBase),limit = estimate.result?.kind == "corner" ? 3.0 : 1.5
                if step.m < 0.10 && step.deg < 1 { target = nil;outcome = "already_aligned" }
                else if total.m > limit || total.deg > 10 { target = nil;outcome = "beyond_limits_since_last_decision" }
                else if samples.count >= 3,LiDARMagnetic.check(samples,transform:t,reference:magneticRef,structure:self.structureGridForCompute(magneticRef)).status == "conflict" {
                    target = nil;outcome = "compass_conflict"
                }
            }
            DispatchQueue.main.async {
                self.quickBusy = false
                var fields:[String:Any] = ["outcome":outcome,"live_lines":live.count]
                if let r = estimate.result { fields.merge(Self.jsonFields(r)) { a,_ in a } }
                guard let target,self.refreshActive,self.generation == token,self.phase == .navigation,self.alignment.mapFromSession == current,
                      (try? self.alignment.accept(target,sessionID:self.sessionID)) != nil else { self.log("quick_correction",fields);return }
                self.alignmentTransition = (current,target,ProcessInfo.processInfo.systemUptime)
                self.quickApplied = (current,target);if self.quickChainBase == nil { self.quickChainBase = current }
                self.spacePlanned = [];self.lastSpacePlan = nil;self.spaceFailure = nil
                fields["applied"] = true;self.log("quick_correction",fields)
                self.status.text = estimate.result?.kind == "corner" ? "已按前方拐角快速校正 · 正在确认" : "已按走廊快速校正 · 正在确认"
            }
        }
    }
    private func endRefresh(_ outcome:String) {
        guard refreshActive else { return }
        refreshActive = false;refreshCloud = [:];refreshSamples = [];quickApplied = nil;synchronizeDepth(reason:"navigation_refresh_ended")
        if outcome == "interrupted" || outcome == "superseded" || outcome == "too_little_depth" { log("refresh_ended",["outcome":outcome]) }
    }
    /// Fit under the current and the candidate alignment, counted only on points comparable under both.
    private func agreementPair(_ frame:ARFrame,current:[[Double]],candidate:[[Double]]) -> LiDARAgreementPair? {
        guard let depth = frame.sceneDepth,let conf = depth.confidenceMap,
              CVPixelBufferGetPixelFormatType(depth.depthMap) == kCVPixelFormatType_DepthFloat32,let mapID = map?.map_id else { return nil }
        if agreementSample?.mapID != mapID { agreementSample = (mapID,LiDARSampling.sample(referencePoints,limit:40_000)) }
        let camera = CampusMapGeometry.multiply(current,matrixRows(frame.camera.transform))
        let near = Array(agreementSample!.points.filter { hypot($0.x-camera[0][3],$0.z-camera[2][3]) < 8 }.prefix(3000))
        CVPixelBufferLockBaseAddress(depth.depthMap,.readOnly);CVPixelBufferLockBaseAddress(conf,.readOnly)
        defer { CVPixelBufferUnlockBaseAddress(conf,.readOnly);CVPixelBufferUnlockBaseAddress(depth.depthMap,.readOnly) }
        guard let db = CVPixelBufferGetBaseAddress(depth.depthMap),let cb = CVPixelBufferGetBaseAddress(conf) else { return nil }
        let w = CVPixelBufferGetWidth(depth.depthMap),h = CVPixelBufferGetHeight(depth.depthMap),k = frame.camera.intrinsics,res = frame.camera.imageResolution
        let inverse = simd_inverse(frame.camera.transform)
        func statuses(_ mapFromSession:[[Double]]) -> [LiDAROverlayCheck.Status] {
            let sessionFromMap = matrixFromRows(CampusMapGeometry.inverse(mapFromSession))
            return near.map { p in
                let cam = inverse*(sessionFromMap*SIMD4(Float(p.x),Float(p.y),Float(p.z),1))
                guard cam.z < -0.2 else { return .unknown }
                let d = -Double(cam.z)
                let u = (Double(k[0][0])*Double(cam.x)/d+Double(k[2][0]))*Double(w)/Double(res.width),v = (Double(k[2][1])-Double(k[1][1])*Double(cam.y)/d)*Double(h)/Double(res.height)
                guard u >= 0,v >= 0,u < Double(w),v < Double(h) else { return .unknown }
                let measured = db.advanced(by:Int(v)*CVPixelBufferGetBytesPerRow(depth.depthMap)).assumingMemoryBound(to:Float.self)[Int(u)]
                let c = cb.advanced(by:Int(v)*CVPixelBufferGetBytesPerRow(conf)).assumingMemoryBound(to:UInt8.self)[Int(u)]
                return LiDAROverlayCheck.classify(expectedDepth:d,measuredDepth:Double(measured),confidence:Int(c))
            }
        }
        let a = statuses(current),b = statuses(candidate)
        func comparable(_ s:LiDAROverlayCheck.Status) -> Bool { s == .aligned || s == .contradicted }
        var common = 0,alignedA = 0,alignedB = 0
        for i in near.indices where comparable(a[i]) && comparable(b[i]) { common += 1;if a[i] == .aligned { alignedA += 1 };if b[i] == .aligned { alignedB += 1 } }
        return LiDARAgreementPair(common:common,comparableBefore:a.filter(comparable).count,comparableAfter:b.filter(comparable).count,alignedBefore:alignedA,alignedAfter:alignedB)
    }
    /// Applies a correction now (the target) and moves everything drawn in AR to it over 1.5 s.
    /// Recorded as automatic and undoable; never labelled as a manual confirmation.
    private func applyCorrection(_ target:[[Double]],source:String,decision:LiDARRefreshDecision,undoTo:[[Double]]? = nil) {
        guard let shown = alignment.mapFromSession else { return }
        let before = undoTo ?? shown
        do { try alignment.accept(target,sessionID:sessionID) } catch { campusError(error);return }
        let now = ProcessInfo.processInfo.systemUptime
        alignmentTransition = (shown,target,now);lastAutoCorrection = (before,target,now,source);quickChainBase = nil
        if source == "auto_micro" { microSoFar += decision.correction_m ?? 0 }
        saveResume(.corrected)
        spacePlanned = [];lastSpacePlan = nil;spaceFailure = nil;progress = 0
        log("refresh_applied",Self.jsonFields(decision).merging(["source":source,"before":before,"after":target,"micro_so_far":microSoFar]) { a,_ in a })
        status.text = String(format:source == "auto_micro" ? "已微调 %.0f 厘米" : "已修正位置 %.1f 米",(decision.correction_m ?? 0)*(source == "auto_micro" ? 100 : 1))
        refreshSuggestion = nil;updatePlateChips(shownChips);showUndoChip()
    }
    private func showUndoChip() {
        guard let last = lastAutoCorrection else { return }
        var config = UIButton.Configuration.bordered();config.cornerStyle = .capsule;config.title = "撤回刚才的自动修正"
        let undo = UIButton(configuration:config,primaryAction:UIAction { [weak self] _ in
            guard let self,let last = self.lastAutoCorrection,self.alignment.mapFromSession == last.after else { return }
            try? self.alignment.accept(last.before,sessionID:self.sessionID)
            self.alignmentTransition = (last.after,last.before,ProcessInfo.processInfo.systemUptime)
            if last.source == "auto_micro" { self.microSoFar = max(0,self.microSoFar-hypot(last.after[0][3]-last.before[0][3],last.after[2][3]-last.before[2][3])) }
            self.spacePlanned = [];self.lastSpacePlan = nil;self.spaceFailure = nil;self.lastAutoCorrection = nil
            self.log("refresh_undone",["source":last.source]);self.updatePlateChips(self.shownChips)
        })
        plateChips.addArrangedSubview(undo)
        let at = last.at
        DispatchQueue.main.asyncAfter(deadline:.now()+8) { [weak self] in
            guard let self,self.lastAutoCorrection?.at == at else { return };self.lastAutoCorrection = nil;self.updatePlateChips(self.shownChips)
        }
    }
    /// Alignment used for drawing: the target, or a yaw/translation interpolation during a transition.
    private func displayedAlignment(_ now:Double) -> [[Double]]? {
        guard let target = alignment.mapFromSession else { return nil }
        guard let t = alignmentTransition else { return target }
        let f = (now-t.start)/1.5
        if f >= 1 || f < 0 { alignmentTransition = nil;return target }
        let ya = atan2(t.from[0][2],t.from[0][0]),yb = atan2(t.to[0][2],t.to[0][0]),yaw = ya+remainder(yb-ya,2*Double.pi)*f
        let c = cos(yaw),s = sin(yaw)
        func lerp(_ r:Int) -> Double { t.from[r][3]+(t.to[r][3]-t.from[r][3])*f }
        return [[c,0,s,lerp(0)],[0,1,0,lerp(1)],[-s,0,c,lerp(2)],[0,0,0,1]]
    }
    private func showRefreshChip() {
        guard let s = refreshSuggestion else { return }
        var config = UIButton.Configuration.filled();config.cornerStyle = .capsule
        let lost = s.decision.action == "lost"
        config.baseBackgroundColor = lost ? .systemRed : .systemOrange
        config.title = lost ? "前方有遮挡，位置可能失准 · 点此重新定位" : String(format:"建议修正 %.1f 米 / %.0f° · 点此采用",s.decision.correction_m ?? 0,s.decision.correction_deg ?? 0)
        config.subtitle = lost ? "当前路线保持不变，可以忽略" : String(format:"贴合度 %.0f%% → %.0f%%（%d 个共同点）",(s.decision.aligned_before ?? 0)*100,(s.decision.aligned_after ?? 0)*100,s.decision.common_points ?? 0)
        let adopt = UIButton(configuration:config,primaryAction:UIAction { [weak self] _ in self?.adoptRefresh() })
        var dismissConfig = UIButton.Configuration.bordered();dismissConfig.title = "忽略";dismissConfig.cornerStyle = .capsule
        let dismiss = UIButton(configuration:dismissConfig,primaryAction:UIAction { [weak self] _ in
            self?.log("refresh_dismissed",["action":s.decision.action]);self?.refreshSuggestion = nil;self?.updatePlateChips(self?.shownChips ?? [])
        })
        plateChips.addArrangedSubview(adopt);plateChips.addArrangedSubview(dismiss)
    }
    /// Drops any pending correction (and the refresh baseline) when what it was computed against changes.
    private func invalidateRefresh(_ reason:String) {
        if refreshActive { endRefresh("superseded") }
        lastRefreshPosition = nil;alignmentTransition = nil;lastAutoCorrection = nil
        if reason == "new_confirmation" || reason == "session_restarted" || reason == "map_switched" { microSoFar = 0;quickChainBase = nil }
        guard refreshSuggestion != nil else { return }
        refreshSuggestion = nil;log("refresh_invalidated",["reason":reason]);updatePlateChips(shownChips)
    }
    private func adoptRefresh() {
        guard let s = refreshSuggestion,phase == .navigation,map?.map_id == s.mapID,sessionID == s.session,arSessionGeneration == s.arGeneration,
              alignment.mapFromSession == s.base else { invalidateRefresh("stale_on_adopt");return }
        refreshSuggestion = nil
        if let target = s.transform { applyCorrection(target,source:"accepted_suggestion",decision:s.decision) }
        else { log("refresh_relocalize_requested");updatePlateChips(shownChips);beginCapture() }   // lost: full relocalization, route kept meanwhile
    }
    private func startEarlyStopTrial(_ frame:ARFrame) {
        trialRunning = true;lastTrialFrames = frames
        let points = Array(cloud.values),reference = referencePoints,sid = sessionID,token = generation,count = frames,cancel = cancellation
        let startNode = startPrior,c = frame.camera.transform.columns.3
        let referenceCamera = ProbePoint(Double(c.x),Double(c.y),Double(c.z))
        let plate = currentPlateSearch,magnetic = querySamples,reference_ = magneticReference,near = lastKnownCamera
        compute.async { [self] in
            let started = ProcessInfo.processInfo.systemUptime
            let trial = searchWithCompass(reference:reference,points:points,sid:sid,referenceCamera:referenceCamera,startNode:startNode,plate:plate,
                                          magnetic:magnetic,magneticRef:reference_,seconds:3,cancel:cancel,near:near).last!
            let seconds = ProcessInfo.processInfo.systemUptime-started
            let screen = magneticScreenFor(trial,query:magnetic,reference:reference_)
            // A unique answer that contradicts the compass, or jumps far from where this session was
            // confirmed, is implausible: keep collecting instead of stopping on it.
            var implausible:String?
            if trial.status == "candidate_requires_review",let best = trial.candidates.first {
                if screen.checks.first?.status == "conflict" { implausible = "compass_conflict" }
                let cam = CampusMapGeometry.point([referenceCamera.x,referenceCamera.y,referenceCamera.z],through:best.transform_query_to_map)
                if let near,hypot(cam[0]-near.x,cam[2]-near.z) > 15 { implausible = "far_from_last_confirmed" }
            }
            // A compass-only stop needs a flip-type ambiguity and exactly one passing candidate left.
            let gatedLeft = trial.candidates.indices.filter { trial.candidates[$0].quality_gate && !screen.suppressed.contains($0) }.count
            let compassStop = trial.status == "ambiguous" && screen.applied && gatedLeft == 1 && Set(trial.decision_reasons ?? []).isSubset(of:["multiple_modes","opposite_yaw_mode"])
            DispatchQueue.main.async { [self] in
                trialRunning = false
                guard token == generation,sid == sessionID,phase == .collecting,!isMapping,!closing else { return }
                log("early_stop_trial",["frames":count,"status":trial.status,"decision_reasons":trial.decision_reasons ?? [],"seconds":seconds,"implausible":implausible ?? NSNull()])
                lastTrialStatus = implausible == nil ? trial.status : "implausible"
                if implausible != nil { status.text = "结果可疑（与指南针或上次位置不符）· 继续采集，请转向其他方向" }
                else if trial.status == "candidate_requires_review" || compassStop {
                    earlyStopRequested = true
                    status.text = autoEarlyStop ? (compassStop ? "指南针排除反向候选 · 结束采集并复核" : "已找到唯一候选 · 结束采集并复核")
                                                : "已找到唯一候选 · 可点“结束采集并定位”，或继续采满 \(queryFrameTarget) 帧"
                    if compassStop { log("early_stop_by_compass",["frames":count,"suppressed":screen.suppressed]) }
                }
            }
        }
    }
    private func finishQuery() {
        guard !isMapping,phase == .collecting,!working,let writer else { return }
        guard frames >= 3 else { status.text = "有效帧不足，请继续观察固定结构";return }
        phase = .solving;status.text = "手机正在匹配几何地图…";detail.text = "计算期间可继续举机观察。不会重置当前 AR 会话。";refresh()
        let startNode = startPrior
        let cameraColumn = scene.session.currentFrame?.camera.transform.columns.3
        let referenceCamera = cameraColumn.map { ProbePoint(Double($0.x),Double($0.y),Double($0.z)) }
        let plate = currentPlateSearch,magnetic = querySamples,magneticRef = magneticReference,near = lastKnownCamera
        if (startNode != nil || plate != nil) && referenceCamera == nil { phase = .idle;status.text = "缺少查询相机位置，请重新扫描";refresh();return }
        let sourcePoints = Array(cloud.values),reference = referencePoints,token = generation,sid = sessionID,cancel = cancellation
        let mapID = map?.map_id,mapHash = geometrySHA256,arGeneration = arSessionGeneration,attempt = attemptID
        let snapshot = UUID().uuidString,appVersion = Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "unknown"
        let device = ProbeIO.hardwareIdentifier(),snapshotFrames = writer.manifest.frames.map(\.index)
        let preparationStarted = ProcessInfo.processInfo.systemUptime
        log("localization_started",["snapshot_id":snapshot,"used_frame_ids":snapshotFrames])
        io.async { [self] in
            let outcome = Result { () -> (Data,[ProbePoint],String) in
                _ = try writer.finish(reason:"on_device_query",valid:true)
                // Quantize once; the persisted snapshot is the exact solver input.
                let bytes = try LiDARPointFile.encode(sourcePoints)
                try bytes.write(to:writer.directory.appendingPathComponent("solver-query.f32"),options:.atomic)
                let points = try LiDARPointFile.decode(bytes,count:sourcePoints.count)
                return (bytes,points,try CampusFiles.hash(writer.directory.appendingPathComponent("scan.json")))
            }
            switch outcome {
            case .failure(let error):DispatchQueue.main.async { [weak self] in
                guard let self,token == self.generation else { return };self.phase = .idle;self.status.text = "查询保存失败";self.refresh();self.campusError(error)
            }
            case .success(let (bytes,points,manifestHash)):
                let preparationSeconds = ProcessInfo.processInfo.systemUptime-preparationStarted
                compute.async { [self] in
                    let solveStarted = ProcessInfo.processInfo.systemUptime
                    var tiers = searchWithCompass(reference:reference,points:points,sid:sid,referenceCamera:referenceCamera,startNode:startNode,plate:plate,
                                                  magnetic:magnetic,magneticRef:magneticRef,seconds:20,cancel:cancel,near:near)
                    if let last = tiers.last,last.decision_reasons?.contains(where:{ $0.hasPrefix("compass_yaw_prior") }) == true {
                        tiers[tiers.count-1].reason = (last.status == "candidate_requires_review" ? "按指南针方向匹配到唯一候选" : "按指南针方向匹配，仍有多个候选")+"，需现场核对"
                    }
                    let solveSeconds = ProcessInfo.processInfo.systemUptime-solveStarted
                    let provenance = LiDARResultProvenance(map_id:mapID,geometry_sha256:mapHash,
                        query_scan_id:writer.manifest.scan_id,session_id:sid,generation:arGeneration,attempt_id:attempt,
                        used_frame_ids:snapshotFrames,app_version:appVersion,device:device,recomputable:mapHash != nil,
                        query_input_file:"solver-query.f32",query_input_sha256:Self.digest(bytes),query_manifest_sha256:manifestHash,
                        preprocessing_id:"depth_stride4_conf1_range0.2_4.5_voxel0.10_latest_f32_v1",snapshot_id:snapshot)
                    for i in tiers.indices { tiers[i].provenance = provenance }
                    var solved = tiers.last!
                    var stages = solved.stage_seconds ?? [:];stages["app_prepare"] = preparationSeconds;stages["app_all_tiers"] = solveSeconds;solved.stage_seconds = stages
                    tiers[tiers.count-1] = solved
                    let screen = magneticScreenFor(solved,query:magnetic,reference:magneticRef)
                    let publication = Result { () -> Data in
                        let encoder = JSONEncoder();encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
                        // Keep the existing top-level result readable by old tools, and preserve every scope tried.
                        var object = try JSONSerialization.jsonObject(with:encoder.encode(solved)) as! [String:Any]
                        object["search_tiers"] = try JSONSerialization.jsonObject(with:encoder.encode(tiers))
                        object["magnetic_screen"] = try JSONSerialization.jsonObject(with:encoder.encode(screen))
                        let data = try JSONSerialization.data(withJSONObject:object,options:[.prettyPrinted,.sortedKeys])
                        try data.write(to:writer.directory.appendingPathComponent("on-device-result.json"),options:.atomic)
                        try ProbeIO.makeManifest(at:writer.directory)
                        return data
                    }
                    DispatchQueue.main.async { [self] in
                        guard token == generation,sid == sessionID,!closing,phase == .solving else { return }
                        switch publication {
                        case .failure(let error):diagnosticError = error.localizedDescription
                        case .success(let data):recorder?.writeResult(data,filename:"localization-\(writer.manifest.scan_id).json")
                        }
                        result = solved;candidateIndex = 0;magneticScreen = screen;plateSearch = nil
                        log("magnetic_screen",Self.jsonFields(screen))
                        if screen.applied {
                            // Start review at the first passing candidate the compass does not argue against.
                            let gated = solved.candidates.indices.filter { solved.candidates[$0].quality_gate }
                            if let first = gated.firstIndex(where:{ !screen.suppressed.contains($0) }) { candidateIndex = first }
                        }
                        log("localization_finished",["status":solved.status,"compute_seconds":solveSeconds,"search_tiers":tiers.count,
                            "total_seconds":ProcessInfo.processInfo.systemUptime-(requestStarted ?? ProcessInfo.processInfo.systemUptime),
                            "candidates":solved.candidates.count,"query_scan_id":writer.manifest.scan_id,"snapshot_id":snapshot])
                        if solved.status == "candidate_requires_review" || solved.status == "ambiguous" {
                            phase = .review;spacePlanned = [];lastSpacePlan = nil;spaceFailure = nil;log("candidate_selected");showCandidate()
                        } else { phase = .idle;status.text = solved.reason;root?.isEnabled = false;refresh() }
                    }
                }
            }
        }
    }
    private static func digest(_ data:Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
    private func clearConfirmedReference(_ reason:String) {
        invalidateRefresh(reason)
        if confirmedAlignment != nil { log("confirmed_reference_invalidated",["reason":reason]) }
        confirmedAlignment = nil;consistencyReport = nil
    }
    private func updateConsistency() {
        guard let map,let candidate else { consistencyReport = nil;return }
        let report = LiDARSessionConsistency.compare(reference:confirmedAlignment,transform:candidate.transform_query_to_map,
            mapID:map.map_id,geometrySHA256:geometrySHA256,sessionID:sessionID,generation:arSessionGeneration,
            cameraInSession:scene.session.currentFrame.map { matrixRows($0.camera.transform) })
        consistencyReport = report
        if let data = try? JSONEncoder().encode(report),let object = try? JSONSerialization.jsonObject(with:data) as? [String:Any] {
            log("same_session_consistency",object)
        }
    }
    private var selectedCandidateResultIndex:Int? {
        guard let result else { return nil }
        let indices = result.candidates.indices.filter { result.candidates[$0].quality_gate }
        return indices.indices.contains(candidateIndex) ? indices[candidateIndex] : nil
    }
    private var candidate:LiDARLocalizationCandidate? {
        let candidates = result?.candidates.filter(\.quality_gate) ?? []
        return candidates.indices.contains(candidateIndex) ? candidates[candidateIndex] : nil
    }
    private func showCandidate() {
        guard let candidate else { return }
        let count = result?.candidates.filter(\.quality_gate).count ?? 0
        status.text = "\(result?.status == "ambiguous" ? "存在多解" : "待现场核对") · 候选 \(candidateIndex+1)/\(count)"+((magneticScreen?.applied ?? false) ? " · 指南针排除 \(magneticScreen!.suppressed.count) 个" : "")
        updateConsistency()
        let scopeText = result?.search_scope.map { $0.kind == "plate_entrance_windows" ? "按门牌在 \($0.tiers_tried) 处入口附近搜索\n" : "在起点\(Int($0.candidate_radius_m))米范围内 · 已尝试\($0.tiers_tried)档\n" } ?? "全图搜索 · 需现场核对\n"
        var compassText = ""
        if let screen = magneticScreen,let ri = selectedCandidateResultIndex,screen.checks.indices.contains(ri) {
            let c = screen.checks[ri],d = c.delta_deg.map { String(format:"%.0f°",abs($0)) } ?? ""
            let scope = c.reference_scope == "global" ? "（全图参照）" : ""
            let why:String
            switch c.reason ?? "" {
            case "no_map_reference":why = "地图没有磁场参照"
            case "no_reference_near_candidate":why = "候选附近没有磁场参照，全图参照也不一致"
            case "phone_not_upright":why = "手机过低或过平，请竖持手机平视"
            case "too_few_query_samples":why = "指南针读数太少，请多停留一会"
            case "query_spread":why = "这次读数分散，可能附近有干扰"
            default:why = "无可用参照"
            }
            compassText = c.status == "consistent" ? "\n指南针：方向一致（相差\(d)）\(scope)" : c.status == "conflict" ? "\n指南针：方向与地图相差\(d)\(scope)，此候选很可能不对" : c.status == "uncertain" ? "\n指南针：方向相差\(d)\(scope)，无法判断" : "\n指南针不可用：\(why)"
            if result?.decision_reasons?.contains(where:{ $0.hasPrefix("compass_yaw_prior") }) == true { compassText += "\n本结果按指南针方向重新匹配" }
        }
        detail.text = scopeText+String(format:"几何重叠 %.1f%% · 表面残差 %.1fcm\n这些不是定位正确概率。核对路线是否位于真实走廊。",candidate.overlap*100,candidate.rmse_m*100)+"\n"+(result?.reason ?? "")+compassText+(lineCheckText.map { "\n"+$0 } ?? "")
        refresh()
        if let frame = scene.session.currentFrame { renderNavigation(frame);lastOverlayUpdate = -.infinity;updatePointOverlay(frame) };refresh()
    }
    /// Session point → map point while supplementing; identity otherwise.
    private func toMap(_ p:ProbePoint) -> ProbePoint {
        guard let t = supplementTransform else { return p }
        let q = CampusMapGeometry.point([p.x,p.y,p.z],through:t);return ProbePoint(q[0],q[1],q[2])
    }
    private func toMapPose(_ m:[[Double]]) -> [[Double]] { supplementTransform.map { CampusMapGeometry.multiply($0,m) } ?? m }
    func setCrossMap(targets:[LiDARNodeRef],directories:[String:URL],maps:[String:LiDARNavigationMap],links:[LiDARMapLink]) {
        crossMap = CrossMap(targets:targets,directories:directories,maps:maps,links:links,plan:nil);crossDistances = nil
    }
    private func label(_ mapID:String) -> String {
        guard let url = crossMap?.directories[mapID],let m = crossMap?.maps[mapID] else { return "下一张地图" }
        return LiDARGeometryLibraryController.label(url,m,catalog:try? LiDARCampusCatalog.load(root:LiDARLibrary.root))
    }
    /// Plans from the confirmed camera position on the current map; the current leg's target becomes the route end.
    /// In-map lengths are space routes on each map's grid (loaded lazily on `compute` and kept for this
    /// navigation); a map or entrance without a walkable connection is no edge and is named in the message.
    private func planCrossMap() {
        guard let cross = crossMap,let map,let t = alignment.mapFromSession,let frame = scene.session.currentFrame else { return }
        let camera = CampusMapGeometry.multiply(t,matrixRows(frame.camera.transform)),start = ProbePoint(camera[0][3],camera[1][3],camera[2][3])
        var maps = cross.maps;maps[map.map_id] = map
        let current = (id:map.map_id,grid:spaceGrid),directories = cross.directories,token = generation
        if crossDistances == nil || crossDistancesMap != map.map_id {
            crossDistancesMap = map.map_id
            crossDistances = LiDARSpaceDistances { id in
                if id == current.id { return current.grid }
                guard let url = directories[id],let (m,points) = try? LiDARNavigationStore.load(url) else { return nil }
                return LiDARNavigationStore.spaceInputs(url,map:m,points:points).grid
            }
        }
        guard let distances = crossDistances else { return }
        status.text = "正在规划跨图路线…"
        compute.async { [weak self] in
            let result = Result { try LiDARMultiMapPlanner.plan(maps:maps,links:cross.links,startMap:current.id,start:start,destinations:cross.targets,distances:distances) }
            let failures = distances.failures
            DispatchQueue.main.async {
                guard let self,self.generation == token,var cross = self.crossMap else { return }
                switch result {
                case .success(let plan):
                    cross.maps = maps;cross.plan = plan;self.crossMap = cross;self.destinations = [plan.legs[0].target_node_id];self.planRevision += 1
                    self.spacePlanned = [];self.lastSpacePlan = nil;self.spaceFailure = nil;self.transitionReady = false
                    self.log("cross_map_planned",["legs":plan.legs.map { ["map_id":$0.map_id,"target":$0.target_node_id,"link":$0.link?.kind.rawValue ?? "none","length_m":$0.length_m] },"total_m":plan.total_m,"length_source":"space"])
                    if let frame = self.scene.session.currentFrame { self.renderNavigation(frame) }
                case .failure(let error):
                    let detail = failures.isEmpty ? error.localizedDescription : Array(Set(failures)).sorted().prefix(6).joined(separator:"\n")
                    self.log("cross_map_unreachable",["error":error.localizedDescription,"failures":failures])
                    self.campusMessage("无法规划跨图路线",detail)
                }
            }
        }
    }
    private var currentLeg:LiDARMultiMapRoute.Leg? { crossMap?.plan?.legs.first }
    /// Arrived at a room: within 2 m along the route and 2 m off it (doors are wide, drift is real).
    private static let arrivalM = 2.0,arrivalOffM = 2.0
    /// Arrived precisely: show "已到达" briefly, then close. Within a campus trip the coordinator shows
    /// the summary; on its own the indoor screen shows it before closing.
    private func arriveAndSummarise() {
        guard usesShell else { return }
        DispatchQueue.main.asyncAfter(deadline:.now()+1.5) { [weak self] in
            guard let self,!self.closing,self.completed else { return }
            if self.onFinished != nil { self.finishAndClose();return }
            let s = TripSummaryController(.init(destination:self.destinationName,started:self.tripStarted,indoorM:self.walkedM,floorChanges:self.floorChanges))
            s.onDone = { [weak self] in self?.finishAndClose() }
            self.present(s,animated:true)
        }
    }
    /// An explicit lobby/stairs confirmation is offered in a 15 m neighbourhood of the current
    /// leg's transfer node. It parks this floor; only the subsequent floor confirmation switches maps.
    private var nearbyTransferTitle:String? {
        guard phase == .navigation,!closing,!parkedAtTransfer,let leg = currentLeg,let link = leg.link,
              link.kind == .elevator || link.kind == .stairs,
              let plan = crossMap?.plan,plan.legs.count >= 2,
              let target = map?.nodes.first(where: { $0.id == leg.target_node_id }),let position = lastWalkPosition,
              NavigationArrivalPolicy.offersTransferConfirmation(distanceM:hypot(position.x-target.position.x,position.z-target.position.z)) else { return nil }
        return link.kind == .elevator ? "我已到达电梯厅" : "我已到达楼梯口"
    }
    private func confirmTransferArrival() {
        guard nearbyTransferTitle != nil,let plan = crossMap?.plan,let leg = currentLeg,let link = leg.link else { return }
        transitionReady = true;parkSuppressed = false
        let nextLabel = label(plan.legs[1].map_id)
        status.text = link.kind == .elevator ? "已确认到达电梯厅" : "已确认到达楼梯口"
        detail.text = link.kind == .elevator ? "乘电梯到\(nextLabel)，出电梯后点击“我已到达”。" : "走楼梯到\(nextLabel)，到达后点击“我已到达”。"
        log("cross_map_transition_reached",["node_id":leg.target_node_id,"link_kind":link.kind.rawValue,"confirmation":"manual","offer_radius_m":NavigationArrivalPolicy.manualTransferRadiusM])
        parkAtTransfer(plan)
    }
    /// Reached the elevator lobby or stairs: stop the camera (nothing to track in a lift or stairwell)
    /// and move "上次位置" to the arrival point on the next floor, so reopening resumes there.
    private func parkAtTransfer(_ plan:LiDARMultiMapRoute) {
        guard !parkedAtTransfer,plan.legs.count >= 2,let cross = crossMap,let from = map?.map_id else { return }
        parkedAtTransfer = true;generation += 1;spacePlanning = false
        invalidateRefresh("transfer_parked")
        let next = plan.legs[1]
        if let url = cross.directories[next.map_id],let node = cross.maps[next.map_id]?.nodes.first(where: { $0.id == next.entry_node_id }) {
            io.async {
                guard let hash = try? CampusFiles.hash(url.appendingPathComponent("geometry.f32")) else { return }
                var r = LiDARIndoorResume.load(root:LiDARLibrary.root)
                r.transfer(from:from,to:.init(mapID:next.map_id,geometrySHA256:hash,position:node.position,reason:.transfer))
                try? r.save(root:LiDARLibrary.root)
            }
        }
        depthGate.cancel();depthAction = nil;depthRequestID = nil;depthTimeout?.cancel()
        scene.session.pause();chain?.hide();root?.isEnabled = false
        log("cross_map_parked",["from_map":from,"to_map":next.map_id,"entry_node_id":next.entry_node_id])
        refresh()
    }
    /// Parked at the elevator or stairs but staying on this floor: camera back on, localise again
    /// near the lobby, and put "上次位置" back on this floor.
    private func relocateOnThisFloor() {
        guard parkedAtTransfer,let map else { return }
        parkedAtTransfer = false;parkSuppressed = true;transitionReady = false
        if let next = crossMap?.plan?.legs.dropFirst().first?.map_id {
            io.async { var r = LiDARIndoorResume.load(root:LiDARLibrary.root);r.remove(mapID:next);try? r.save(root:LiDARLibrary.root) }
        }
        startNodeID = currentLeg?.target_node_id ?? startNodeID;resumePrior = nil
        clearConfirmedReference("relocalize_same_floor");root?.removeFromParent();root = nil;spacePlanned = [];lastSpacePlan = nil;spaceFailure = nil
        sessionID = UUID().uuidString;arSessionGeneration += 1;generation += 1;alignment.reset(sessionID:sessionID)
        previousTime = nil;previousPosition = nil;unhealthySince = nil
        phase = .idle;runSession()
        log("cross_map_unparked",["map_id":map.map_id])
        status.text = "在\(label(map.map_id))重新定位";detail.text = "对准附近的墙和地面，点击开始定位。"
        refresh()
    }
    private func switchToNextLeg() {
        floorChanges += 1;lastWalkPosition = nil;parkedAtTransfer = false
        guard let cross = crossMap,let plan = cross.plan,plan.legs.count >= 2,let link = plan.legs[0].link,let url = cross.directories[plan.legs[1].map_id] else { return }
        let next = plan.legs[1],kind = link.kind
        generation += 1;let token = generation,sid = sessionID,fromMap = map?.map_id
        phase = .solving;status.text = "正在载入\(label(next.map_id))…";refresh()
        LiDARNavigationStore.queue.async { [weak self] in
            let result = Result { () -> (LiDARNavigationMap,[ProbePoint],LiDARLandmarkSet?,LiDARMagnetic.Reference?,LiDARSpaceGrid?) in
                let (map,points) = try LiDARNavigationStore.load(url)
                return (map,points,try LiDARLandmarkSet.load(url,map:map,geometrySHA256:try CampusFiles.hash(url.appendingPathComponent("geometry.f32"))),
                        LiDARNavigationStore.magneticReference(url,map:map),LiDARNavigationStore.spaceInputs(url,map:map,points:points).grid)
            }
            DispatchQueue.main.async {
                // Cancelled, backgrounded, interrupted or already switched while loading: do nothing.
                guard let self,!self.closing,self.phase == .solving,self.generation == token,self.sessionID == sid,self.map?.map_id == fromMap else { return }
                switch result {
                case .failure(let error):self.phase = .navigation;self.refresh();self.campusError(error)
                case .success(let (map,points,landmarks,magnetic,grid)):
                    self.spaceGrid = grid
                    self.log("cross_map_switched",["from_map":self.map?.map_id ?? "","to_map":map.map_id,"link_kind":kind.rawValue,"link_id":link.id,"group_id":link.group_id ?? ""])
                    self.map = map;self.referencePoints = points;self.knownPlates = landmarks?.landmarks ?? [];self.magneticReference = magnetic
                    if let bytes = try? LiDARPointFile.encode(points) { self.geometrySHA256 = Self.digest(bytes) }
                    self.mapLines = [];self.liveLines = [];self.lineComparison = nil
                    self.compute.async { [weak self] in
                        self?.structureGrid = nil
                        let lines = LiDARStructureLines.extract(points)
                        DispatchQueue.main.async { self?.mapLines = lines }
                    }
                    self.startNodeID = next.entry_node_id;self.resumePrior = nil;self.destinations = [next.target_node_id];self.transitionReady = false
                    var c = cross;c.plan = nil;self.crossMap = c
                    // A new map has its own coordinates; stairs and elevators also tend to break tracking. Start fresh.
                    self.clearConfirmedReference("map_switched");self.root?.removeFromParent();self.root = nil;self.spacePlanned = [];self.lastSpacePlan = nil;self.spaceFailure = nil
                    self.sessionID = UUID().uuidString;self.arSessionGeneration += 1;self.generation += 1;self.alignment.reset(sessionID:self.sessionID)
                    self.previousTime = nil;self.previousPosition = nil;self.unhealthySince = nil
                    self.phase = .idle;self.runSession()
                    let entry = map.nodes.first { $0.id == next.entry_node_id }?.name ?? "连接点"
                    self.status.text = "已切换到\(self.label(map.map_id))";self.detail.text = "请在「\(entry)」附近观察周围结构，点击开始定位。"
                    self.refresh()
                }
            }
        }
    }
    private func enterSupplement() {
        guard supplementDirectory != nil,!isMapping,let map,let transform = alignment.mapFromSession,phase == .navigation else { return }
        isMapping = true;supplementTransform = transform
        supplementConfirmation = (arSessionGeneration,result?.provenance?.attempt_id ?? attemptID,selectedCandidateResultIndex)
        root?.removeFromParent();root = nil;reticle.isHidden = false
        navigationItem.rightBarButtonItems?.last?.title = "标记门牌"
        var editor = LiDARRouteEditor(nodes:map.nodes,edges:map.edges);editor.spaceMode = true
        if let frame = scene.session.currentFrame {
            let camera = toMapPose(matrixRows(frame.camera.transform))
            if let near = map.nodes.min(by:{ hypot($0.position.x-camera[0][3],$0.position.z-camera[2][3]) < hypot($1.position.x-camera[0][3],$1.position.z-camera[2][3]) }) {
                try? editor.setConnectFrom(near.id)
            }
        }
        editor.markSaved();routeEditor = editor;renderPaths()
        plateRecords = knownPlates
        cloud = [:];for point in referencePoints { cloud[LiDARVoxelKey(point,size:0.10)] = point };supplementNew = [:]
        phase = .idle;status.text = "正在载入原图…";refresh()
        let base = referencePoints
        io.async { [self] in
            let budget = LiDARBlockBudget(settings:.init(globalCap:LiDARScanLimits.mapVoxelsV3))
            let outcome = Result { try budget.seed(base) }
            mappingBudget = budget;keyframePolicy = LiDARKeyframePolicy();revisitGate = LiDARRevisitGate()
            acceptedFrameIDs = [];diagnosticFrameIDs = [];frameForBatch = [:];ioLastRevisitPose = nil
            let snapshot = budget.snapshot()
            DispatchQueue.main.async { [self] in
                budgetSnapshot = snapshot;syncRouteEditor();synchronizeDepth(reason:"supplement_started")
                if case .failure(let error) = outcome { campusError(error) }
                status.text = "补采 · 已对齐原图";detail.text = "紫色是原图点。点击开始扫描后，新几何会先与原图核对再并入；节点默认接到最近的原有节点。"
                log("supplement_started",["map_from_session":transform,"seed_points":base.count]);refresh()
            }
        }
    }
    private func confirm() {
        guard phase == .review,normal,let result,result.session_id == sessionID,let candidate else { return }
        do {
            let before = alignment.mapFromSession
            updateConsistency()
            try alignment.accept(candidate.transform_query_to_map,sessionID:result.session_id)
            phase = .navigation;spacePlanned = [];lastSpacePlan = nil;spaceFailure = nil;progress = 0;completed = false
            var fields:[String:Any] = ["candidate_index":selectedCandidateResultIndex ?? candidateIndex,"candidate_selection_index":candidateIndex,"manual_confirmation":true,"map_from_session":candidate.transform_query_to_map]
            if let before {
                if let frame = scene.session.currentFrame {
                    let oldCamera = CampusMapGeometry.multiply(before,matrixRows(frame.camera.transform))
                    let newCamera = CampusMapGeometry.multiply(candidate.transform_query_to_map,matrixRows(frame.camera.transform))
                    fields["camera_correction_m"] = sqrt((0..<3).reduce(0.0) { $0+pow(oldCamera[$1][3]-newCamera[$1][3],2) })
                }
                let delta = CampusMapGeometry.multiply(candidate.transform_query_to_map,CampusMapGeometry.inverse(before))
                fields["yaw_correction_deg"] = atan2(delta[0][2],delta[2][2])*180/Double.pi
            }
            if let map {
                confirmedAlignment = LiDARConfirmedAlignment(map_id:map.map_id,geometry_sha256:geometrySHA256,
                    session_id:sessionID,generation:arSessionGeneration,attempt_id:result.provenance?.attempt_id ?? attemptID,
                    candidate_index:selectedCandidateResultIndex,transform:candidate.transform_query_to_map)
            }
            log("alignment_physically_confirmed",fields);refresh()
            invalidateRefresh("new_confirmation")
            if supplementDirectory != nil { enterSupplement();return }
            saveResume(.confirmed)
            if crossMap != nil { planCrossMap() }
            if let frame = scene.session.currentFrame { renderNavigation(frame) }
        } catch { campusError(error) }
    }
    /// Navigation follows the space route only (no hand-drawn network, no fallback): the shortest
    /// reachable destination entrance, planned on `compute`. When none is reachable the route stays
    /// empty and every entrance's reason is shown.
    private func planSpaceRoute(from position:ProbePoint) {
        guard let grid = spaceGrid,let map,!spacePlanning else { return }
        spacePlanning = true;lastSpacePlan = position
        let targets = map.nodes.filter { destinations.contains($0.id) },token = generation
        compute.async { [weak self] in
            let started = ProcessInfo.processInfo.systemUptime
            // Outside the walkable area: plan from the nearest walkable place; the return arrow points there.
            // Beyond 30 m the position itself is suspect, so no arrow, only a re-localization prompt.
            let inside = LiDARSpacePlanner.nearestWalkable(grid,x:position.x,z:position.z,maxDistance:grid.params.endpoint_snap_m) != nil
            let back = inside ? nil : LiDARSpacePlanner.nearestWalkable(grid,x:position.x,z:position.z,maxDistance:30)
            if !inside && back == nil {
                DispatchQueue.main.async {
                    guard let self,self.generation == token else { return }
                    self.spacePlanning = false;self.spacePlanned = [];self.offMapDistance = nil
                    self.spaceFailure = "已离开地图区域超过 30 米，位置可能已失准。请回到地图范围内，或点击重新定位。"
                    self.log("space_route_planned",["status":"far_outside_map"])
                    if self.phase == .navigation { self.root?.isEnabled = false;self.status.text = "已离开地图区域";self.detail.text = self.spaceFailure }
                }
                return
            }
            let from = back.map { (x:$0.x,z:$0.z) } ?? (x:position.x,z:position.z)
            let routes = targets.map { (node:$0,route:LiDARSpacePlanner.route(grid,from:from,to:($0.position.x,$0.position.z))) }
            let best = routes.filter { $0.route.status == "ok" }.min { ($0.route.length_m ?? .infinity) < ($1.route.length_m ?? .infinity) }
            let seconds = ProcessInfo.processInfo.systemUptime-started
            DispatchQueue.main.async {
                guard let self,self.generation == token else { return }
                self.spacePlanning = false
                self.offMapDistance = back?.distance
                if let best {
                    self.spacePlanned = best.route.points.map { ProbePoint($0[0],best.node.position.y,$0[1]) }
                    self.chosenDestinationID = best.node.id;self.progress = 0;self.spaceFailure = nil
                } else {
                    self.spacePlanned = []
                    self.spaceFailure = targets.isEmpty ? "目的地入口不在当前地图中" : routes.map { "「\($0.node.name)」：\($0.route.reason)" }.joined(separator:"\n")
                }
                self.log("space_route_planned",["status":best == nil ? "unreachable" : "ok","length_m":best?.route.length_m ?? NSNull(),"variant":best?.route.variant ?? NSNull(),
                    "lengths":best?.route.lengths ?? [:],"used_paths":best?.route.used_paths ?? [],"seconds":seconds,
                    "selected_node_id":best?.node.id ?? NSNull(),"outside_map_m":back?.distance ?? NSNull(),"reasons":routes.filter { $0.route.status != "ok" }.map { ["node_id":$0.node.id,"reason":$0.route.reason] }])
                if best == nil,self.phase == .navigation,let reason = self.spaceFailure { self.root?.isEnabled = false;self.status.text = "空间路线不可达";self.detail.text = reason }
            }
        }
    }
    /// Records the trusted position (formally decided alignment, normal tracking, no provisional quick
    /// correction in effect) for "start from where I last was". Throttled while walking.
    private func saveResume(_ reason:LiDARIndoorResume.Entry.Reason) {
        let now = ProcessInfo.processInfo.systemUptime
        guard phase == .navigation,!isMapping,!parkedAtTransfer,supplementDirectory == nil,normal,quickApplied == nil,quickChainBase == nil,
              let t = alignment.mapFromSession,let frame = scene.session.currentFrame,let map,let hash = geometrySHA256 else { return }
        if reason == .walking && now-lastResumeSave < 10 { return }
        lastResumeSave = now
        let c = CampusMapGeometry.multiply(t,matrixRows(frame.camera.transform))
        let entry = LiDARIndoorResume.Entry(mapID:map.map_id,geometrySHA256:hash,position:ProbePoint(c[0][3],c[1][3],c[2][3]),reason:reason)
        io.async { var r = LiDARIndoorResume.load(root:LiDARLibrary.root);r.record(entry);try? r.save(root:LiDARLibrary.root) }
    }
    private func renderNavigation(_ frame:ARFrame) {
        guard !parkedAtTransfer,normal,let map,!destinations.isEmpty else { return }
        if phase == .navigation,let t = alignment.mapFromSession {
            let c = CampusMapGeometry.multiply(t,matrixRows(frame.camera.transform)),p = ProbePoint(c[0][3],c[1][3],c[2][3])
            if tripStarted == nil { tripStarted = Date() }
            if let last = lastWalkPosition { let d = hypot(p.x-last.x,p.z-last.z);if d < 3 { walkedM += d } }
            lastWalkPosition = p
        }
        if phase == .navigation { saveResume(.walking) }
        let transform = phase == .review ? candidate?.transform_query_to_map : displayedAlignment(ProcessInfo.processInfo.systemUptime)
        guard let transform else { root?.isEnabled = false;chainGeometry = nil;chain?.hide();return }
        let camera = CampusMapGeometry.multiply(transform,matrixRows(frame.camera.transform))
        let position = ProbePoint(camera[0][3],camera[1][3],camera[2][3])
        guard spaceGrid != nil else {
            root?.isEnabled = false
            if phase == .navigation { status.text = "这张地图还没有可走区域";detail.text = "空间栅格未能生成。请在地图工具中重建可走区域或导入工作台校准后再导航。" }
            updateShell();return
        }
        if spacePlanned.isEmpty && spaceFailure == nil || lastSpacePlan.map({ hypot(position.x-$0.x,position.z-$0.z) > 2 }) ?? true { planSpaceRoute(from:position) }
        do {
            let main = spacePlanned
            guard main.count >= 2 else {
                root?.isEnabled = false;chainGeometry = nil;chain?.hide();guide = nil
                if phase == .navigation { if let reason = spaceFailure { status.text = "空间路线不可达";detail.text = reason } else { status.text = "正在规划空间路线…" } }
                updateShell();return
            }
            let geometry = try CampusRouteGeometry(points:main),projection = try geometry.project(position,near:progress)
            progress = projection.distance
            root?.removeFromParent()
            let anchor = AnchorEntity(world:.zero);anchor.transform = Transform(matrix:matrixFromRows(CampusMapGeometry.inverse(transform)))
            // The arrow chain lives on its own anchor and moves every frame (see updateChain).
            chainGeometry = geometry;chainProgress = progress
            let remainingNow = max(0,geometry.length-progress)
            if let turn = geometry.nextTurn(progress:progress) {
                guide = (turn.direction == .left ? .left : turn.direction == .right ? .right : .uTurn,max(0,turn.distance-progress),remainingNow)
            } else { guide = (remainingNow < Self.arrivalM ? .arrive : .straight,remainingNow,remainingNow) }
            if projection.offset > 1.5 {
                let from = SIMD3(Float(position.x),Float(projection.point.y),Float(position.z)),to = SIMD3(Float(projection.point.x),Float(projection.point.y),Float(projection.point.z))
                anchor.addChild(try RouteRenderer.returnBearing(points:[from,to],target:to))
            }
            scene.scene.addAnchor(anchor);root = anchor
            if phase == .navigation,let leg = currentLeg,let link = leg.link,let plan = crossMap?.plan,plan.legs.count >= 2 {
                let remaining = max(0,geometry.length-progress),nextLabel = label(plan.legs[1].map_id)
                let here = map.nodes.first { $0.id == leg.target_node_id }?.name ?? "连接点"
                if remaining > 5 { parkSuppressed = false }
                // Allow a wider lobby/stair landing; manual confirmation is also available within 15 m.
                let reached = link.kind == .elevator || link.kind == .stairs
                    ? NavigationArrivalPolicy.reachedTransfer(remainingM:remaining,offsetM:projection.offset)
                    : remaining < 3 && projection.offset < 2.5
                if reached && alignmentTransition == nil {
                    if !transitionReady { transitionReady = true;log("cross_map_transition_reached",["node_id":leg.target_node_id,"link_kind":link.kind.rawValue]) }
                    status.text = "已到达「\(here)」"
                    detail.text = link.kind == .elevator ? "乘电梯到\(nextLabel)，出电梯后点击“我已到达”。" : link.kind == .stairs ? "走楼梯到\(nextLabel)，到达后点击“我已到达”。" : "继续走入\(nextLabel)，然后点击“我已到达”。"
                    if !parkedAtTransfer && !parkSuppressed && (link.kind == .elevator || link.kind == .stairs) { parkAtTransfer(plan) }
                } else {
                    status.text = "第 1/\(plan.legs.count) 段 · 前往「\(here)」· 约 \(Int(remaining.rounded())) 米";guideStatus = status.text
                    detail.text = "之后\(link.kind.title)到\(nextLabel)，最终目的地：\(destinationName)"
                }
            } else if phase == .navigation {
                let remaining = max(0,geometry.length-progress)
                status.text = remaining < Self.arrivalM && projection.offset < Self.arrivalOffM ? "已接近目的地" : "沿路线前行 · 剩余约 \(Int(remaining.rounded())) 米";guideStatus = status.text
                let turn = geometry.nextTurn(progress:progress)
                let turnText = turn.map { "约\(Int(max(0,$0.distance-progress).rounded()))米后\($0.direction == .left ? "左转" : $0.direction == .right ? "右转" : "掉头")" } ?? "沿当前路线继续前行"
                detail.text = projection.offset > 1.5 ? (offMapDistance != nil ? String(format:"已离开地图区域，橙色箭头指向最近的可走区域（约 %.0f 米）。",projection.offset) : String(format:"距路线约 %.1f 米，橙色箭头指向路线。若放错位置，请报告错位并重新定位。",projection.offset)) : "\(turnText)\nARKit 持续跟踪 · 需要时点击重新定位"
                if remaining < Self.arrivalM && projection.offset < Self.arrivalOffM && !completed && alignmentTransition == nil {
                    completed = true;saveResume(.arrived);log("destination_approached",["numeric_accuracy_measured":false,"destination_name":destinationName,"selected_node_id":chosenDestinationID ?? "unknown"])
                    arriveAndSummarise()
                }
            }
        } catch { root?.isEnabled = false;chainGeometry = nil;chain?.hide();status.text = "路线计算失败：\(error.localizedDescription)" }
        updateShell()
    }
    /// Every frame while a route is shown: the chain follows the displayed alignment and eased progress.
    private func updateChain(_ frame:ARFrame) {
        guard normal,phase == .navigation || phase == .review,let geometry = chainGeometry,
              let transform = phase == .review ? candidate?.transform_query_to_map : displayedAlignment(ProcessInfo.processInfo.systemUptime) else { chain?.hide();return }
        if chain == nil { let c = GroundArrowChain(),a = AnchorEntity(world:.zero);a.addChild(c.root);scene.scene.addAnchor(a);chain = c;chainAnchor = a }
        chainAnchor?.transform = Transform(matrix:matrixFromRows(CampusMapGeometry.inverse(transform)))
        let target = chainProgress
        let shown = shownChainProgress.map { abs(target-$0) > 6 ? target : $0+(target-$0)*0.15 } ?? target
        shownChainProgress = shown
        let grid = spaceGrid
        chain?.update(route:geometry,progress:shown,lengthM:arrowChainM,turns:chainTurns(geometry).map { (at:$0.0,right:$0.1) },
                      floor:{ x,z in grid?.floorField?.floor(x,z) ?? grid.map { $0.floorY } })
    }
    /// Floor-arrow turns: only real corners (≥ 75° net); gentle bends are left to the chevrons. Cached per route.
    private var chainTurnCache:(length:Double,count:Int,turns:[(Double,Bool)])?
    private func chainTurns(_ geometry:CampusRouteGeometry) -> [(Double,Bool)] {
        if let c = chainTurnCache,c.length == geometry.length,c.count == geometry.points.count { return c.turns }
        let turns = geometry.sharpTurns().filter { $0.direction != .turnBack }.map { ($0.distance,$0.direction == .right) }
        chainTurnCache = (geometry.length,geometry.points.count,turns);return turns
    }
    private func mark() {
        guard isMapping,normal,phase == .collecting,frames >= 3,pendingMark == nil,!geometryUncertain,!diagnosticSegment else { return }
        let screen = scene.convert(reticle.center,from:view)
        let hit = scene.raycast(from:screen,allowing:.existingPlaneGeometry,alignment:.horizontal).first
            ?? scene.raycast(from:screen,allowing:.estimatedPlane,alignment:.horizontal).first
        guard let hit,let frame = scene.session.currentFrame,simd_distance(hit.worldTransform.columns.3,frame.camera.transform.columns.3) < 4.5 else {
            campusMessage("未找到近处地面","缓慢观察地面，再将＋对准需要标记的位置。");return
        }
        let p = hit.worldTransform.columns.3,point = toMap(ProbePoint(Double(p.x),Double(p.y),Double(p.z)))
        let floor = budgetSnapshot?.floor_y ?? LiDARSampling.floorHeight(Array(cloud.values))
        guard abs(point.y-floor) < 0.30,cloud.values.contains(where:{ abs($0.x-point.x) < 0.8 && abs($0.z-point.z) < 0.8 && abs($0.y-point.y) < 0.35 }) else {
            campusMessage("请先扫描这片地面","将附近地面扫入点云后再标记，避免标到桌面或尚未采集的区域。");return
        }
        if let first = nodes.first,abs(first.position.y-point.y) > 0.45 { campusMessage("请保持同一楼层","这一阶段先建单层局部路线，楼梯和台面不要作为地面标点。");return }
        if nodes.contains(where:{ hypot($0.position.x-point.x,$0.position.z-point.z) < 0.25 }) { campusMessage("距离已有节点太近","可在工具中选择已有节点作为下一条线的起点。");return }
        pendingMark = PendingMark(point:point,session:sessionID,coordinateGeneration:arSessionGeneration,
            timestamp:frame.timestamp,camera:matrixRows(frame.camera.transform),
            keyframeIndex:lastAcceptedForMark.flatMap { frame.timestamp-$0.timestamp <= 1 ? $0.index : nil },
            keyframeDelta:lastAcceptedForMark.flatMap { frame.timestamp-$0.timestamp <= 1 ? frame.timestamp-$0.timestamp : nil })
        refresh()
        let form = LiDARNodeNamingController(number:nodes.count+1,spaceMode:routeEditor.spaceMode) { [weak self] input in
            guard let self,let mark = self.pendingMark else { return }
            self.pendingMark = nil
            guard let input else { self.log("route_node_cancelled");self.refresh();return }
            guard !mark.invalid,mark.session == self.sessionID,mark.coordinateGeneration == self.arSessionGeneration,
                  self.normal,self.phase == .collecting else {
                self.campusMessage("标点坐标已失效","命名期间跟踪发生变化，请重新对准地面标记。");self.refresh();return
            }
            do {
                let capture = LiDARNodeCaptureContext(timestamp:mark.timestamp,session_id:mark.session,
                    generation:mark.coordinateGeneration,camera_to_session:mark.camera,
                    keyframe_index:mark.keyframeIndex,keyframe_dt_s:mark.keyframeDelta)
                let node = try self.routeEditor.addNode(name:input.name,kind:input.kind,position:mark.point,capture:capture)
                self.syncRouteEditor()
                self.log("route_node_added",["node_id":node.id,"name":node.name,"kind":input.kind.rawValue,
                    "position":mark.point.array,"marked_timestamp":mark.timestamp,"camera_at_mark":mark.camera])
            } catch { self.campusError(error);self.refresh() }
        }
        let panel = UINavigationController(rootViewController:form);panel.isModalInPresentation = true
        present(panel,animated:true)
    }
    private func syncRouteEditor() {
        nodes = routeEditor.nodes;edges = routeEditor.edges;selectedNode = routeEditor.connectFrom
        let ids = Set(nodes.filter { $0.resolvedKind == .room }.map(\.id))
        for i in plateRecords.indices {
            if let id = plateRecords[i].destination.node_id,!ids.contains(id) {
                plateRecords[i].destination = LiDARLandmarkDestination(enabled:false,node_id:nil)
                log("plate_binding_invalidated",["landmark_id":plateRecords[i].id,"removed_node_id":id])
            }
        }
        renderMapping();refresh()
    }
    private func renderMapping() {
        root?.removeFromParent();let anchor = AnchorEntity(world:.zero)
        if let t = supplementTransform { anchor.transform = Transform(matrix:matrixFromRows(CampusMapGeometry.inverse(t))) }
        let byID = Dictionary(uniqueKeysWithValues:nodes.map { ($0.id,$0.position) })
        for e in edges {
            if let a = byID[e.from],let b = byID[e.to],let line = try? RouteRenderer.network(points:[SIMD3(Float(a.x),Float(a.y),Float(a.z)),SIMD3(Float(b.x),Float(b.y),Float(b.z))],arrows:false) { anchor.addChild(line) }
        }
        for node in nodes {
            let marker = ModelEntity(mesh:.generateSphere(radius:0.12),materials:[UnlitMaterial(color:node.id == selectedNode ? .systemYellow : .systemTeal)])
            marker.scale.y = 0.08;marker.position = SIMD3(Float(node.position.x),Float(node.position.y)+0.025,Float(node.position.z));anchor.addChild(marker)
        }
        root = anchor;scene.scene.addAnchor(anchor)
    }
    private func saveMap(warningsConfirmed:Bool = false) {
        guard isMapping,[.collecting,.suspended].contains(phase),nodes.count >= (routeEditor.spaceMode ? 1 : 2),let writer else { return }
        if working { savePending = true;return }
        guard plateToken == nil else { return }
        if geometryUncertain,let baselineEditor { routeEditor = baselineEditor;syncRouteEditor() }
        let set = LiDARLandmarkSet(mapID:writer.manifest.scan_id,geometrySHA256:nil,landmarks:plateRecords)
        let check = routeEditor.saveCheck(landmarks:set)
        guard check.blocking.isEmpty else { campusMessage("路网尚未连通",check.blocking.joined(separator:"\n"));return }
        let withoutEntrance = LiDARRouteEditor.platesWithoutEntrance(set)
        if !warningsConfirmed && !check.warnings.isEmpty {
            let names = withoutEntrance.prefix(8).map { $0.text.raw }.joined(separator:"、")
            let alert = UIAlertController(title:"部分门牌未设入口",message:"\(withoutEntrance.count) 个门牌未设入口（\(names)）。仍会保留在门牌列表中，但不能导航到；本版保存后暂不支持补设入口。",preferredStyle:.alert)
            alert.addAction(UIAlertAction(title:"返回设置",style:.cancel))
            alert.addAction(UIAlertAction(title:"仍然保存",style:.default) { [weak self] _ in self?.saveMap(warningsConfirmed:true) })
            present(alert,animated:true);return
        }
        let storedPlates = plateRecords,drawnPaths = phonePaths
        let editor = routeEditor,sid = sessionID,wasInterrupted = phase == .suspended
        if let directory = supplementDirectory,let base = map,supplementTransform != nil {
            saveSupplement(directory:directory,base:base,editor:editor,plates:storedPlates,wasInterrupted:wasInterrupted,writer:writer);return
        }
        phase = .solving;status.text = "正在保存已接受的几何与路线…";refresh()
        io.async { [self] in
            let points = mappingBudget.runtimePoints(limit:LiDARScanLimits.mapVoxelsV3)
            var saved = editor.map(mapID:writer.manifest.scan_id,sessionID:sid,name:name,pointCount:points.count,voxel:0.10)
            saved.sources = [LiDARMapSource(kind:LiDARMapSource.initial,scanID:writer.manifest.scan_id,sessionID:sid,
                mapFromSession:[[1,0,0,0],[0,1,0,0],[0,0,1,0],[0,0,0,1]],confirmation:"identity",acceptedFrames:acceptedFrameIDs.count)]
            let outcome = Result { () -> Void in
                try saved.validate()
                guard acceptedFrameIDs.count >= 3 else { throw LiDARScanError.invalid("至少需要3个已接受几何关键帧，原始诊断记录仍保留") }
                _ = try writer.finish(reason:wasInterrupted ? "accepted_prefix_after_interruption" : "navigation_map_saved",valid:!wasInterrupted && diagnosticFrameIDs.isEmpty)
                try LiDARNavigationStore.write(mappingBudget.snapshot(),to:writer.directory.appendingPathComponent("budget-summary.json"))
                let summary:[String:Any] = ["schema_version":1,"map_id":saved.map_id,"ar_session_id":sid,
                    "accepted_frame_ids":acceptedFrameIDs,"diagnostic_frame_ids":diagnosticFrameIDs,
                    "geometry_source":"accepted_batches_only","was_interrupted":wasInterrupted,
                    "budget_batch":mappingBudget.batch,"numeric_accuracy_measured":false]
                try ProbeIO.json(summary,pretty:true).write(to:writer.directory.appendingPathComponent("capture-summary.json"),options:.atomic)
                let geometryBytes = try LiDARPointFile.encode(points)
                try geometryBytes.write(to:writer.directory.appendingPathComponent("geometry.f32"),options:.atomic)
                let set = LiDARLandmarkSet(mapID:saved.map_id,geometrySHA256:Self.digest(geometryBytes),landmarks:storedPlates)
                try set.validate(against:saved)
                _ = try LiDARLandmarkFileCleanup.prune(in:writer.directory,keepingIDs:storedPlates.map(\.id))
                // Recount surviving referenced files: a failed partial write may never have
                // reached the old counter, so subtracting removed bytes could undercount.
                let evidencePaths = Set(storedPlates.flatMap { plate in
                    plate.evidence.flatMap { [$0.image_file,$0.depth_file,$0.confidence_file].compactMap { $0 } }+[plate.best_crop].compactMap { $0 }
                })
                manualEvidenceBytes = 0
                for path in evidencePaths {
                    let attributes = try FileManager.default.attributesOfItem(atPath:writer.directory.appendingPathComponent(path).path)
                    guard let size = attributes[.size] as? NSNumber else { throw LiDARScanError.invalid("无法统计门牌证据文件") }
                    manualEvidenceBytes += size.intValue
                }
                try LiDARNavigationStore.write(set,to:writer.directory.appendingPathComponent(LiDARLandmarkSet.fileName))
                let draft = writer.directory.appendingPathComponent("landmarks-draft.json")
                if FileManager.default.fileExists(atPath:draft.path) { try FileManager.default.removeItem(at:draft) }
                if let recorder,let magnetic = try? recorder.snapshotLog("magnetic-heading.jsonl"),!magnetic.isEmpty {
                    try magnetic.write(to:writer.directory.appendingPathComponent("magnetic-samples.jsonl"),options:.atomic)
                    let source:[String:Any] = ["schema_version":1,"map_id":saved.map_id,"geometry_sha256":Self.digest(geometryBytes),
                            "source_scan_id":writer.manifest.scan_id,"source_run_id":recorder.runID,"session_id":sid,
                            "samples_file":"magnetic-samples.jsonl","axis_mapping_id":"portrait_view_up_v1","axis_mapping_verified":false,"used_for_localization":false]
                    try ProbeIO.json(source,pretty:true).write(to:writer.directory.appendingPathComponent("magnetic-samples.json"),options:.atomic)
                    let reference = LiDARMagnetic.reference(LiDARMagnetic.samples(jsonl:magnetic,sessionID:sid))
                    if !reference.cells.isEmpty { try LiDARNavigationStore.write(reference,to:writer.directory.appendingPathComponent(LiDARMagnetic.Reference.fileName)) }
                }
                let image = writer.directory.appendingPathComponent("frames/0000/rgb.jpg")
                if FileManager.default.fileExists(atPath:image.path) { try Data(contentsOf:image).write(to:writer.directory.appendingPathComponent("reference.jpg"),options:.atomic) }
                if let captureBuilding,let captureFloor {
                    let placement = try LiDARMapPlacement(mapID:saved.map_id,building:captureBuilding,floor:captureFloor,region:name)
                    try placement.validate(mapID:saved.map_id)
                    try LiDARNavigationArchive.write(placement,to:writer.directory.appendingPathComponent(LiDARMapPlacement.fileName))
                }
                // Space routing: where the mapper walked (accepted keyframes only) and the paths drawn on the phone.
                var walkedScan = writer.manifest;walkedScan.frames = walkedScan.frames.filter { acceptedFrameIDs.contains($0.index) }
                let walked = LiDARWalkedTrajectory.from(mapID:saved.map_id,scans:[walkedScan])
                if !walked.polylines.isEmpty { try LiDARNavigationStore.write(walked,to:writer.directory.appendingPathComponent(LiDARWalkedTrajectory.fileName)) }
                if !drawnPaths.isEmpty {
                    let calibration = LiDARPassageCalibration(mapID:saved.map_id,geometrySHA256:Self.digest(geometryBytes),editor:"phone",paths:drawnPaths)
                    try calibration.validate(mapID:saved.map_id)
                    try LiDARNavigationStore.write(calibration,to:writer.directory.appendingPathComponent(LiDARPassageCalibration.fileName))
                }
                // Publish navigation.json last; interrupted saves are not listed as maps.
                try LiDARNavigationStore.write(saved,to:writer.directory.appendingPathComponent("navigation.json"))
                try ProbeIO.makeManifest(at:writer.directory)
            }
            let savedStorageBytes = writer.rawBytes+manualEvidenceBytes
            DispatchQueue.main.async { [self] in
                switch outcome {
                case .success:rawBytesRecorded = savedStorageBytes;routeEditor.markSaved();phase = .finished;status.text = "地图已保存";detail.text = "\(nodes.count) 个节点 · \(edges.count) 条连接 · \(points.count) 个运行点\n结束后从首页“导航”进入，重新启动独立会话验证。";onSaved?();log("navigation_map_saved",["map_id":saved.map_id,"point_count":points.count]);refresh()
                case .failure(let error):phase = .suspended;status.text = "保存未完成，请导出原始记录检查";refresh();campusError(error)
                }
            }
        }
    }
    /// Updates the original map in place: everything is written to a staging folder, then
    /// LiDARMapVersions.publish snapshots the old map and swaps the files (navigation.json last),
    /// restoring the snapshot on failure. The supplement's raw scan stays in its own folder.
    private func saveSupplement(directory:URL,base:LiDARNavigationMap,editor:LiDARRouteEditor,plates:[LiDARLandmark],wasInterrupted:Bool,writer:LiDARScanWriter) {
        guard let transform = supplementTransform else { return }
        let sid = sessionID,confirmation = supplementConfirmation,oldPlateIDs = Set(knownPlates.map(\.id)),drawnPaths = phonePaths,calibration = existingCalibration
        phase = .solving;status.text = "正在更新原图（先备份旧版本）…";refresh()
        io.async { [self] in
            let points = mappingBudget.runtimePoints(limit:LiDARScanLimits.mapVoxelsV3)
            var saved = editor.map(mapID:base.map_id,sessionID:base.session_id,name:base.name,pointCount:points.count,voxel:0.10)
            saved.created_utc = base.created_utc
            var sources = base.sources ?? [LiDARMapSource(kind:LiDARMapSource.initial,scanID:base.map_id,sessionID:base.session_id,
                mapFromSession:[[1,0,0,0],[0,1,0,0],[0,0,1,0],[0,0,0,1]],confirmation:"identity",acceptedFrames:0)]
            var source = LiDARMapSource(kind:LiDARMapSource.supplement,scanID:writer.manifest.scan_id,sessionID:sid,mapFromSession:transform,acceptedFrames:acceptedFrameIDs.count)
            source.generation = confirmation?.generation;source.attempt_id = confirmation?.attempt;source.candidate_index = confirmation?.candidate
            sources.append(source);saved.sources = sources
            let fm = FileManager.default,stage = fm.temporaryDirectory.appendingPathComponent("supplement-"+UUID().uuidString)
            defer { try? fm.removeItem(at:stage) }
            let outcome = Result { () -> Void in
                try saved.validate()
                _ = try writer.finish(reason:wasInterrupted ? "supplement_prefix_after_interruption" : "supplement_saved",valid:!wasInterrupted && diagnosticFrameIDs.isEmpty)
                try fm.createDirectory(at:stage,withIntermediateDirectories:true)
                let geometryBytes = try LiDARPointFile.encode(points)
                try geometryBytes.write(to:stage.appendingPathComponent("geometry.f32"),options:.atomic)
                try LiDARNavigationStore.write(mappingBudget.snapshot(),to:stage.appendingPathComponent("budget-summary.json"))
                let summary:[String:Any] = ["schema_version":1,"map_id":base.map_id,"kind":"supplement","supplement_scan_id":writer.manifest.scan_id,
                    "ar_session_id":sid,"accepted_frame_ids":acceptedFrameIDs,"diagnostic_frame_ids":diagnosticFrameIDs,"seed_points":base.point_count,
                    "geometry_source":"seeded_map_plus_accepted_batches","was_interrupted":wasInterrupted,"numeric_accuracy_measured":false]
                try ProbeIO.json(summary,pretty:true).write(to:stage.appendingPathComponent("capture-summary.json"),options:.atomic)
                // The published summary is replaced by later versions; the raw scan keeps its own copy.
                try ProbeIO.json(summary,pretty:true).write(to:writer.directory.appendingPathComponent("capture-summary.json"),options:.atomic)
                try ProbeIO.makeManifest(at:writer.directory)
                let evidence = directory.appendingPathComponent(LiDARLandmarkSet.directoryName)
                if fm.fileExists(atPath:evidence.path) { try fm.copyItem(at:evidence,to:stage.appendingPathComponent(LiDARLandmarkSet.directoryName)) }
                try LiDARMapVersions.copyEvidence(from:writer.directory,to:stage,ids:plates.map(\.id).filter { !oldPlateIDs.contains($0) })
                let set = LiDARLandmarkSet(mapID:saved.map_id,geometrySHA256:Self.digest(geometryBytes),landmarks:plates)
                try set.validate(against:saved)
                _ = try LiDARLandmarkFileCleanup.prune(in:stage,keepingIDs:plates.map(\.id))
                try LiDARNavigationStore.write(set,to:stage.appendingPathComponent(LiDARLandmarkSet.fileName))
                // Walked trajectory (this supplement's accepted frames, in map coordinates) merged into the map's.
                var walkedScan = writer.manifest;walkedScan.frames = walkedScan.frames.filter { acceptedFrameIDs.contains($0.index) }
                var walked = LiDARWalkedTrajectory.from(mapID:base.map_id,scans:[walkedScan])
                if let data = try? Data(contentsOf:directory.appendingPathComponent(LiDARWalkedTrajectory.fileName)),
                   let old = try? JSONDecoder().decode(LiDARWalkedTrajectory.self,from:data),old.map_id == base.map_id { walked = old.merged(with:walked) }
                if !walked.polylines.isEmpty { try LiDARNavigationStore.write(walked,to:stage.appendingPathComponent(LiDARWalkedTrajectory.fileName)) }
                // Calibration: keep walkable, auto_params and the raster's base hash; only append this session's paths.
                if !drawnPaths.isEmpty {
                    var next = calibration ?? LiDARPassageCalibration(mapID:base.map_id,geometrySHA256:Self.digest(geometryBytes),editor:"phone")
                    next.suggested_paths += drawnPaths;next.updated_utc = ISO8601DateFormatter().string(from:Date())
                    try next.validate(mapID:base.map_id)
                    try LiDARNavigationStore.write(next,to:stage.appendingPathComponent(LiDARPassageCalibration.fileName))
                }
                // Compass reference: the map's existing cells plus this session's readings moved into the map.
                if let recorder,let log = try? recorder.snapshotLog("magnetic-heading.jsonl") {
                    let added = LiDARMagnetic.reference(LiDARMagnetic.moved(LiDARMagnetic.samples(jsonl:log,sessionID:sid),by:transform))
                    let merged = magneticReference.map { $0.merged(with:added) } ?? added
                    if !merged.cells.isEmpty { try LiDARNavigationStore.write(merged,to:stage.appendingPathComponent(LiDARMagnetic.Reference.fileName)) }
                }
                try LiDARNavigationStore.write(saved,to:stage.appendingPathComponent("navigation.json"))
                try LiDARMapVersions.publish(directory,staged:stage)
            }
            DispatchQueue.main.async { [self] in
                switch outcome {
                case .success:
                    routeEditor.markSaved();phase = .finished;status.text = "原图已更新"
                    detail.text = "\(nodes.count) 个节点 · \(edges.count) 条连接 · \(points.count) 个点\n更新前的版本已保留，可在建图的地图操作中恢复。";onSaved?()
                    log("supplement_map_saved",["map_id":base.map_id,"point_count":points.count,"scan_id":writer.manifest.scan_id]);refresh()
                case .failure(let error):phase = .suspended;status.text = "更新未完成，原图保持不变";refresh();campusError(error)
                }
            }
        }
    }
    @objc private func tools() {
        guard plateToken == nil else { campusMessage("门牌处理中","请先确认或取消当前门牌记录。");return }
        if isMapping {
            if phase == .suspended {
                campusChoices("会话已停用",message:"不能沿用旧坐标续扫；可以保存中断前已接受的部分或导出原始记录。",choices:[
                    ("保存中断前已接受的路网",{ [weak self] in self?.saveMap() }),
                    ("导出原始记录",{ [weak self] in self?.exportCurrentScan() })]);return
            }
            guard phase == .collecting else { return }
            if geometryUncertain || diagnosticSegment {
                campusChoices("异常段",choices:[("处理疑似偏移",{ [weak self] in self?.presentRevisitReview() }),("导出当前原始记录",{ [weak self] in self?.exportCurrentScan() })]);return
            }
            campusChoices("路线工具",message:"当前连接起点：\(nodes.first(where:{$0.id == selectedNode})?.name ?? "未选择，下一点不连线")",choices:[
                ("点云叠加：\(overlayVisible ? "开" : "关")",{ [weak self] in self?.togglePointOverlay() }),
                ("深度对齐上色：\(overlayDepthColors ? "开" : "关")",{ [weak self] in self?.toggleDepthColors() }),
                ("墙角线：\(linesVisible ? "开" : "关")",{ [weak self] in self?.toggleLines() }),
                ("画建议通行路径",{ [weak self] in self?.startPathDraft() }),
                ("添加房间",{ [weak self] in self?.startManualRoom() }),
                ("门牌列表",{ [weak self] in self?.presentPlateList() }),
                ("重点采集一帧",{ [weak self] in self?.manualKeyframeRequested = true;self?.log("manual_keyframe_requested") }),
                ("查看当前采集分布",{ [weak self] in self?.showCurrentDistribution() }),
                ("删除本次画的上一条路径（共 \(phonePaths.count) 条）",{ [weak self] in
                    guard let self,!self.phonePaths.isEmpty else { return };let removed = self.phonePaths.removeLast();self.renderPaths();self.log("suggested_path_removed",["path_id":removed.id])
                }),
                ("修改节点名称",{ [weak self] in self?.chooseNode("选择节点") { [weak self] node in self?.campusText("节点名称",value:node.name) { name in
                    guard let self else { return };do { try self.routeEditor.rename(node.id,to:name);self.syncRouteEditor();self.log("route_node_renamed",["node_id":node.id,"name":name]) } catch { self.campusError(error) }
                } } }),
                ("修改节点类型",{ [weak self] in self?.chooseNode("选择节点") { [weak self] node in
                    self?.campusChoices("节点类型",choices:CampusNodeKind.allCases.map { kind in
                        (kind.title,{ [weak self] in guard let self else { return };do { try self.routeEditor.setKind(node.id,kind);self.syncRouteEditor();self.log("route_node_kind_changed",["node_id":node.id,"kind":kind.rawValue]) } catch { self.campusError(error) } })
                    })
                } }),
                ("撤销：\(routeEditor.undoTitle ?? "暂无操作")",{ [weak self] in
                    guard let self else { return };if let command = self.routeEditor.undo() { self.syncRouteEditor();self.log("route_command_undone",["command":command]) }
                }),
                ("操作说明",{ [weak self] in self?.campusMessage("建图与标点（空间路网试验版）","地面要扫全：哪里能走由扫到的地面和你走过的路线决定。用＋标出有名字的地点（房间入口、楼梯口、电梯口、命名路口），不需要连线。窄通道或希望固定走法的地方，用“画建议通行路径”逐点画线，路径上必须没有障碍物。暂停采集仍可标点，但跟踪必须正常。名称与类型可修改。热暂停须降温稳定后手动恢复，不代表消除了漂移。\n\n采集要领：离固定结构约1–3米，缓慢往返并上下倾斜手机，换角度和距离；同一视角反复扫描收益很小。多观察墙角、门框和有纹理的固定结构，避开玻璃和镜面。长走廊先分成小区域，返回起点检查重影，但这不代表做过闭环校正。") })])
        } else {
            campusChoices("导航工具",choices:(debugPanelOn && supplementDirectory == nil ? [("关闭调试界面（返回导航界面）",{ [weak self] in
                    UserDefaults.standard.set(false,forKey:"lidar.debugPanel");self?.applyChrome() })] : [])+[
                ("点云叠加：\(overlayVisible ? "开" : "关")",{ [weak self] in self?.togglePointOverlay() }),
                ("深度对齐上色：\(overlayDepthColors ? "开" : "关")",{ [weak self] in self?.toggleDepthColors() }),
                ("墙角线：\(linesVisible ? "开" : "关")",{ [weak self] in self?.toggleLines() }),
                ("记录路线位置正确",{ [weak self] in self?.log("physical_alignment_feedback",["correct":true,"numeric_accuracy_measured":false]);self?.campusMessage("已记录","这条反馈用于现场核对，不作为厘米级精度测量。") }),
                ("报告路线错位",{ [weak self] in self?.log("physical_alignment_feedback",["correct":false]);self?.clearConfirmedReference("reported_misalignment");self?.root?.isEnabled = false;self?.alignment.reset(sessionID:self?.sessionID ?? "");self?.phase = .idle;self?.refresh() }),
                ("定位采集帧数：\(queryFrameTarget)",{ [weak self] in
                    self?.campusChoices("定位采集帧数",message:"采满后计算；帧数越多信息越多，耗时越长。",choices:[16,24,32,48,64].map { n in ("\(n) 帧",{ UserDefaults.standard.set(n,forKey:"lidar.queryFrames");self?.refresh() }) })
                }),
                ("自动提前结束：\(autoEarlyStop ? "开" : "关")",{ [weak self] in UserDefaults.standard.set(!(self?.autoEarlyStop ?? false),forKey:"lidar.queryAutoStop");self?.refresh() }),
                ("自动刷新定位：\(refreshMode == "off" ? "关" : "开")",{ [weak self] in
                    guard let self else { return };UserDefaults.standard.set(self.refreshMode == "off" ? "prompt" : "off",forKey:"lidar.refreshMode");self.log("refresh_mode_changed",["mode":self.refreshMode])
                }),
                ("快速粗修正（走廊/拐角）：\(quickCorrectionOn ? "开" : "关")",{ [weak self] in
                    guard let self else { return };UserDefaults.standard.set(!self.quickCorrectionOn,forKey:"lidar.quickCorrection")
                }),
                ("大幅修正：\(largeCorrectionMode == "direct" ? "直接更改" : "询问")",{ [weak self] in
                    guard let self else { return };UserDefaults.standard.set(self.largeCorrectionMode == "direct" ? "ask" : "direct",forKey:"lidar.largeCorrection.v2")
                }),
                ("深度按需：\(depthOnDemand ? "开" : "关（持续输出）")",{ [weak self] in
                    guard let self else { return };self.depthOnDemand.toggle();UserDefaults.standard.set(self.depthOnDemand,forKey:"lidar.depthOnDemand");self.synchronizeDepth(reason:"user_depth_policy");self.refresh()
                }),
                ("查看定位指标",{ [weak self] in guard let self else { return };self.campusMessage("当前定位",self.result.map { String(format:"%@\n计算 %.2f 秒\n地图 %d 点，查询 %d 点\n结构约束比 %.3f\n所有分数仅表示几何贴合，需现场核对。",$0.reason,$0.registration_seconds,$0.map_points,$0.query_points,$0.structural_constraint_ratio) } ?? "尚未完成定位") })])
        }
    }
    private func togglePointOverlay() {
        UserDefaults.standard.set(!overlayVisible,forKey:"lidar.overlay."+overlayContext)
        lastOverlayUpdate = -.infinity
        if let frame = scene.session.currentFrame { updatePointOverlay(frame) }
        log("point_overlay_changed",["context":overlayContext,"enabled":overlayVisible])
    }
    private func toggleLines() {
        UserDefaults.standard.set(!linesVisible,forKey:"lidar.structureLines");lastLinesUpdate = -.infinity
        if !linesVisible { linesRoot?.removeFromParent();linesRoot = nil }
        log("structure_lines_changed",["enabled":linesVisible])
    }
    private func toggleDepthColors() {
        overlayDepthColors.toggle();UserDefaults.standard.set(overlayDepthColors,forKey:"lidar.overlay.depthColors")
        lastOverlayUpdate = -.infinity
        if let frame = scene.session.currentFrame { updatePointOverlay(frame) }
        log("point_overlay_depth_colors_changed",["enabled":overlayDepthColors])
    }
    private func updatePointOverlay(_ frame:ARFrame) {
        let heat = ProcessInfo.processInfo.thermalState.rawValue
        guard overlayVisible,heat < 2,normal,!closing else {
            if !pointOverlay.isHidden { pointOverlay.isHidden = true;pointOverlay.clear() };return
        }
        guard frame.timestamp-lastOverlayUpdate >= 0.33 else { return };lastOverlayUpdate = frame.timestamp
        let transform:simd_float4x4
        let points:[ProbePoint]
        if isMapping,let t = supplementTransform { transform = matrixFromRows(CampusMapGeometry.inverse(t));points = referencePoints }
        else if isMapping { transform = matrix_identity_float4x4;points = Array(cloud.values) }
        else {
            let mapFromSession = phase == .review ? candidate?.transform_query_to_map : displayedAlignment(ProcessInfo.processInfo.systemUptime)
            guard let mapFromSession else { pointOverlay.isHidden = true;pointOverlay.clear();return }
            transform = matrixFromRows(CampusMapGeometry.inverse(mapFromSession));points = referencePoints
        }
        let inverse = simd_inverse(frame.camera.transform)
        // Both buffers belong to this ARFrame. Read their padded rows directly; no full-frame copy.
        let liveDepth = overlayDepthColors && depthRequested ? frame.sceneDepth : nil
        let depthBuffer = liveDepth?.depthMap,confidenceBuffer = liveDepth?.confidenceMap
        if let depthBuffer { CVPixelBufferLockBaseAddress(depthBuffer,.readOnly) }
        if let confidenceBuffer { CVPixelBufferLockBaseAddress(confidenceBuffer,.readOnly) }
        defer {
            if let depthBuffer { CVPixelBufferUnlockBaseAddress(depthBuffer,.readOnly) }
            if let confidenceBuffer { CVPixelBufferUnlockBaseAddress(confidenceBuffer,.readOnly) }
        }
        var summary = LiDAROverlayCheck.Summary()
        func comparison(_ camera:SIMD4<Float>) -> LiDAROverlayCheck.Status {
            guard let depthBuffer,let confidenceBuffer,
                  CVPixelBufferGetPixelFormatType(depthBuffer) == kCVPixelFormatType_DepthFloat32,
                  CVPixelBufferGetPixelFormatType(confidenceBuffer) == kCVPixelFormatType_OneComponent8,
                  let depthBase = CVPixelBufferGetBaseAddress(depthBuffer),let confidenceBase = CVPixelBufferGetBaseAddress(confidenceBuffer) else { return .unknown }
            let width = CVPixelBufferGetWidth(depthBuffer),height = CVPixelBufferGetHeight(depthBuffer)
            guard width == CVPixelBufferGetWidth(confidenceBuffer),height == CVPixelBufferGetHeight(confidenceBuffer) else { return .unknown }
            let k = frame.camera.intrinsics,d = -Double(camera.z),resolution = frame.camera.imageResolution
            let u = (Double(k[0][0])*Double(camera.x)/d+Double(k[2][0]))*Double(width)/Double(resolution.width)
            let v = (Double(k[2][1])-Double(k[1][1])*Double(camera.y)/d)*Double(height)/Double(resolution.height)
            guard u.isFinite,v.isFinite,u >= 0,v >= 0,u < Double(width),v < Double(height) else { return .unknown }
            let x = Int(u),y = Int(v)
            let measured = depthBase.advanced(by:y*CVPixelBufferGetBytesPerRow(depthBuffer)).assumingMemoryBound(to:Float.self)[x]
            let confidence = confidenceBase.advanced(by:y*CVPixelBufferGetBytesPerRow(confidenceBuffer)).assumingMemoryBound(to:UInt8.self)[x]
            return LiDAROverlayCheck.classify(expectedDepth:d,measuredDepth:Double(measured),confidence:Int(confidence))
        }
        var dots = [LiDARPointOverlay.Dot]();dots.reserveCapacity(1500)
        func add(_ samples:[ProbePoint],transform:simd_float4x4,color:UIColor,limit:Int) {
            let step = max(1,Int(ceil(Double(samples.count)/4000)))
            for i in Swift.stride(from:0,to:samples.count,by:step) {
                let p = samples[i],world = transform*SIMD4(Float(p.x),Float(p.y),Float(p.z),1),camera = inverse*world
                guard camera.z < -0.1,simd_length(SIMD3(camera.x,camera.y,camera.z)) <= 15,
                      let screen = scene.project(SIMD3(world.x,world.y,world.z)),scene.bounds.contains(screen) else { continue }
                var dotColor = color
                if overlayDepthColors && color != .systemOrange {
                    let state = comparison(camera);summary.add(state)
                    switch state { case .aligned:dotColor = .systemGreen;case .contradicted:dotColor = .systemRed;case .occluded,.unknown:dotColor = .systemGray }
                }
                dots.append(.init(point:pointOverlay.convert(screen,from:scene),color:dotColor))
                if dots.count >= limit { break }
            }
        }
        if supplementTransform != nil {
            add(points,transform:transform,color:.systemIndigo,limit:800)
            add(Array(supplementNew.values),transform:transform,color:.systemTeal,limit:1300)
            add(diagnosticOverlayPoints,transform:transform,color:.systemOrange,limit:1500)
        } else {
            add(points,transform:transform,color:isMapping ? .systemTeal : .systemIndigo,limit:diagnosticOverlayPoints.isEmpty ? 1500 : 1200)
            if isMapping { add(diagnosticOverlayPoints,transform:matrix_identity_float4x4,color:.systemOrange,limit:1500) }
        }
        pointOverlay.isHidden = false
        let legend = overlayDepthColors ? "绿：贴合 · 红：表面前方冲突\n灰：遮挡或深度未知 · 橙：隔离帧" : (supplementTransform != nil ? "紫色原图点 · 青色本次新点 · 橙色隔离帧" : isMapping ? "青色已接受点 · 橙色最近隔离帧" : "紫色地图点 · 根据当前候选投影")
        let comparable = summary.aligned+summary.contradicted
        pointOverlay.update(dots,message:"15米内示意 · \(dots.count)/1500点\n"+legend+(overlayDepthColors ? "\n可比较 \(comparable) 点；非定位正确率" : "\n可能透过物体显示；点数不代表定位成功。"))
    }
    /// Mapping: refresh live lines every 3 s from the accepted cloud (new points only while
    /// supplementing) and compare them with the original map's lines. Review: compare the query's
    /// lines with the map's under the current candidate. Lines are drawn in map coordinates.
    private func updateStructureLines(_ frame:ARFrame) {
        let wanted = (linesVisible || usesShell) && normal && !closing && (isMapping ? phase == .collecting || phase == .idle : phase == .review)
        guard wanted else { if linesRoot != nil { linesRoot?.removeFromParent();linesRoot = nil };return }
        guard frame.timestamp-lastLinesUpdate >= 3,!linesBusy else { return }
        lastLinesUpdate = frame.timestamp;linesBusy = true
        let mapping = isMapping,supplementing = supplementTransform != nil,base = mapLines
        let queryCloud = mapping ? [] : Array(cloud.values),candidateTransform = candidate?.transform_query_to_map
        let work = { [self] () -> ([LiDARStructureLine],LiDARStructureLines.Comparison?) in
            let live:[LiDARStructureLine]
            if mapping { live = LiDARStructureLines.extract(supplementing ? mappingBudget.addedPoints : mappingBudget.points,floorY:mappingBudget.floorY) }
            else if let t = candidateTransform { live = LiDARStructureLines.extract(queryCloud).map { $0.moved(t) } }
            else { live = [] }
            let comparison = (supplementing || !mapping) && !base.isEmpty && !live.isEmpty ? LiDARStructureLines.compare(map:base,live:live) : nil
            return (live,comparison)
        }
        (mapping ? io : compute).async { [weak self] in
            let (live,comparison) = work()
            DispatchQueue.main.async {
                guard let self else { return };self.linesBusy = false
                self.liveLines = live;self.lineComparison = comparison;self.renderStructureLines()
                if let c = comparison { self.log("structure_line_check",Self.jsonFields(c)) }
            }
        }
    }
    private func renderStructureLines() {
        linesRoot?.removeFromParent();linesRoot = nil
        let anchor = AnchorEntity(world:.zero)
        let mapFromSession = isMapping ? supplementTransform : (phase == .review ? candidate?.transform_query_to_map : alignment.mapFromSession)
        if let t = mapFromSession { anchor.transform = Transform(matrix:matrixFromRows(CampusMapGeometry.inverse(t))) }
        if usesShell,!isMapping,let t = mapFromSession {
            addAlignmentGuides(to:anchor,mapFromSession:t);scene.scene.addAnchor(anchor);linesRoot = anchor;return
        }
        func add(_ lines:[LiDARStructureLine],_ color:UIColor,_ thickness:Float) {
            for l in lines.prefix(150) {
                let length = Float(l.length);guard length > 0.05 else { continue }
                let mid = SIMD3(Float((l.a.x+l.b.x)/2),Float((l.a.y+l.b.y)/2),Float((l.a.z+l.b.z)/2))
                let entity:ModelEntity
                if l.kind == "corner" { entity = ModelEntity(mesh:.generateBox(size:SIMD3(thickness,length,thickness)),materials:[UnlitMaterial(color:color)]) }
                else {
                    entity = ModelEntity(mesh:.generateBox(size:SIMD3(length,thickness,thickness)),materials:[UnlitMaterial(color:color)])
                    entity.orientation = simd_quatf(angle:-Float(atan2(l.b.z-l.a.z,l.b.x-l.a.x)),axis:SIMD3(0,1,0))
                }
                entity.position = mid+SIMD3(0,l.kind == "corner" ? 0 : 0.02,0);anchor.addChild(entity)
            }
        }
        let showMap = supplementTransform != nil || !isMapping
        if showMap { add(mapLines,.systemPurple,0.03) }
        add(liveLines,showMap ? .systemYellow : .systemTeal,0.02)
        scene.scene.addAnchor(anchor);linesRoot = anchor
    }
    /// Product alignment check: the map's wall feet as white lines with a soft blue glow and its wall
    /// corners as short glowing posts, only within 9 m, so the person can compare them with the room.
    /// (Looks, not measurement; the debug view keeps the raw purple/yellow lines.)
    private func addAlignmentGuides(to anchor:AnchorEntity,mapFromSession t:[[Double]]) {
        guard let frame = scene.session.currentFrame else { return }
        let c = CampusMapGeometry.multiply(t,matrixRows(frame.camera.transform)),here = (x:c[0][3],z:c[2][3])
        var glow = UnlitMaterial(color:WayfindingPalette.route);glow.blending = .transparent(opacity:0.35)
        var core = UnlitMaterial(color:.white);core.blending = .transparent(opacity:0.92)
        var postGlow = UnlitMaterial(color:WayfindingPalette.route);postGlow.blending = .transparent(opacity:0.22)
        let near = mapLines.filter { hypot(($0.a.x+$0.b.x)/2-here.x,($0.a.z+$0.b.z)/2-here.z) < 9 }
        for l in near.prefix(80) {
            let length = Float(l.length);guard length > 0.3 else { continue }
            if l.kind == "corner" {
                let base = SIMD3(Float(l.a.x),Float(min(l.a.y,l.b.y)),Float(l.a.z)),h:Float = 1.2
                let halo = ModelEntity(mesh:.generateBox(size:[0.09,h,0.09],cornerRadius:0.04),materials:[postGlow]);halo.position = base+[0,h/2,0]
                let post = ModelEntity(mesh:.generateBox(size:[0.028,h,0.028],cornerRadius:0.012),materials:[core]);post.position = base+[0,h/2,0]
                anchor.addChild(halo);anchor.addChild(post)
            } else {
                let mid = SIMD3(Float((l.a.x+l.b.x)/2),Float((l.a.y+l.b.y)/2)+0.02,Float((l.a.z+l.b.z)/2))
                let turn = simd_quatf(angle:-Float(atan2(l.b.z-l.a.z,l.b.x-l.a.x)),axis:[0,1,0])
                let halo = ModelEntity(mesh:.generateBox(size:[length,0.006,0.11],cornerRadius:0.003),materials:[glow]);halo.position = mid;halo.orientation = turn
                let line = ModelEntity(mesh:.generateBox(size:[length,0.012,0.032],cornerRadius:0.006),materials:[core]);line.position = mid+[0,0.004,0];line.orientation = turn
                anchor.addChild(halo);anchor.addChild(line)
            }
        }
    }
    /// Shown while collecting until the person turns (> 15°/s for 0.6 s); shown again after 2.5 s
    /// without turning while still collecting. Only in the product view.
    private func updateTurnGuide(_ frame:ARFrame) {
        guard usesShell,phase == .collecting,plateToken == nil else { if turnGuide.shown { turnGuide.setVisible(false) };lastYaw = nil;turningSince = nil;stillSince = nil;return }
        let f = frame.camera.transform.columns.2,yaw = atan2(-f.x,-f.z),t = frame.timestamp
        if let last = lastYaw,t > last.t {
            let d = abs(remainderf(yaw-last.yaw,2 * .pi))*180 / .pi,rate = Double(d)/(t-last.t)
            yawRate = yawRate*0.85+rate*0.15
        }
        lastYaw = (yaw,t)
        if yawRate > 15 { stillSince = nil;turningSince = turningSince ?? t;if t-(turningSince ?? t) > 0.6,turnGuide.shown { turnGuide.setVisible(false) } }
        else if yawRate < 5 { turningSince = nil;stillSince = stillSince ?? t;if t-(stillSince ?? t) > 2.5,!turnGuide.shown { turnGuide.setVisible(true) } }
        if frames == 0 && !turnGuide.shown && turningSince == nil { turnGuide.setVisible(true) }
    }
    /// The current leg ends at a bound elevator: within 25 m (or on arrival) show the call card and
    /// connect; it stays grey until the board is ready. Leaves when the leg or plan changes.
    /// "我已到达 3F" at an elevator or stairs (the shell's action).
    private var arrivedTitle:String { "我已到达"+(crossMap?.plan.map { $0.legs.count >= 2 ? label($0.legs[1].map_id) : "" } ?? "") }
    private func updateElevator() {
        guard usesShell,phase == .navigation,ElevatorCallMode.current != .off,let cross = crossMap,let plan = cross.plan,let leg = plan.legs.first,let link = leg.link,link.kind == .elevator,
              let map else { stopElevator();return }
        // While the route is being re-planned there is no guide for a moment: keep what is shown.
        guard let g = guide else { return }
        let near = transitionReady || g.remaining <= (elevatorLinkID == nil ? 25 : 35)
        guard near else { stopElevator();return }
        if elevatorLinkID != link.id {
            stopElevator()
            var placements = [String:LiDARMapPlacement]()
            for (id,url) in cross.directories { if case .placed(let p) = LiDARMapPlacement.load(url,mapID:id) { placements[id] = p } }
            let catalog = (try? LiDARCampusCatalog.load(root:LiDARLibrary.root)) ?? LiDARCampusCatalog()
            let bindings = (try? LiDARCampusBindings.load(root:LiDARLibrary.root)) ?? LiDARCampusBindings()
            let traversal:ElevatorTraversal = link.a.map_id == map.map_id ? .aToB : .bToA
            elevatorLinkID = link.id
            guard let target = ElevatorCallPlanning.target(for:link,traversal:traversal,placements:placements,catalog:catalog,bindings:bindings) else {
                log("elevator_call_unavailable",["link_id":link.id,"group_id":link.group_id ?? ""]);return
            }
            elevatorTarget = target
            let service = ElevatorBLEService();elevatorService = service
            let name = map.nodes.first { $0.id == leg.target_node_id }?.name ?? "电梯"
            // The building's floors for the page: your floor (call floor) and the elevator leg's arrival floor.
            let floors = catalog.building(target.device.building_id)?.sortedFloors ?? []
            let arrival = placements[traversal == .aToB ? link.b.map_id : link.a.map_id]?.floor_id
            elevatorFloors = (floors.map { f in .init(name:f.name,hasDevice:bindings.device(group:target.groupID,floor:f.id) != nil) },
                              floors.firstIndex { $0.id == target.floorID },arrival.flatMap { a in floors.firstIndex { $0.id == a } },name)
            service.onState = { [weak self] state in
                guard let self,let target = self.elevatorTarget else { return }
                self.elevatorCard.update(.init(elevatorName:name,carFloor:nil,direction:target.direction,phase:state.phase,canCall:state.canCall))
                self.elevatorCard.setVisible(ElevatorCallMode.current.showsCard(state.phase))
                self.updateElevatorPanel()
                self.log("elevator_state",["phase":state.phase.rawValue,"reason":state.reason ?? ""])
            }
            elevatorCard.update(.init(elevatorName:name,carFloor:nil,direction:target.direction,phase:.discovering,canCall:false))
            service.start(target:target,planRevision:planRevision);elevatorCard.setVisible(ElevatorCallMode.current.showsCard(.discovering))
            log("elevator_call_shown",["link_id":link.id,"device":target.device.peripheral_name,"direction":target.direction.rawValue])
        }
    }
    private func stopElevator() {
        guard elevatorService != nil || elevatorLinkID != nil else { return }
        elevatorService?.stop();elevatorService = nil;elevatorTarget = nil;elevatorLinkID = nil;elevatorCard.setVisible(false);elevatorPanel.setVisible(false)
    }
    private func callElevator() {
        guard let service = elevatorService,let target = elevatorTarget else { return }
        let sent = service.call(direction:target.direction,context:target.context(planRevision:planRevision))
        log("elevator_call_pressed",["sent":sent,"direction":target.direction.rawValue])
    }
    private func elevatorDetails() {
        guard elevatorTarget != nil else { return }
        updateElevatorPanel();elevatorPanel.setVisible(true)
    }
    private func updateElevatorPanel() {
        guard let target = elevatorTarget else { return }
        let state = elevatorService?.state,f = elevatorFloors
        elevatorPanel.update(.init(elevatorName:f.name,floors:f.floors,current:f.current,destination:f.destination,direction:target.direction,
                                   phase:state?.phase ?? .discovering,canCall:state?.canCall ?? false,deviceName:target.device.peripheral_name))
    }
    private var lineCheckText:String? {
        guard let c = lineComparison else { return nil }
        guard c.matched >= 2,let off = c.median_offset_m,let ang = c.median_angle_deg else { return "墙角线：可比较的线不足（\(c.matched)/\(c.compared)）" }
        return String(format:"墙角线：%d/%d 条对上，偏差 %.0f 厘米 / %.1f°（紫=原图，黄=当前）",c.matched,c.compared,off*100,ang)
    }
    private func showCurrentDistribution() {
        guard isMapping,let writer else { return }
        let editor = routeEditor
        io.async { [self] in
            let points = mappingBudget.runtimePoints(limit:18_000),snapshot = mappingBudget.snapshot()
            // Live compass coverage: this session's readings (moved into the map while supplementing) plus the map's own.
            var magnetic = magneticReference
            if let recorder,let log = try? recorder.snapshotLog("magnetic-heading.jsonl") {
                var samples = LiDARMagnetic.samples(jsonl:log,sessionID:sessionID)
                if let t = supplementTransform { samples = LiDARMagnetic.moved(samples,by:t) }
                let live = LiDARMagnetic.reference(samples)
                magnetic = magnetic.map { $0.merged(with:live) } ?? (live.cells.isEmpty ? nil : live)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self,!closing else { return }
                var data = LiDARDistributionData(title:name,source:.liveCapture,points:points,nodes:editor.nodes,edges:editor.edges,connectFrom:editor.connectFrom,budget:snapshot)
                data.magnetic = magnetic
                let panel = UINavigationController(rootViewController:LiDARDistributionController(data:data))
                present(panel,animated:true);log("distribution_snapshot_opened",["scan_id":writer.manifest.scan_id])
            }
        }
    }
    private func exportCurrentScan() {
        guard let writer else { return }
        io.async { [self] in
            let result = Result { () -> URL in
                try ProbeIO.makeManifest(at:writer.directory)
                let output = ProbeIO.documents.appendingPathComponent("Exports/diagnostic-"+writer.manifest.scan_id+".zip")
                try ProbeZip.create(directory:writer.directory,destination:output);return output
            }
            DispatchQueue.main.async { [weak self] in
                guard let self,!closing else { return };switch result { case .success(let url):campusShare(url);case .failure(let error):campusError(error) }
            }
        }
    }
    @objc private func startPlate() {
        guard plateToken == nil,normal,![.solving,.suspended,.finished].contains(phase),
              !isMapping || (phase == .collecting && writer != nil && !geometryUncertain && !diagnosticSegment && !thermalGate.paused) else { return }
        guard isMapping || [.idle,.review,.navigation].contains(phase) else { return }
        guard ProcessInfo.processInfo.thermalState.rawValue < 3 else { campusMessage("请先降温","设备温度较高，稍后再采集门牌。");return }
        guard view.window?.windowScene?.interfaceOrientation == .portrait else { campusMessage("请竖屏采集","竖持手机，靠近到约1–1.5米，正对门牌并拿稳。");return }
        let alert = UIAlertController(title:isMapping ? "标记门牌" : "扫门牌辅助",message:"靠近到约1–1.5米，正对门牌，保持竖屏。点击开始后拿稳约1秒，再核对识别文字。导航位置不会自动改变。",preferredStyle:.alert)
        alert.addAction(UIAlertAction(title:"取消",style:.cancel))
        alert.addAction(UIAlertAction(title:"开始采集",style:.default) { [weak self] _ in
            guard let self,self.normal else { return }
            if self.isMapping { self.beginPlateWithDepth() } else { self.requestDepth(for:.plate) }
        });present(alert,animated:true)
    }
    private func beginPlateWithDepth() {
        guard normal,hasDepth,plateToken == nil,!closing else { synchronizeDepth(reason:"plate_not_ready");return }
        let token = UUID();plateToken = token;platePackets = [];plateCollecting = true;plateLastFrame = -Double.infinity
        status.text = "门牌采集中 · 请拿稳";log("plate_capture_started",["plate_capture_id":token.uuidString]);refresh()
        DispatchQueue.main.asyncAfter(deadline:.now()+2) { [weak self] in
            guard let self,self.plateToken == token,self.plateCollecting else { return }
            self.cancelPlate("未获得3帧合格深度，请拿稳后重试")
        }
    }
    private func cancelPlate(_ reason:String) {
        entranceDraft = nil;entranceChecking = false;entranceMarker?.removeFromParent();entranceMarker = nil
        plateToken = nil;plateCollecting = false;platePackets = [];status.text = reason;log("plate_capture_cancelled",["reason":reason]);refresh()
    }
    private func feedPlate(_ frame:ARFrame) {
        guard ProcessInfo.processInfo.thermalState.rawValue < 3 else { cancelPlate("设备温度较高，门牌采集已取消，请先降温");return }
        guard normal,view.window?.windowScene?.interfaceOrientation == .portrait else { cancelPlate("跟踪或屏幕方向变化，门牌采集已取消");return }
        guard frame.timestamp-plateLastFrame >= 0.28,let depth = frame.sceneDepth,let conf = depth.confidenceMap else { return }
        let c = LiDARCalibration(width:CVPixelBufferGetWidth(depth.depthMap),height:CVPixelBufferGetHeight(depth.depthMap),imageWidth:CVPixelBufferGetWidth(frame.capturedImage),imageHeight:CVPixelBufferGetHeight(frame.capturedImage),fx:Double(frame.camera.intrinsics[0][0]),fy:Double(frame.camera.intrinsics[1][1]),cx:Double(frame.camera.intrinsics[2][0]),cy:Double(frame.camera.intrinsics[2][1]))
        let metadata = LiDARFrame(index:platePackets.count,timestamp:frame.timestamp,transform:isMapping ? toMapPose(matrixRows(frame.camera.transform)) : matrixRows(frame.camera.transform),calibration:c,validFraction:0)
        platePackets.append(PlatePacket(frame:metadata,image:frame.capturedImage,depth:depth.depthMap,confidence:conf));plateLastFrame = frame.timestamp
        status.text = "门牌采集中 · \(platePackets.count)/3"
        if platePackets.count == 3 { plateCollecting = false;processPlate() }
    }
    private func processPlate() {
        guard let token = plateToken else { return }
        let packets = platePackets,sid = sessionID,coordinateGeneration = arSessionGeneration
        platePackets = [];status.text = "正在本机识别门牌…"
        io.async { [self] in
            let outcome = Result { () -> [PlateObservation] in
                var observations = [PlateObservation]()
                for packet in packets {
                    guard ProcessInfo.processInfo.thermalState.rawValue < 3 else { throw LiDARScanError.invalid("设备温度较高，请降温后再试") }
                    let depth = try Self.pack(packet.depth,format:kCVPixelFormatType_DepthFloat32,bytesPerPixel:4)
                    let confidence = try Self.pack(packet.confidence,format:kCVPixelFormatType_OneComponent8,bytesPerPixel:1)
                    var frame = packet.frame
                    let points = try LiDARGeometry.observations(depth:depth,confidence:confidence,frame:frame,pixelStride:8)
                    let count = ((frame.calibration.width+7)/8)*((frame.calibration.height+7)/8)
                    frame.valid_fraction = Double(points.count)/Double(count)
                    guard frame.valid_fraction >= 0.05 else { continue }
                    let ci = CIImage(cvPixelBuffer:packet.image)
                    guard let image = context.createCGImage(ci,from:ci.extent),let jpeg = context.jpegRepresentation(of:ci,colorSpace:CGColorSpaceCreateDeviceRGB(),options:[kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption:0.9]) else { throw LiDARScanError.invalid("无法保存门牌照片") }
                    let text = try LiDAROCR.recognize(image,orientation:.right)
                    observations.append(PlateObservation(frame:frame,jpeg:jpeg,depth:depth,confidence:confidence,image:image,text:text))
                }
                guard observations.count >= 3 else { throw LiDARScanError.invalid("合格帧不足3张，请拿稳并避开玻璃反光") }
                return observations
            }
            DispatchQueue.main.async { [self] in
                guard plateToken == token,sid == sessionID,coordinateGeneration == arSessionGeneration,!closing else { return }
                switch outcome {
                case .failure(let error):cancelPlate(error.localizedDescription)
                case .success(let observations):
                    guard normal else { cancelPlate("跟踪发生变化，请重新采集门牌");return }
                    let choices = observations[0].text.sorted { a,b in
                        func priority(_ o:LiDARTextObservation) -> Double { let b = o.vision_box;return hypot(b[0]+b[2]/2-0.5,b[1]+b[3]/2-0.5)-(LiDARText.looksLikeRoomNumber(o.text) ? 0.15 : 0) }
                        return priority(a) < priority(b)
                    }
                    if choices.isEmpty { reviewPlate(observations,selection:nil,token:token,session:sid,coordinateGeneration:coordinateGeneration) }
                    else {
                        let alert = UIAlertController(title:"选择要记录的门牌文字",message:"核对截图和文字，编号相近时务必检查。",preferredStyle:.actionSheet)
                        for choice in choices.prefix(12) {
                            alert.addAction(UIAlertAction(title:choice.text,style:.default) { [weak self] _ in self?.reviewPlate(observations,selection:choice,token:token,session:sid,coordinateGeneration:coordinateGeneration) })
                        }
                        alert.addAction(UIAlertAction(title:"手动输入（无三维测量）",style:.default) { [weak self] _ in self?.reviewPlate(observations,selection:nil,token:token,session:sid,coordinateGeneration:coordinateGeneration) })
                        alert.addAction(UIAlertAction(title:"放弃本次门牌",style:.cancel) { [weak self] _ in self?.cancelPlate("本次门牌未记录") })
                        alert.popoverPresentationController?.sourceView = view;alert.popoverPresentationController?.sourceRect = CGRect(x:view.bounds.midX,y:view.bounds.midY,width:1,height:1)
                        present(alert,animated:true)
                    }
                }
            }
        }
    }
    private func reviewPlate(_ observations:[PlateObservation],selection:LiDARTextObservation?,token:UUID,session:String,coordinateGeneration:Int) {
        guard plateToken == token,session == sessionID,coordinateGeneration == arSessionGeneration else { return }
        let id = UUID().uuidString
        var samples = [LiDARLandmarkSample](),evidence = [LiDARLandmarkEvidence](),files = [String:Data]()
        var preview:UIImage?,bestCrop:String?
        for (i,observation) in observations.enumerated() {
            let text = i == 0 ? selection : observation.text.first { LiDARText.normalize($0.text) == LiDARText.normalize(selection?.text ?? "") }
            let c = observation.frame.calibration
            let box = text.map { LiDARLandmarkGeometry.nativeBox(visionBox:$0.vision_box,imageWidth:c.image_width,imageHeight:c.image_height) } ?? [0,0,Double(c.image_width),Double(c.image_height)]
            if text != nil { samples.append(LiDARLandmarkSample(frame:observation.frame,depth:observation.depth,confidence:observation.confidence,nativeBox:box)) }
            // A later frame without the selected text is not evidence for this plate: omit it
            // rather than store a whole-image box that would look like a plate box.
            if i > 0 && text == nil { continue }
            let base = "landmarks/\(id)/\(i)"
            files[base+".jpg"] = observation.jpeg;files[base+".f32"] = observation.depth;files[base+".u8"] = observation.confidence
            evidence.append(LiDARLandmarkEvidence(timestamp:observation.frame.timestamp,session_id:session,generation:coordinateGeneration,camera_to_session:observation.frame.camera_to_session,calibration:c,image_file:base+".jpg",depth_file:base+".f32",confidence_file:base+".u8",native_box:box,box_source:text == nil ? "none_full_image" : "ocr_selection"))
            if isMapping && supplementTransform != nil { evidence[evidence.count-1].pose_frame = "map" }
            if i == 0 {
                let rect = CGRect(x:box[0],y:box[1],width:box[2],height:box[3]).integral.intersection(CGRect(x:0,y:0,width:c.image_width,height:c.image_height))
                if !rect.isEmpty,let crop = observation.image.cropping(to:rect) {
                    preview = UIImage(cgImage:crop,scale:1,orientation:.right)
                    bestCrop = "landmarks/\(id)/crop.jpg"
                    let size = CGSize(width:crop.height,height:crop.width)
                    let upright = UIGraphicsImageRenderer(size:size).image { _ in UIImage(cgImage:crop,scale:1,orientation:.right).draw(in:CGRect(origin:.zero,size:size)) }
                    files[bestCrop!] = upright.jpegData(compressionQuality:0.9)
                } else { preview = UIImage(cgImage:observation.image,scale:1,orientation:.right) }
            }
        }
        let geometry = LiDARLandmarkGeometry.measure(samples)
        let note = geometry.status == "measured" ? String(format:"多帧三维测量：%d帧一致，离散 %.1f cm（不是绝对精度）。",geometry.observations,(geometry.spread_m ?? 0)*100) : "三维位置未知：\(geometry.reason)。仍可记录文字；不会显示三维位置。"
        let review = LiDARPlateReviewController(image:preview,recognized:selection?.text ?? "",candidates:selection?.candidates.map(\.text) ?? [],measurement:note,queryOnly:!isMapping) { [weak self] input in
            guard let self,self.plateToken == token else { return }
            guard let input else { self.cancelPlate("门牌未保存");return }
            guard self.normal,session == self.sessionID,coordinateGeneration == self.arSessionGeneration,
                  !self.closing,!self.isMapping || (!self.geometryUncertain && !self.diagnosticSegment && self.phase == .collecting) else { self.cancelPlate("坐标已失效，请重新采集门牌");return }
            var landmark = LiDARLandmark(id:id,category:input.category == "room_plate" ? .room_plate : .reference_feature,trigger:.manual,
                text:LiDARLandmarkText(raw:input.text,candidates:selection?.candidates ?? [],confirmedByUser:true,edited:input.text != selection?.text),
                destination:LiDARLandmarkDestination(enabled:false,node_id:nil),geometry:geometry,evidence:evidence,best_crop:bestCrop)
            landmark.mount = input.mount
            if input.name != input.text { landmark.display_name = input.name }
            if input.setEntrance { self.beginEntrance(name:input.name,landmark:landmark,files:files,token:token) }
            else { self.persistPlate(landmark,files:files,token:token) }
        }
        let nav = UINavigationController(rootViewController:review);nav.isModalInPresentation = true;present(nav,animated:true)
    }
    private func persistPlate(_ landmark:LiDARLandmark,files:[String:Data],token:UUID,entranceEditor:LiDARRouteEditor? = nil) {
        if isMapping {
            guard let writer else { cancelPlate("尚未开始建图");return }
            let sid = sessionID,coordinateGeneration = arSessionGeneration
            let records = plateRecords+[landmark],map = (entranceEditor ?? routeEditor).map(mapID:writer.manifest.scan_id,sessionID:sessionID,name:name,pointCount:budgetSnapshot?.voxels ?? cloud.count,voxel:0.10)
            let set = LiDARLandmarkSet(mapID:map.map_id,geometrySHA256:nil,landmarks:records)
            io.async { [self] in
                let outcome = Result { () -> Void in
                    try set.validate(against:map)
                    let count = files.values.reduce(0) { $0+$1.count }
                    guard writer.rawBytes+manualEvidenceBytes+count <= LiDARScanLimits.rawBytesV2 else { throw LiDARScanError.invalid("门牌照片会超出本图空间预算，请先保存地图") }
                    for (path,bytes) in files { let url = writer.directory.appendingPathComponent(path);try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true);try bytes.write(to:url,options:.atomic) }
                    // A draft checkpoint is never loaded as published map landmarks. The final map
                    // writes landmarks.json from the accepted in-memory records only.
                    try LiDARNavigationStore.write(set,to:writer.directory.appendingPathComponent("landmarks-draft.json"))
                    manualEvidenceBytes += count
                }
                let storageBytes = writer.rawBytes+manualEvidenceBytes
                DispatchQueue.main.async { [self] in
                    guard plateToken == token,!closing else { return }
                    switch outcome {
                    case .success:
                        guard normal,sid == sessionID,coordinateGeneration == arSessionGeneration,phase == .collecting,!geometryUncertain,!diagnosticSegment else {
                            cancelPlate("坐标已变化，入口未采用；请重新采集本次门牌");return
                        }
                        if let entranceEditor { routeEditor = entranceEditor }
                        plateRecords = records;syncRouteEditor();plateToken = nil;rawBytesRecorded = storageBytes
                        status.text = "已记录门牌 · \(landmark.text.raw)";log("plate_saved",["landmark_id":landmark.id,"text":landmark.text.raw,"entrance_node_id":landmark.destination.node_id ?? "none","geometry_status":landmark.geometry.status,"automatic_localization_changed":false]);refresh()
                    case .failure(let error):cancelPlate(error.localizedDescription)
                    }
                }
            }
        } else {
            guard let recorder else { cancelPlate("诊断记录器不可用");return }
            var attachments = files
            let ranked = knownPlates.map { (plate:$0,score:LiDARText.similarity(landmark.text.raw,$0.text.raw)) }.filter { $0.score >= 0.65 }.sorted { $0.score > $1.score }
            let report:[String:Any] = ["kind":"manual_plate_query","map_id":map?.map_id ?? "unknown","ar_session_id":sessionID,"generation":arSessionGeneration,
                "coordinate_system":"query_session_not_map","automatic_localization_changed":false,"landmark":Self.jsonFields(landmark),
                "text_matches":ranked.prefix(5).map { ["landmark_id":$0.plate.id,"text":$0.plate.text.raw,"text_similarity":$0.score] as [String:Any] }]
            do { attachments["landmarks/\(landmark.id)/observation.json"] = try ProbeIO.json(report,pretty:true) } catch { cancelPlate(error.localizedDescription);return }
            recorder.writeLandmarkFiles(attachments) { [weak self] outcome in
                guard let self,self.plateToken == token,!self.closing else { return }
                switch outcome {
                case .success:
                    self.plateToken = nil;self.status.text = "门牌辅助已记录 · 当前定位未改变"
                    self.log("plate_query_saved",["landmark_id":landmark.id,"text":landmark.text.raw,"automatic_localization_changed":false]);self.refresh()
                    var texts = [String]()
                    for r in ranked.prefix(5) where !texts.contains(where:{ LiDARText.normalize($0) == LiDARText.normalize(r.plate.text.raw) }) { texts.append(r.plate.text.raw) }
                    guard !texts.isEmpty,self.map != nil,!self.isMapping else {
                        self.campusMessage("门牌辅助（仅记录）","读取：\(landmark.text.raw)\n没有匹配记录。当前导航位置未改变。");return
                    }
                    var choices:[(String,() -> Void)] = texts.map { text in ("用「\(text)」定位",{ [weak self] in self?.beginPlateSearch(text,query:landmark) }) }
                    choices.append(("仅记录，不定位",{}))
                    self.campusChoices("门牌辅助",message:"读取：\(landmark.text.raw)\n选择正确的房间后，会在该房间每个入口附近分别搜索；结果仍需现场确认。",choices:choices)
                case .failure(let error):self.cancelPlate(error.localizedDescription)
                }
            }
        }
    }
    private func presentPlateList() {
        present(UINavigationController(rootViewController:LiDARPlateListController(landmarks:plateRecords,nodes:nodes)),animated:true)
    }
    private func startPathDraft() {
        guard isMapping,normal,phase == .collecting,plateToken == nil,entranceDraft == nil,!geometryUncertain,!diagnosticSegment else { return }
        pathDraft = [];log("suggested_path_started");refresh()
    }
    private func addPathPoint() {
        guard var draft = pathDraft,normal,phase == .collecting else { return }
        let screen = scene.convert(reticle.center,from:view)
        let hit = scene.raycast(from:screen,allowing:.existingPlaneGeometry,alignment:.horizontal).first
            ?? scene.raycast(from:screen,allowing:.estimatedPlane,alignment:.horizontal).first
        guard let hit,let frame = scene.session.currentFrame,simd_distance(hit.worldTransform.columns.3,frame.camera.transform.columns.3) < 6 else {
            campusMessage("未找到地面","把＋对准通道地面后再加点。");return
        }
        let c = hit.worldTransform.columns.3,point = toMap(ProbePoint(Double(c.x),Double(c.y),Double(c.z)))
        if let last = draft.last,hypot(last.x-point.x,last.z-point.z) < 0.3 { campusMessage("离上一个点太近","两个路径点至少相隔 0.3 米。");return }
        draft.append(point);pathDraft = draft;renderPaths();refresh()
    }
    private func finishPathDraft() {
        guard let draft = pathDraft,draft.count >= 2 else { return }
        let path = LiDARSuggestedPath(points:draft.map { [$0.x,$0.z] },source:"phone")
        phonePaths.append(path);pathDraft = nil
        log("suggested_path_added",["path_id":path.id,"points":path.points,"length_m":zip(draft,draft.dropFirst()).reduce(0) { $0+hypot($1.1.x-$1.0.x,$1.1.z-$1.0.z) }])
        status.text = "已加入建议通行路径";renderPaths();refresh()
    }
    /// Suggested paths in AR: the map's existing ones, this session's, and the draft (map coordinates).
    private func renderPaths() {
        pathsRoot?.removeFromParent();pathsRoot = nil
        guard isMapping else { return }
        let anchor = AnchorEntity(world:.zero)
        if let t = supplementTransform { anchor.transform = Transform(matrix:matrixFromRows(CampusMapGeometry.inverse(t))) }
        let floor = Float(budgetSnapshot?.floor_y ?? nodes.first?.position.y ?? -1.5)+0.03
        func add(_ points:[[Double]],_ color:UIColor) {
            let v = points.map { SIMD3(Float($0[0]),floor,Float($0[1])) }
            if v.count >= 2,let line = try? RouteRenderer.network(points:v,color:color,arrows:false) { anchor.addChild(line) }
        }
        for p in existingCalibration?.suggested_paths ?? [] { add(p.points,.systemOrange) }
        for p in phonePaths { add(p.points,.systemOrange) }
        if let draft = pathDraft { add(draft.map { [$0.x,$0.z] },.systemYellow) }
        scene.scene.addAnchor(anchor);pathsRoot = anchor
    }
    private func startManualRoom() {
        guard isMapping,normal,phase == .collecting,plateToken == nil,!working,!geometryUncertain,!diagnosticSegment,!thermalGate.paused else { return }
        guard routeEditor.spaceMode || !edges.isEmpty else { campusMessage("请先建立路线","先标出两个路点并连接，再给房间设置入口。");return }
        let token = UUID(),sid = sessionID,coordinateGeneration = arSessionGeneration
        plateToken = token;refresh()
        let names = nodes.filter { $0.resolvedKind == .room }.map(\.name)
        let panel = LiDARRoomNamingController(names:names) { [weak self] name in
            guard let self,self.plateToken == token else { return }
            guard let name else { self.cancelPlate("已取消添加房间");return }
            guard self.normal,self.sessionID == sid,self.arSessionGeneration == coordinateGeneration else { self.cancelPlate("坐标失效，请重新添加房间");return }
            self.beginEntrance(name:name,landmark:nil,files:[:],token:token)
            self.placeEntranceAtReticle()
        }
        present(UINavigationController(rootViewController:panel),animated:true)
    }
    private func beginEntrance(name:String,landmark:LiDARLandmark?,files:[String:Data],token:UUID) {
        guard isMapping,normal,phase == .collecting,plateToken == token,!geometryUncertain,!diagnosticSegment else { cancelPlate("当前无法设置入口，请重新采集");return }
        let floor = budgetSnapshot?.floor_y ?? nodes.first?.position.y ?? LiDARSampling.floorHeight(Array(cloud.values))
        let suggestion = landmark.flatMap { $0.mount == .door ? nil : LiDARLandmarkGeometry.suggestedEntrance($0.geometry,floorY:floor) }
        entranceDraft = EntranceDraft(name:name,token:token,session:sessionID,coordinateGeneration:arSessionGeneration,landmark:landmark,files:files,position:suggestion,capture:scene.session.currentFrame.map(entranceCapture))
        renderEntrance();refresh();log("entrance_selection_started",["name":name,"from_plate":landmark != nil,"has_suggestion":suggestion != nil])
    }
    private func entranceCapture(_ frame:ARFrame) -> LiDARNodeCaptureContext {
        LiDARNodeCaptureContext(timestamp:frame.timestamp,session_id:sessionID,generation:arSessionGeneration,camera_to_session:matrixRows(frame.camera.transform))
    }
    private func placeEntranceAtReticle() {
        guard var draft = entranceDraft,!entranceChecking,normal,phase == .collecting,!geometryUncertain,!diagnosticSegment,!thermalGate.paused else { return }
        let screen = scene.convert(reticle.center,from:view)
        let hit = scene.raycast(from:screen,allowing:.existingPlaneGeometry,alignment:.horizontal).first
            ?? scene.raycast(from:screen,allowing:.estimatedPlane,alignment:.horizontal).first
        guard let hit,let frame = scene.session.currentFrame,simd_distance(hit.worldTransform.columns.3,frame.camera.transform.columns.3) < 4.5 else { campusMessage("未找到近处地面","把＋对准走廊一侧的门口地面，观察地面后重试。");return }
        let p = hit.worldTransform.columns.3,point = toMap(ProbePoint(Double(p.x),Double(p.y),Double(p.z)))
        let floor = budgetSnapshot?.floor_y ?? nodes.first?.position.y ?? LiDARSampling.floorHeight(Array(cloud.values))
        guard abs(point.y-floor) < 0.30,cloud.values.contains(where:{ abs($0.x-point.x) < 0.8 && abs($0.z-point.z) < 0.8 && abs($0.y-point.y) < 0.35 }) else { campusMessage("请选择已扫到的门口地面","入口应在走廊一侧的地面，不能标在门板、墙面或桌面上。可暂不设置，先扫描门口再重新采集门牌。");return }
        draft.position = point;draft.capture = entranceCapture(frame);entranceDraft = draft;renderEntrance();refresh()
    }
    private func renderEntrance() {
        entranceMarker?.removeFromParent();entranceMarker = nil
        guard let point = entranceDraft?.position else { return }
        let anchor = AnchorEntity(world:.zero)
        if let t = supplementTransform { anchor.transform = Transform(matrix:matrixFromRows(CampusMapGeometry.inverse(t))) }
        let marker = ModelEntity(mesh:.generateSphere(radius:0.18),materials:[UnlitMaterial(color:.systemTeal)])
        marker.scale.y = 0.08;marker.position = SIMD3(Float(point.x),Float(point.y)+0.04,Float(point.z));anchor.addChild(marker)
        if let join = routeEditor.nearestJoin(point),join.distance > 0.05 {
            let a = SIMD3(Float(point.x),Float(point.y)+0.02,Float(point.z)),b = SIMD3(Float(join.point.x),Float(join.point.y)+0.02,Float(join.point.z))
            if let line = try? RouteRenderer.returnBearing(points:[a,b],target:b) { anchor.addChild(line) }
        }
        scene.scene.addAnchor(anchor);entranceMarker = anchor
    }
    private func entranceIsCurrent(_ draft:EntranceDraft) -> Bool {
        plateToken == draft.token && entranceDraft?.token == draft.token && draft.session == sessionID && draft.coordinateGeneration == arSessionGeneration && normal && phase == .collecting && !geometryUncertain && !diagnosticSegment && !closing
    }
    private func adoptEntrance() {
        guard let draft = entranceDraft,let point = draft.position,entranceIsCurrent(draft),!entranceChecking,!thermalGate.paused else { return }
        // Prepare on a value copy. Nothing is committed until the user has accepted any warning.
        let before = routeEditor
        var edited = before
        do {
            let result = try edited.addEntrance(name:draft.name,position:point,capture:draft.capture)
            let ready = edited
            entranceChecking = true;refresh()
            io.async { [self] in
                let crosses = mappingBudget.crossesStructure(from:point,to:result.attachment.join)
                DispatchQueue.main.async { [self] in
                    guard entranceIsCurrent(draft) else { entranceChecking = false;cancelPlate("入口坐标已失效，请重新设置");return }
                    entranceChecking = false
                    let commit = { [weak self] in
                        guard let self,self.entranceIsCurrent(draft),!self.thermalGate.paused else { return }
                        self.entranceDraft = nil;self.entranceMarker?.removeFromParent();self.entranceMarker = nil
                        self.log("room_entrance_added",["node_id":result.node.id,"name":draft.name,"join_node_id":result.attachment.joinedNodeID,"join_distance_m":result.attachment.distance_m,"possible_structure_crossing":crosses,"from_plate":draft.landmark != nil])
                        if var plate = draft.landmark {
                            plate.destination = LiDARLandmarkDestination(enabled:true,node_id:result.node.id)
                            self.persistPlate(plate,files:draft.files,token:draft.token,entranceEditor:ready)
                        } else { self.routeEditor = ready;self.syncRouteEditor();self.plateToken = nil;self.status.text = "已添加房间入口 · \(draft.name)";self.refresh() }
                    }
                    if crosses {
                        let alert = UIAlertController(title:"接入线可能穿墙",message:"入口到路网的连线经过已扫描的结构。这只是警告，未检测到墙也不代表可以通行。请核对入口是否在走廊一侧。",preferredStyle:.alert)
                        alert.addAction(UIAlertAction(title:"返回重新选点",style:.cancel) { [weak self] _ in self?.refresh() })
                        alert.addAction(UIAlertAction(title:"已核对，仍采用",style:.default) { _ in commit() })
                        present(alert,animated:true)
                    } else { commit() }
                }
            }
        } catch { campusError(error);refresh() }
    }
    private func skipEntrance() {
        guard let draft = entranceDraft,!entranceChecking else { return }
        entranceDraft = nil;entranceMarker?.removeFromParent();entranceMarker = nil
        if let landmark = draft.landmark {
            guard draft.session == sessionID,draft.coordinateGeneration == arSessionGeneration,normal else { cancelPlate("坐标已失效，请重新采集门牌");return }
            persistPlate(landmark,files:draft.files,token:draft.token)
        } else { cancelPlate("已取消添加房间") }
    }
    private func chooseNode(_ title:String,done:@escaping (LiDARRouteNode) -> Void) { campusChoices(title,choices:nodes.map { node in (node.name,{ done(node) }) }) }
    private func suspend(_ message:String) {
        guard phase != .suspended,phase != .finished else { return }
        pendingMark?.invalid = true
        plateToken = nil;plateCollecting = false;platePackets = []
        entranceDraft = nil;entranceChecking = false;entranceMarker?.removeFromParent();entranceMarker = nil
        headingManager.stopUpdatingHeading();motionManager.stopDeviceMotionUpdates()
        depthGate.cancel();depthAction = nil;depthRequestID = nil;depthTimeout?.cancel()
        clearConfirmedReference("tracking_invalidated");plateSearch = nil
        let wasCollecting = phase == .collecting
        cancellation.cancel();generation += 1;phase = .suspended;root?.isEnabled = false;alignment.reset(sessionID:sessionID)
        status.text = message;detail.text = isMapping ? "本次地图会话已中断，请结束并重新建图；可在工具中保存已接受的部分或导出原始记录。" : "旧定位已失效，点击重启会话。";refresh();log("session_invalidated",["reason":message])
        if wasCollecting,let writer { io.async { _ = try? writer.finish(reason:"session_invalidated",valid:false) } }
    }
    @objc private func background() {
        // Parked at the elevator or stairs: the camera is already off and the next floor starts fresh.
        if parkedAtTransfer { return }
        suspend("应用进入后台，旧坐标已停用")
    }
    func sessionWasInterrupted(_ session:ARSession) { suspend("AR 会话中断，旧坐标已停用") }
    func session(_ session:ARSession,didFailWithError error:Error) { suspend(error.localizedDescription) }
    @objc private func close() {
        if depthAction != nil { cancelDepthRequest("深度请求已取消") }
        guard !closing,!(isMapping && phase == .solving) else { return }
        if plateToken != nil { cancelPlate("门牌采集已取消") }
        if isMapping && phase != .finished && (routeEditor.dirty || frames > 0) {
            let alert = UIAlertController(title:"结束本次建图？",message:"未保存的路线不会作为导航地图。原始采集记录会保留。",preferredStyle:.alert)
            alert.addAction(UIAlertAction(title:"继续建图",style:.cancel));alert.addAction(UIAlertAction(title:"结束",style:.destructive) { [weak self] _ in self?.finishAndClose() });present(alert,animated:true)
        } else { finishAndClose() }
    }
    private func finishAndClose() {
        elevatorService?.stop();elevatorService = nil
        saveResume(.exited)
        headingManager.stopUpdatingHeading();motionManager.stopDeviceMotionUpdates();depthGate.cancel();depthAction = nil;depthRequestID = nil;depthTimeout?.cancel()
        closing = true;cancellation.cancel();generation += 1;scene.session.pause()
        if phase == .collecting,let writer { io.async { _ = try? writer.finish(reason:"user_ended",valid:false) } }
        log("run_ended",["phase":String(describing:phase)])
        recorder?.finish(statistics:["geometry_navigation":true,"phase":String(describing:phase),"physically_confirmed":alignment.mapFromSession != nil,"numeric_accuracy_measured":false]) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .success:self.closeScreen()
            case .failure(let error):self.closing = false;self.diagnosticError = error.localizedDescription;self.refresh();self.campusError(error)
            }
        }
        if recorder == nil { closeScreen() }
    }
    private func closeScreen() {
        let callback = onFinished,arrived = completed,walked = walkedM,floors = floorChanges
        let end = arrived ? zip([map?.map_id],[chosenDestinationID]).compactMap { m,n in m.flatMap { m in n.map { LiDARNodeRef(map:m,node:$0) } } }.first : nil
        onFinished = nil
        dismiss(animated:true) { callback?(arrived,walked,floors,end) }
    }
}
#endif


import UIKit

final class LiDARNodeNamingController:UIViewController {
    struct Input { let name:String?;let kind:CampusNodeKind }
    private let number:Int
    private let completion:(Input?) -> Void
    private let field = UITextField()
    /// Space routing has no use for plain waypoints: only semantic kinds are offered.
    private let values:[CampusNodeKind]
    private let kinds:UISegmentedControl
    init(number:Int,spaceMode:Bool = false,completion:@escaping (Input?) -> Void) {
        values = spaceMode ? [.junction,.room,.stair,.elevator,.exit] : [.waypoint,.junction,.room,.stair,.elevator,.exit]
        kinds = UISegmentedControl(items:values.map { $0 == .room ? "房间" : $0 == .exit ? "出入口" : $0.title })
        self.number = number;self.completion = completion;super.init(nibName:nil,bundle:nil)
        modalPresentationStyle = .formSheet;isModalInPresentation = true
    }
    required init?(coder:NSCoder) { fatalError("init(coder:)") }
    override func viewDidLoad() {
        super.viewDidLoad();title = "新标点";view.backgroundColor = .systemGroupedBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(title:"取消标点",style:.plain,target:self,action:#selector(cancel))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title:"保存",style:.done,target:self,action:#selector(save))
        let note = UILabel();note.numberOfLines = 0;note.text = "位置已固定为刚才点击时的位置。名称可留空，由系统分配自动编号。普通路点可不命名，岔路口和楼梯口建议命名。"
        field.borderStyle = .roundedRect;field.placeholder = "名称（可选）";field.clearButtonMode = .whileEditing;field.autocorrectionType = .no
        field.accessibilityIdentifier = "lidar.node.name";kinds.accessibilityIdentifier = "lidar.node.kind";kinds.selectedSegmentIndex = 0
        let skip = UIButton(type:.system);skip.configuration = .bordered();skip.setTitle("跳过命名，使用自动编号",for:.normal);skip.addTarget(self,action:#selector(skipName),for:.touchUpInside)
        let stack = UIStackView(arrangedSubviews:[note,field,kinds,skip]);stack.axis = .vertical;stack.spacing = 20;stack.translatesAutoresizingMaskIntoConstraints = false;view.addSubview(stack)
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo:view.safeAreaLayoutGuide.topAnchor,constant:24),stack.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:20),stack.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-20),field.heightAnchor.constraint(greaterThanOrEqualToConstant:44),kinds.heightAnchor.constraint(greaterThanOrEqualToConstant:36)])
    }
    private func finish(_ name:String?,cancelled:Bool = false) {
        let chosen = values[max(0,min(values.count-1,kinds.selectedSegmentIndex))]
        dismiss(animated:true) { [completion] in completion(cancelled ? nil : Input(name:name,kind:chosen)) }
    }
    @objc private func cancel() { finish(nil,cancelled:true) }
    @objc private func skipName() { finish(nil) }
    @objc private func save() {
        let value = field.text?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
        guard value.count <= 120 else { campusMessage("名称太长","请控制在120个字符以内。");return }
        finish(value.isEmpty ? nil : value)
    }
}

/// Shared by device capture and the DEBUG-only Mac layout preview. This panel
/// confirms the physical label selected by the user; it does not accept a pose.
final class LiDARPlateReviewController:UIViewController {
    struct Input { let text:String;let name:String;let category:String;let mount:LiDARLandmark.Mount;let setEntrance:Bool }
    private let image:UIImage?,recognized:String,candidates:[String],measurement:String
    private let queryOnly:Bool
    private let completion:(Input?) -> Void
    /// Plate text (exactly as printed, used for recognition) and name (shown, used for the entrance) are separate.
    private let field = UITextField(),nameField = UITextField(),category = UISegmentedControl(items:["门牌","参考特征物"])
    private var nameEdited = false
    private let mount = UISegmentedControl(items:["贴在墙上","贴在门上","不确定"])
    private let entrance = UIButton(type:.system),bindingNote = UILabel()
    init(image:UIImage?,recognized:String,candidates:[String],measurement:String,queryOnly:Bool = false,completion:@escaping (Input?) -> Void) {
        self.image = image;self.recognized = recognized;self.candidates = candidates;self.measurement = measurement;self.queryOnly = queryOnly;self.completion = completion
        super.init(nibName:nil,bundle:nil);modalPresentationStyle = .formSheet;isModalInPresentation = true
        preferredContentSize = CGSize(width:440,height:720)
    }
    required init?(coder:NSCoder) { fatalError("init(coder:)") }
    override func viewDidLoad() {
        super.viewDidLoad();title = "确认门牌";view.backgroundColor = .systemGroupedBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(title:"取消",style:.plain,target:self,action:#selector(cancel))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title:"仅记录",style:.done,target:self,action:#selector(save))
        let scroll = UIScrollView();scroll.keyboardDismissMode = .interactive;scroll.translatesAutoresizingMaskIntoConstraints = false;view.addSubview(scroll)
        let photo = UIImageView(image:image);photo.contentMode = .scaleAspectFit;photo.backgroundColor = .secondarySystemGroupedBackground;photo.clipsToBounds = true;photo.layer.cornerRadius = 12
        photo.isAccessibilityElement = true;photo.accessibilityLabel = image == nil ? "无可用截图" : "冻结的所选门牌截图"
        photo.heightAnchor.constraint(equalToConstant:180).isActive = true
        func label(_ text:String) -> UILabel { let l = UILabel();l.text = text;l.numberOfLines = 0;l.font = .preferredFont(forTextStyle:.subheadline);return l }
        let note = label("请核对截图里的文字和类别。门牌位置与房间入口分别记录；不会自动改变导航定位。")
        field.borderStyle = .roundedRect;field.placeholder = "门牌文字（可手动修改）";field.text = recognized;field.clearButtonMode = .whileEditing;field.autocorrectionType = .no
        field.accessibilityIdentifier = "lidar.plate.text";field.heightAnchor.constraint(greaterThanOrEqualToConstant:44).isActive = true
        field.addTarget(self,action:#selector(textChanged),for:.editingChanged)
        nameField.borderStyle = .roundedRect;nameField.placeholder = "名称（显示和目的地用，默认同门牌文字）";nameField.text = recognized;nameField.clearButtonMode = .whileEditing
        nameField.autocorrectionType = .no;nameField.accessibilityIdentifier = "lidar.plate.name";nameField.heightAnchor.constraint(greaterThanOrEqualToConstant:44).isActive = true
        nameField.addTarget(self,action:#selector(nameChanged),for:.editingChanged)
        category.selectedSegmentIndex = 0;category.addTarget(self,action:#selector(categoryChanged),for:.valueChanged);category.heightAnchor.constraint(greaterThanOrEqualToConstant:36).isActive = true
        mount.selectedSegmentIndex = 2;mount.accessibilityIdentifier = "lidar.plate.mount";mount.accessibilityLabel = "标识安装位置"
        mount.heightAnchor.constraint(greaterThanOrEqualToConstant:36).isActive = true
        let mountNote = label("贴在门上的标识会随开关门移动；不确定时请保留默认选项。安装位置不影响文字记录或入口设置。")
        mountNote.textColor = .secondaryLabel
        entrance.configuration = .filled();entrance.setTitle("设置入口（AR）",for:.normal);entrance.accessibilityIdentifier = "lidar.plate.entrance"
        entrance.addTarget(self,action:#selector(setEntrance),for:.touchUpInside)
        bindingNote.numberOfLines = 0;bindingNote.font = .preferredFont(forTextStyle:.subheadline);bindingNote.textColor = .secondaryLabel
        let geometry = label(measurement);geometry.textColor = .secondaryLabel
        let textNote = label("门牌文字：照门牌上印的填写（如 3-132），只用于自动识别。名称：显示和目的地用（如 132）。两者互不覆盖。");textNote.textColor = .secondaryLabel
        let stack = UIStackView(arrangedSubviews:[photo,note,label("门牌文字"),field,label("名称"),nameField,textNote,category,label("标识安装位置"),mount,mountNote,entrance,bindingNote,geometry]);stack.axis = .vertical;stack.spacing = 16;stack.translatesAutoresizingMaskIntoConstraints = false
        if !candidates.isEmpty {
            let alternative = UIButton(type:.system);alternative.configuration = .bordered();alternative.setTitle("选择其他识别文字",for:.normal);alternative.showsMenuAsPrimaryAction = true
            alternative.menu = UIMenu(children:Array(Set(candidates)).sorted().map { text in UIAction(title:text) { [weak self] _ in self?.field.text = text;self?.textChanged() } })
            stack.insertArrangedSubview(alternative,at:4)
        }
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo:view.leadingAnchor),scroll.trailingAnchor.constraint(equalTo:view.trailingAnchor),scroll.topAnchor.constraint(equalTo:view.safeAreaLayoutGuide.topAnchor),scroll.bottomAnchor.constraint(equalTo:view.keyboardLayoutGuide.topAnchor),stack.leadingAnchor.constraint(equalTo:scroll.contentLayoutGuide.leadingAnchor,constant:20),stack.trailingAnchor.constraint(equalTo:scroll.contentLayoutGuide.trailingAnchor,constant:-20),stack.topAnchor.constraint(equalTo:scroll.contentLayoutGuide.topAnchor,constant:20),stack.bottomAnchor.constraint(equalTo:scroll.contentLayoutGuide.bottomAnchor,constant:-24),stack.widthAnchor.constraint(equalTo:scroll.frameLayoutGuide.widthAnchor,constant:-40)])
        categoryChanged()
    }
    /// The name follows the plate text until the person edits the name itself.
    @objc private func textChanged() { if !nameEdited { nameField.text = field.text } }
    @objc private func nameChanged() { nameEdited = true }
    @objc private func categoryChanged() {
        entrance.isHidden = queryOnly || category.selectedSegmentIndex != 0
        bindingNote.text = queryOnly ? "导航辅助只记录本次查询，不设置入口，不修改地图或当前定位。" : category.selectedSegmentIndex != 0 ? "参考特征物仅作记录，不能设置房间入口，也不会出现在目的地列表中。" : "点“设置入口”回到相机画面，将入口设在走廊一侧的门口地面上；也可以点右上角“仅记录”。未设入口的门牌仍在门牌列表里，但不能作为导航目的地。"
    }
    @objc private func cancel() { dismiss(animated:true) { [completion] in completion(nil) } }
    @objc private func setEntrance() { finish(entrance:true) }
    @objc private func save() { finish(entrance:false) }
    private func finish(entrance:Bool) {
        let text = field.text?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
        guard !text.isEmpty,text.count <= 120 else { campusMessage("请核对文字","输入1–120个字符的门牌或标识文字。");return }
        let name = nameField.text?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
        guard name.count <= 120 else { campusMessage("名称过长","名称最多 120 个字符。");return }
        let mounts:[LiDARLandmark.Mount] = [.wall,.door,.unknown]
        let value = Input(text:text,name:name.isEmpty ? text : name,category:category.selectedSegmentIndex == 0 ? "room_plate" : "reference_feature",mount:mounts[max(0,min(2,mount.selectedSegmentIndex))],setEntrance:entrance && !queryOnly && category.selectedSegmentIndex == 0)
        dismiss(animated:true) { [completion] in completion(value) }
    }
}

/// Names a manual room without creating a plate entity. Shared with the Mac UI preview.
final class LiDARRoomNamingController:UIViewController {
    private let names:[String],completion:(String?) -> Void
    private let field = UITextField()
    init(names:[String],completion:@escaping (String?) -> Void) {
        self.names = names;self.completion = completion;super.init(nibName:nil,bundle:nil)
        preferredContentSize = CGSize(width:440,height:360);isModalInPresentation = true
    }
    required init?(coder:NSCoder) { fatalError("init(coder:)") }
    override func viewDidLoad() {
        super.viewDidLoad();title = "添加房间入口";view.backgroundColor = .systemGroupedBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(title:"取消",style:.plain,target:self,action:#selector(cancel))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title:"下一步",style:.done,target:self,action:#selector(continueToEntrance))
        let note = UILabel();note.numberOfLines = 0;note.text = "填写房间名，或选择已有房间名以增加另一个入口。楼梯口、电梯请用普通标点并选择“楼梯口”类型。下一步在 AR 画面中确认走廊一侧的门口地面。此操作不创建门牌记录。"
        field.borderStyle = .roundedRect;field.placeholder = "房间名称（必填）";field.accessibilityIdentifier = "lidar.room.name";field.autocorrectionType = .no
        let existing = UIButton(type:.system);existing.configuration = .bordered();existing.setTitle("选择已有房间名（另一个入口）",for:.normal);existing.showsMenuAsPrimaryAction = true;existing.isEnabled = !names.isEmpty
        existing.menu = UIMenu(children:Array(Set(names)).sorted().map { name in UIAction(title:name) { [weak self] _ in self?.field.text = name } })
        let stack = UIStackView(arrangedSubviews:[note,field,existing]);stack.axis = .vertical;stack.spacing = 20;stack.translatesAutoresizingMaskIntoConstraints = false;view.addSubview(stack)
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo:view.safeAreaLayoutGuide.topAnchor,constant:24),stack.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:20),stack.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-20),field.heightAnchor.constraint(greaterThanOrEqualToConstant:44)])
    }
    @objc private func cancel() { dismiss(animated:true) { [completion] in completion(nil) } }
    @objc private func continueToEntrance() {
        let text = field.text?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
        guard !text.isEmpty,text.count <= 120 else { campusMessage("请填写房间名","请输入1–120个字符。");return }
        dismiss(animated:true) { [completion] in completion(text) }
    }
}
