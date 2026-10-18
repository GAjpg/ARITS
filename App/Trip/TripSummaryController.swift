import UIKit

/// End-of-trip summary: a check that draws itself, "已到达 X", time taken, distance walked and the
/// arrival time, with an outdoor / indoor split when the trip had both. "完成" closes it.
final class TripSummaryController: UIViewController {
    struct Summary {
        var destination:String
        var started:Date?
        var arrived = Date()
        var outdoorM:Double?
        var indoorM:Double?
        var floorChanges = 0
    }
    var onDone:(() -> Void)?
    private let summary:Summary
    private let card = UIView(),check = CAShapeLayer(),ring = UIView()
    private var cardBottom:NSLayoutConstraint?

    init(_ s:Summary) { summary = s;super.init(nibName:nil,bundle:nil);modalPresentationStyle = .overFullScreen;modalTransitionStyle = .crossDissolve }
    required init?(coder:NSCoder) { fatalError("init(coder:)") }

    override func viewDidLoad() {
        super.viewDidLoad();view.backgroundColor = WayfindingPalette.ink.withAlphaComponent(0.35)
        card.backgroundColor = .white;card.layer.cornerRadius = 28;card.layer.cornerCurve = .continuous
        card.layer.maskedCorners = [.layerMinXMinYCorner,.layerMaxXMinYCorner]
        ring.backgroundColor = UIColor(red:0.86,green:0.95,blue:0.89,alpha:1);ring.layer.cornerRadius = 36
        let path = UIBezierPath();path.move(to:CGPoint(x:22,y:37));path.addLine(to:CGPoint(x:32,y:47));path.addLine(to:CGPoint(x:51,y:26))
        check.path = path.cgPath;check.strokeColor = UIColor(red:0.08,green:0.50,blue:0.24,alpha:1).cgColor;check.fillColor = nil
        check.lineWidth = 6;check.lineCap = .round;check.lineJoin = .round;check.strokeEnd = 0;ring.layer.addSublayer(check)
        let title = UILabel();title.text = "已到达";title.font = .systemFont(ofSize:15,weight:.semibold);title.textColor = WayfindingPalette.secondary
        let name = UILabel();name.text = summary.destination;name.font = .systemFont(ofSize:26,weight:.heavy);name.textColor = WayfindingPalette.ink
        name.numberOfLines = 2;name.textAlignment = .center
        let f = DateFormatter();f.locale = Locale(identifier:"en_US_POSIX");f.dateFormat = "HH:mm"
        let minutes = summary.started.map { max(1,Int((summary.arrived.timeIntervalSince($0)/60).rounded())) }
        let total = (summary.outdoorM ?? 0)+(summary.indoorM ?? 0)
        let stats = UIStackView(arrangedSubviews:[
            stat(minutes.map { "\($0) 分钟" } ?? "—","用时"),
            stat(total > 0 ? NavigationShellState.distance(total) : "—","步行"),
            stat(f.string(from:summary.arrived),"到达")])
        stats.distribution = .fillEqually
        var parts = [String]()
        if let o = summary.outdoorM,o > 0 { parts.append("室外 \(NavigationShellState.distance(o))") }
        if let i = summary.indoorM,i > 0 { parts.append("室内 \(NavigationShellState.distance(i))") }
        if summary.floorChanges > 0 { parts.append("换层 \(summary.floorChanges) 次") }
        let split = UILabel();split.text = parts.count > 1 ? parts.joined(separator:" · ") : nil;split.font = .systemFont(ofSize:14)
        split.textColor = WayfindingPalette.secondary;split.textAlignment = .center;split.isHidden = split.text == nil
        var c = UIButton.Configuration.filled();c.cornerStyle = .capsule;c.baseBackgroundColor = WayfindingPalette.route;c.title = "完成"
        c.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { var a = $0;a.font = .systemFont(ofSize:17,weight:.bold);return a }
        let done = UIButton(configuration:c,primaryAction:UIAction { [weak self] _ in self?.finish() })
        let ringHolder = UIView();ring.translatesAutoresizingMaskIntoConstraints = false;ringHolder.addSubview(ring)
        let column = UIStackView(arrangedSubviews:[ringHolder,title,name,stats,split,done]);column.axis = .vertical;column.alignment = .fill;column.spacing = 10
        column.setCustomSpacing(18,after:ringHolder);column.setCustomSpacing(2,after:title);column.setCustomSpacing(22,after:name);column.setCustomSpacing(22,after:split)
        title.textAlignment = .center
        for v in [card,column] as [UIView] { v.translatesAutoresizingMaskIntoConstraints = false }
        view.addSubview(card);card.addSubview(column)
        let bottom = card.topAnchor.constraint(equalTo:view.bottomAnchor);cardBottom = bottom
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo:view.leadingAnchor),card.trailingAnchor.constraint(equalTo:view.trailingAnchor),bottom,
            column.leadingAnchor.constraint(equalTo:card.leadingAnchor,constant:24),column.trailingAnchor.constraint(equalTo:card.trailingAnchor,constant:-24),
            column.topAnchor.constraint(equalTo:card.topAnchor,constant:28),column.bottomAnchor.constraint(equalTo:card.safeAreaLayoutGuide.bottomAnchor,constant:-12),
            ring.widthAnchor.constraint(equalToConstant:72),ring.heightAnchor.constraint(equalToConstant:72),
            ring.centerXAnchor.constraint(equalTo:ringHolder.centerXAnchor),ring.topAnchor.constraint(equalTo:ringHolder.topAnchor),ring.bottomAnchor.constraint(equalTo:ringHolder.bottomAnchor),
            done.heightAnchor.constraint(equalToConstant:54)
        ])
    }
    private func stat(_ value:String,_ label:String) -> UIView {
        let v = UILabel();v.text = value;v.font = .systemFont(ofSize:22,weight:.heavy);v.textColor = WayfindingPalette.ink;v.textAlignment = .center
        v.adjustsFontSizeToFitWidth = true;v.minimumScaleFactor = 0.7
        let l = UILabel();l.text = label;l.font = .systemFont(ofSize:13);l.textColor = WayfindingPalette.secondary;l.textAlignment = .center
        let s = UIStackView(arrangedSubviews:[v,l]);s.axis = .vertical;s.spacing = 2;return s
    }
    override func viewDidAppear(_ animated:Bool) {
        super.viewDidAppear(animated)
        view.layoutIfNeeded()
        let h = card.systemLayoutSizeFitting(CGSize(width:view.bounds.width,height:UIView.layoutFittingCompressedSize.height),
                                              withHorizontalFittingPriority:.required,verticalFittingPriority:.fittingSizeLevel).height
        cardBottom?.constant = -h
        let reduce = UIAccessibility.isReduceMotionEnabled
        UIView.animate(withDuration:reduce ? 0 : 0.55,delay:0,usingSpringWithDamping:0.86,initialSpringVelocity:0.2) { self.view.layoutIfNeeded() }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        let draw = CABasicAnimation(keyPath:"strokeEnd");draw.fromValue = 0;draw.toValue = 1;draw.duration = reduce ? 0 : 0.45
        draw.beginTime = CACurrentMediaTime()+(reduce ? 0 : 0.3);draw.fillMode = .backwards;draw.timingFunction = CAMediaTimingFunction(name:.easeOut)
        check.strokeEnd = 1;check.add(draw,forKey:"draw")
    }
    private func finish() { let done = onDone;dismiss(animated:true) { done?() } }
}
