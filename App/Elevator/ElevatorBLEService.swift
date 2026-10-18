import Foundation
import CoreBluetooth

/// Radio-only adapter. All public operations and state callbacks run on the main queue.
/// start is explicit: constructing this object neither requests permission nor scans/writes.
/// App target compiles ProbeCore sources together; project references/usage description are added by its owner.
final class ElevatorBLEService:NSObject,CBCentralManagerDelegate,CBPeripheralDelegate {
    struct NearbyDevice:Equatable {
        let id:UUID,name:String,rssi:Int?,lastSeenAt:TimeInterval
    }
    enum DiscoveryPhase { case idle,scanning,unavailable }
    struct DiscoveryState {
        let phase:DiscoveryPhase,devices:[NearbyDevice],reason:String?
    }
    var onDiscovery:((DiscoveryState)->Void)?
    private(set) var discoveryState = DiscoveryState(phase:.idle,devices:[],reason:nil)
    private var discoveryOnly = false,nearby = [UUID:NearbyDevice]()
    enum Phase:String { case unavailable, discovering, discovered, connecting, ready, waitingConfirmation, confirmed, unconfirmed }
    struct State {
        let phase:Phase
        let reason:String?
        let deviceID:String?,groupID:String?,floorID:String?,peripheralName:String?
        let rssi:Int?
        let lastSeenAt:TimeInterval?
        let canCall:Bool
        /// Reserved for a future car telemetry protocol. FFE2's floor is the hall board, not the car.
        let carFloor:Int? = nil
    }
    var onState:((State)->Void)?
    private(set) var state = State(phase:.unavailable,reason:"not_started",deviceID:nil,groupID:nil,floorID:nil,peripheralName:nil,rssi:nil,lastSeenAt:nil,canCall:false)
    private let serviceID = CBUUID(string:"FFE0"),writeID = CBUUID(string:"FFE1"),receiptID = CBUUID(string:"FFE2")
    private var central:CBCentralManager?,peripheral:CBPeripheral?,command:CBCharacteristic?,receipt:CBCharacteristic?
    private var target:ElevatorCallTarget?,context:ElevatorCallContext?,machine:ElevatorCallMachine?
    private var timer:Timer?,lastSeen:TimeInterval?,connectingSince:TimeInterval?,lastRSSIRequest:TimeInterval = 0
    private var rssi:Int?,ready = false,wanted = false,blocked = false
    private var writeInFlight:UUID?
    private var reason:String?,transportPhase:Phase = .unavailable
    private let timeout:TimeInterval
    init(timeout:TimeInterval = 3) { self.timeout = timeout;super.init() }
    private var now:TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Binding tool mode: scan advertised FFE0 services only. Never connect, read or write.
    @discardableResult func startDiscovery() -> Bool {
        dispatchPrecondition(condition:.onQueue(.main));stop();nearby = [:];target = nil
        guard let usage = Bundle.main.object(forInfoDictionaryKey:"NSBluetoothAlwaysUsageDescription") as? String,
              !usage.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {
            publishDiscovery(.unavailable,reason:"missing_bluetooth_usage_description");return false
        }
        discoveryOnly = true;publishDiscovery(.scanning,reason:"bluetooth_starting")
        central = CBCentralManager(delegate:self,queue:.main,options:[CBCentralManagerOptionShowPowerAlertKey:false])
        timer = Timer.scheduledTimer(withTimeInterval:0.5,repeats:true) { [weak self] _ in self?.tick() }
        return true
    }
    func stopDiscovery() { dispatchPrecondition(condition:.onQueue(.main));if discoveryOnly { stop() } }
    private func publishDiscovery(_ phase:DiscoveryPhase,reason:String? = nil) {
        discoveryState = DiscoveryState(phase:phase,devices:nearby.values.sorted {
            $0.name == $1.name ? $0.id.uuidString < $1.id.uuidString : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        },reason:reason)
        onDiscovery?(discoveryState)
    }
    func start(target:ElevatorCallTarget,planRevision:Int) {
        dispatchPrecondition(condition:.onQueue(.main));stop()
        self.target = target;context = target.context(planRevision:planRevision)
        machine = ElevatorCallMachine(boardID:target.device.id,timeout:timeout)
        guard context?.valid == true else { reason = "invalid_context";publish();return }
        // Missing usage text must fail locally rather than triggering an OS privacy termination.
        guard let usage = Bundle.main.object(forInfoDictionaryKey:"NSBluetoothAlwaysUsageDescription") as? String,
              !usage.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { reason = "missing_bluetooth_usage_description";publish();return }
        wanted = true;blocked = false;reason = nil;transportPhase = .discovering
        central = CBCentralManager(delegate:self,queue:.main,options:[CBCentralManagerOptionShowPowerAlertKey:false])
        timer = Timer.scheduledTimer(withTimeInterval:0.5,repeats:true) { [weak self] _ in self?.tick() }
        publish()
    }
    /// Call for every plan/context revision, even when the same physical radio remains connected.
    func updateContext(_ value:ElevatorCallContext?) {
        dispatchPrecondition(condition:.onQueue(.main))
        machine?.invalidate(ifContextDiffersFrom:value)
        guard let value,let target,value.valid,value.boardID == target.device.id,value.floorID == target.floorID,
              value.groupID == target.groupID,value.wireFloor == target.wireFloor,
              target.device.directions.contains(where: { $0.rawValue == value.direction.rawValue }) else {
            context = nil;reason = "context_invalidated";publish();return
        }
        context = value;reason = nil;publish()
    }
    @discardableResult func call(direction:ElevatorCallDirection,context value:ElevatorCallContext) -> Bool {
        dispatchPrecondition(condition:.onQueue(.main));_ = machine?.expire(now:now)
        guard canCall,context == value,value.direction == direction,let p = peripheral,let command,
              machine?.begin(context:value,sentAt:now) == true,let request = machine?.request else { return false }
        writeInFlight = request.id;publish()
        p.writeValue(Data(direction.command.utf8),for:command,type:.withResponse)
        return true
    }
    func stop() {
        dispatchPrecondition(condition:.onQueue(.main));wanted = false;blocked = false;discoveryOnly = false;nearby = [:]
        publishDiscovery(.idle)
        machine?.fail(.stopped);timer?.invalidate();timer = nil
        if let p = peripheral { p.delegate = nil;central?.cancelPeripheralConnection(p) }
        central?.stopScan();central?.delegate = nil;central = nil;peripheral = nil;command = nil;receipt = nil
        ready = false;writeInFlight = nil;connectingSince = nil;lastSeen = nil;rssi = nil;context = nil
        transportPhase = .unavailable;reason = "stopped";publish()
    }
    private var canCall:Bool {
        wanted && !blocked && ready && context != nil && central?.state == .poweredOn && peripheral?.state == .connected
        && receipt?.isNotifying == true && writeInFlight == nil && machine?.phase != .pending && machine?.phase != .failed
        && lastSeen.map { now-$0 <= 10 } == true
    }
    private func publish() {
        var phase = transportPhase
        if wanted && !blocked && ready {
            switch machine?.phase {
            case .pending:phase = .waitingConfirmation
            case .confirmed:phase = .confirmed
            case .unconfirmed:phase = .unconfirmed
            case .failed:phase = .unavailable
            default:phase = .ready
            }
        }
        state = State(phase:phase,reason:reason ?? machine?.reason?.rawValue,deviceID:target?.device.id,groupID:target?.groupID,
                      floorID:target?.floorID,peripheralName:target?.device.peripheral_name,rssi:rssi,lastSeenAt:lastSeen,canCall:canCall)
        onState?(state)
    }
    private func unavailable(_ code:String,callReason:ElevatorCallReason = .disconnected) {
        ready = false;blocked = true;reason = code;transportPhase = .unavailable;machine?.fail(callReason)
        central?.stopScan()
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        publish()
    }
    private func tick() {
        if discoveryOnly {
            nearby = nearby.filter { now-$0.value.lastSeenAt <= 10 }
            publishDiscovery(discoveryState.phase,reason:discoveryState.reason);return
        }
        guard wanted else { return }
        let time = now;_ = machine?.expire(now:time)
        if !blocked,let lastSeen,time-lastSeen > 10 { unavailable("device_expired",callReason:.deviceExpired);return }
        if !blocked,!ready,let since = connectingSince,time-since > 8 { unavailable("connection_timeout");return }
        if !blocked,peripheral?.state == .connected,time-lastRSSIRequest >= 2 { lastRSSIRequest = time;peripheral?.readRSSI() }
        publish()
    }
    private func scan() {
        guard wanted,!blocked,central?.state == .poweredOn else { return }
        transportPhase = .discovering;reason = nil
        central?.scanForPeripherals(withServices:[serviceID],options:[CBCentralManagerScanOptionAllowDuplicatesKey:true]);publish()
    }
    func centralManagerDidUpdateState(_ central:CBCentralManager) {
        guard central === self.central else { return }
        if discoveryOnly {
            switch central.state {
            case .poweredOn:
                central.scanForPeripherals(withServices:[serviceID],options:[CBCentralManagerScanOptionAllowDuplicatesKey:true])
                publishDiscovery(.scanning)
            case .poweredOff:nearby = [:];central.stopScan();publishDiscovery(.unavailable,reason:"bluetooth_powered_off")
            case .unauthorized:nearby = [:];central.stopScan();publishDiscovery(.unavailable,reason:"bluetooth_unauthorized")
            case .unsupported:nearby = [:];publishDiscovery(.unavailable,reason:"bluetooth_unsupported")
            case .resetting:nearby = [:];publishDiscovery(.unavailable,reason:"bluetooth_resetting")
            default:publishDiscovery(.scanning,reason:"bluetooth_starting")
            }
            return
        }
        guard wanted else { return }
        switch central.state {
        case .poweredOn:scan()
        case .poweredOff:unavailable("bluetooth_powered_off",callReason:.bluetoothUnavailable)
        case .unauthorized:unavailable("bluetooth_unauthorized",callReason:.bluetoothUnavailable)
        case .unsupported:unavailable("bluetooth_unsupported",callReason:.bluetoothUnavailable)
        case .resetting:unavailable("bluetooth_resetting",callReason:.bluetoothUnavailable)
        default:transportPhase = .unavailable;reason = "bluetooth_unknown";publish()
        }
    }
    func centralManager(_ central:CBCentralManager,didDiscover p:CBPeripheral,advertisementData:[String:Any],rssi RSSI:NSNumber) {
        guard central === self.central else { return }
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? p.name ?? ""
        if discoveryOnly {
            let first = nearby[p.identifier] == nil
            guard name.utf8.count <= 160,!first || nearby.count < 64 else { return }
            nearby[p.identifier] = NearbyDevice(id:p.identifier,name:name,rssi:RSSI.intValue == 127 ? nil : RSSI.intValue,lastSeenAt:now)
            if first { publishDiscovery(.scanning) };return
        }
        guard wanted,!blocked,let target else { return }
        guard name == target.device.peripheral_name else { return }
        if let existing = peripheral,existing.identifier != p.identifier { unavailable("ambiguous_device_name");return }
        lastSeen = now;rssi = RSSI.intValue == 127 ? nil : RSSI.intValue
        if peripheral == nil {
            peripheral = p;p.delegate = self;transportPhase = .discovered;publish()
            connectingSince = now;transportPhase = .connecting;central.connect(p,options:nil)
        }
        publish()
    }
    func centralManager(_ central:CBCentralManager,didConnect p:CBPeripheral) {
        guard central === self.central,p === peripheral,wanted,!blocked else { central.cancelPeripheralConnection(p);return }
        lastSeen = now;p.discoverServices([serviceID]);publish()
    }
    func centralManager(_ central:CBCentralManager,didFailToConnect p:CBPeripheral,error:Error?) {
        guard central === self.central,p === peripheral,wanted else { return };unavailable("connection_failed")
    }
    func centralManager(_ central:CBCentralManager,didDisconnectPeripheral p:CBPeripheral,error:Error?) {
        guard central === self.central,p === peripheral,wanted,!blocked else { return };unavailable("disconnected")
    }
    func peripheral(_ p:CBPeripheral,didDiscoverServices error:Error?) {
        guard p === peripheral,wanted,!blocked else { return }
        guard error == nil,let service = p.services?.first(where: { $0.uuid == serviceID }) else { unavailable("service_missing");return }
        p.discoverCharacteristics([writeID,receiptID],for:service)
    }
    func peripheral(_ p:CBPeripheral,didDiscoverCharacteristicsFor service:CBService,error:Error?) {
        guard p === peripheral,wanted,!blocked,service.uuid == serviceID else { return }
        guard error == nil,let write = service.characteristics?.first(where: { $0.uuid == writeID }),write.properties.contains(.write),
              let status = service.characteristics?.first(where: { $0.uuid == receiptID }),status.properties.contains(.notify) || status.properties.contains(.indicate) else { unavailable("characteristics_unsupported");return }
        command = write;receipt = status;p.setNotifyValue(true,for:status)
        // Do not read FFE2: its retained value is history, not confirmation of our next command.
    }
    func peripheral(_ p:CBPeripheral,didUpdateNotificationStateFor characteristic:CBCharacteristic,error:Error?) {
        guard p === peripheral,characteristic === receipt,wanted,!blocked else { return }
        guard error == nil,characteristic.isNotifying else { unavailable("notification_subscription_failed");return }
        ready = true;connectingSince = nil;lastSeen = now;transportPhase = .ready;publish()
    }
    func peripheral(_ p:CBPeripheral,didWriteValueFor characteristic:CBCharacteristic,error:Error?) {
        guard p === peripheral,characteristic === command,wanted,!blocked,let writing = writeInFlight else { return }
        writeInFlight = nil
        if writing == machine?.request?.id,error != nil,machine?.phase == .pending { machine?.fail(.writeFailed);reason = "write_failed" }
        publish()
    }
    func peripheral(_ p:CBPeripheral,didUpdateValueFor characteristic:CBCharacteristic,error:Error?) {
        guard p === peripheral,characteristic === receipt,ready,wanted,!blocked else { return }
        guard error == nil else { unavailable("notification_failed");return }
        lastSeen = now
        if let value = characteristic.value,let text = String(data:value,encoding:.utf8),let context {
            _ = machine?.receive(text,receivedAt:now,context:context,source:.notification)
        }
        publish()
    }
    func peripheral(_ p:CBPeripheral,didReadRSSI RSSI:NSNumber,error:Error?) {
        guard p === peripheral,wanted,!blocked,error == nil,RSSI.intValue != 127 else { return }
        lastSeen = now;rssi = RSSI.intValue;publish()
    }
    deinit { timer?.invalidate();central?.stopScan();if let peripheral { central?.cancelPeripheralConnection(peripheral) } }
}
