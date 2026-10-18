import UIKit

/// Three native design drafts. No camera, location or BLE is started in this screen.
final class NavigationDesignPreviewController:UIViewController {
    private let campus:OutdoorCampus?
    private let selector = UISegmentedControl(items:["室外行走","进楼恢复","室内呼梯"])
    private let canvas = UIView(),shell = UnifiedNavigationShell(),map = OutdoorCampusMapView(),concept = NavigationConceptView(),lift = UIView()
    init(campus:OutdoorCampus? = nil) { self.campus = campus;super.init(nibName:nil,bundle:nil) }
    required init?(coder:NSCoder) { fatalError("init(coder:)") }
    override func viewDidLoad() {
        super.viewDidLoad();title = "统一导航 · 三张视觉稿"
        navigationItem.rightBarButtonItem = UIBarButtonItem(title:"校园首页",style:.plain,target:self,action:#selector(showCampus))
        view.backgroundColor = NavigationPalette.canvas
        selector.selectedSegmentIndex = 0;selector.addTarget(self,action:#selector(change),for:.valueChanged)
        selector.translatesAutoresizingMaskIntoConstraints = false;canvas.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(selector);view.addSubview(canvas)
        NSLayoutConstraint.activate([selector.centerXAnchor.constraint(equalTo:view.centerXAnchor),selector.widthAnchor.constraint(equalTo:canvas.widthAnchor,constant:-32),selector.topAnchor.constraint(equalTo:view.safeAreaLayoutGuide.topAnchor,constant:6),selector.heightAnchor.constraint(equalToConstant:36),canvas.centerXAnchor.constraint(equalTo:view.centerXAnchor),canvas.widthAnchor.constraint(lessThanOrEqualToConstant:430),canvas.leadingAnchor.constraint(greaterThanOrEqualTo:view.leadingAnchor),canvas.trailingAnchor.constraint(lessThanOrEqualTo:view.trailingAnchor),canvas.topAnchor.constraint(equalTo:selector.bottomAnchor,constant:8),canvas.bottomAnchor.constraint(equalTo:view.bottomAnchor)])
        let width = canvas.widthAnchor.constraint(equalTo:view.widthAnchor);width.priority = .defaultHigh;width.isActive = true
        for child in [map,concept,shell] { child.translatesAutoresizingMaskIntoConstraints = false;canvas.addSubview(child);NSLayoutConstraint.activate([child.leadingAnchor.constraint(equalTo:canvas.leadingAnchor),child.trailingAnchor.constraint(equalTo:canvas.trailingAnchor),child.topAnchor.constraint(equalTo:canvas.topAnchor),child.bottomAnchor.constraint(equalTo:canvas.bottomAnchor)]) }
        let url = Bundle.main.url(forResource:"campus",withExtension:"json",subdirectory:"Outdoor") ?? Bundle.main.url(forResource:"campus",withExtension:"json")
        if let campus = campus ?? url.flatMap({ try? OutdoorCampus.decode(Data(contentsOf:$0)) }) {
            map.setCampus(campus)
            if let building = campus.building(id:"w832289363"),let e = building.entrances.first,
               let route = OutdoorRouter(campus:campus).plan(from:campus.graph.nodes[0],buildingID:building.id,entrances:[e]) {
                map.route = route;map.userCoordinate = route.point(at:route.lengthM*0.6);map.accuracyM = 8;map.headingDegrees = 30
                DispatchQueue.main.async { [weak self] in self?.map.recenter() }
            }
        }
        let title = UILabel();title.text = "电梯 · 编号示例";title.font = .systemFont(ofSize:14,weight:.semibold);title.textColor = NavigationPalette.ink
        let floor = UILabel();floor.text = "电梯所在楼层  —";floor.font = .systemFont(ofSize:12);floor.textColor = NavigationPalette.muted
        let call = UIButton(type:.system);var cfg = UIButton.Configuration.filled();cfg.title = "↑  呼叫上行";cfg.baseBackgroundColor = NavigationPalette.route;cfg.baseForegroundColor = .white;cfg.cornerStyle = .medium;call.configuration = cfg
        call.accessibilityLabel = "视觉示例，不发送呼梯命令"
        let stack = UIStackView(arrangedSubviews:[title,floor,call]);stack.axis = .vertical;stack.spacing = 9;stack.translatesAutoresizingMaskIntoConstraints = false
        lift.backgroundColor = .white;lift.layer.cornerRadius = 20;lift.layer.shadowOpacity = 0.12;lift.layer.shadowRadius = 10;lift.addSubview(stack);lift.translatesAutoresizingMaskIntoConstraints = false;canvas.addSubview(lift)
        NSLayoutConstraint.activate([lift.trailingAnchor.constraint(equalTo:canvas.trailingAnchor,constant:-16),lift.bottomAnchor.constraint(equalTo:canvas.safeAreaLayoutGuide.bottomAnchor,constant:-175),lift.widthAnchor.constraint(equalToConstant:156),stack.topAnchor.constraint(equalTo:lift.topAnchor,constant:16),stack.leadingAnchor.constraint(equalTo:lift.leadingAnchor,constant:16),stack.trailingAnchor.constraint(equalTo:lift.trailingAnchor,constant:-16),stack.bottomAnchor.constraint(equalTo:lift.bottomAnchor,constant:-16)])
        shell.onMore = { [weak self] in self?.selector.selectedSegmentIndex = ((self?.selector.selectedSegmentIndex ?? 0)+1)%3;self?.change() }
        change()
    }
    @objc private func showCampus() {
        let page = OutdoorCampusController(campus:campus);page.automaticallyStartsLocation = false
        navigationController?.pushViewController(page,animated:true)
    }
    @objc private func change() {
        let i = selector.selectedSegmentIndex;map.isHidden = i != 0;concept.isHidden = i == 0;concept.recovery = i == 1;lift.isHidden = i != 2
        let s:NavigationShellState
        switch i {
        case 0:s = .init(maneuver:.left,maneuverDistanceM:28,destination:"会议中心 · 132",remainingDistanceM:245,durationSeconds:200,arrivalTime:Date().addingTimeInterval(200),phase:.outdoor,status:.init("视觉稿 · 路线与位置仅作示意"))
        case 1:s = .init(maneuver:.recover,destination:"会议中心 · 132",phase:.indoorRecovery,status:.init("正在确认门口的位置",detail:"缓慢转动手机，观察两侧墙面与门框。",level:.information),floorLabel:"1F",actionTitle:"扫门牌辅助")
        default:s = .init(maneuver:.elevatorUp,maneuverDistanceM:18,destination:"会议中心 · 232",remainingDistanceM:86,phase:.indoor,status:.init("视觉稿 · 呼梯按钮不发送命令"),floorLabel:"1F → 2F")
        }
        shell.update(s)
    }
}

private final class NavigationConceptView:UIView {
    var recovery = false { didSet { setNeedsDisplay() } }
    override func draw(_ rect:CGRect) {
        guard let c = UIGraphicsGetCurrentContext() else { return }
        UIColor(red:0.85,green:0.88,blue:0.86,alpha:1).setFill();c.fill(rect)
        let horizon = bounds.height*0.36,middle = bounds.midX
        let floor = UIBezierPath();floor.move(to:CGPoint(x:middle-38,y:horizon));floor.addLine(to:CGPoint(x:middle+38,y:horizon));floor.addLine(to:CGPoint(x:bounds.maxX+80,y:bounds.maxY));floor.addLine(to:CGPoint(x:-80,y:bounds.maxY));floor.close()
        UIColor(red:0.75,green:0.79,blue:0.77,alpha:1).setFill();floor.fill()
        UIColor.white.withAlphaComponent(0.3).setStroke()
        for i in 1...8 {
            let y = horizon+pow(CGFloat(i)/8,1.8)*(bounds.height-horizon)
            let p = UIBezierPath();p.move(to:CGPoint(x:0,y:y));p.addLine(to:CGPoint(x:bounds.width,y:y));p.lineWidth = 1;p.stroke()
        }
        for side in [-1,1] {
            for i in 1...3 {
                let x = middle+CGFloat(side)*(40+CGFloat(i*i)*16),y = horizon-CGFloat(i)*8
                let p = UIBezierPath(rect:CGRect(x:x,y:y,width:CGFloat(side)*20,height:80+CGFloat(i)*35));NavigationPalette.ink.withAlphaComponent(0.12).setFill();p.fill()
            }
        }
        if !recovery {
            let arrow = UIBezierPath();let y = bounds.height*0.69
            arrow.move(to:CGPoint(x:middle-12,y:y+70));arrow.addLine(to:CGPoint(x:middle+12,y:y+70));arrow.addLine(to:CGPoint(x:middle+12,y:y));arrow.addLine(to:CGPoint(x:middle+30,y:y));arrow.addLine(to:CGPoint(x:middle,y:y-40));arrow.addLine(to:CGPoint(x:middle-30,y:y));arrow.addLine(to:CGPoint(x:middle-12,y:y));arrow.close()
            UIColor.white.setStroke();arrow.lineWidth = 7;arrow.lineJoinStyle = .round;arrow.stroke();NavigationPalette.route.setFill();arrow.fill()
        }
        ("空间示意 · 非实时摄像头" as NSString).draw(at:CGPoint(x:16,y:bounds.height*0.5),withAttributes:[.font:UIFont.systemFont(ofSize:11),.foregroundColor:NavigationPalette.muted])
    }
}
