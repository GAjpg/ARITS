import UIKit

/// Palette kept for older call sites; values follow the quiet wayfinding look.
enum NavigationPalette {
    static let ink = WayfindingPalette.ink
    static let muted = WayfindingPalette.secondary
    static let route = WayfindingPalette.route
    static let canvas = WayfindingPalette.ground
    static let attention = UIColor(red:0.706,green:0.325,blue:0.035,alpha:1)   // #B45309
    static let surface = UIColor.white
    static let mapBuilding = WayfindingPalette.building
    static let mapRoad = WayfindingPalette.road
}

/// The manoeuvre glyph on the instruction card (white on ink).
final class NavigationManeuverView: UIView {
    private let image = UIImageView()
    var maneuver: NavigationManeuver = .straight {
        didSet {
            guard oldValue != maneuver else { return }
            image.image = Self.symbol(maneuver)
            // A small spring when the next step changes, so the change is noticed.
            guard !UIAccessibility.isReduceMotionEnabled else { return }
            image.transform = CGAffineTransform(scaleX:0.6,y:0.6)
            UIView.animate(withDuration:0.45,delay:0,usingSpringWithDamping:0.55,initialSpringVelocity:0.8) { self.image.transform = .identity }
        }
    }
    override init(frame:CGRect) {
        super.init(frame:frame);isAccessibilityElement = false
        image.contentMode = .scaleAspectFit;image.tintColor = .white;image.image = Self.symbol(.straight)
        image.translatesAutoresizingMaskIntoConstraints = false;addSubview(image)
        NSLayoutConstraint.activate([image.leadingAnchor.constraint(equalTo:leadingAnchor),image.trailingAnchor.constraint(equalTo:trailingAnchor),
                                     image.topAnchor.constraint(equalTo:topAnchor),image.bottomAnchor.constraint(equalTo:bottomAnchor)])
    }
    required init?(coder:NSCoder) { fatalError("init(coder:)") }
    static func symbol(_ m:NavigationManeuver) -> UIImage? {
        let name:String
        switch m {
        case .start,.straight: name = "arrow.up"
        case .slightLeft: name = "arrow.up.left"
        case .slightRight: name = "arrow.up.right"
        case .left,.sharpLeft: name = "arrow.turn.up.left"
        case .right,.sharpRight: name = "arrow.turn.up.right"
        case .uTurn: name = "arrow.uturn.down"
        case .elevatorUp: name = "arrow.up.square"
        case .elevatorDown: name = "arrow.down.square"
        case .stairsUp,.stairsDown: name = "figure.stairs"
        case .enterIndoor: name = "door.left.hand.open"
        case .recover: name = "location.viewfinder"
        case .arrive: name = "flag.checkered"
        }
        return UIImage(systemName:name,withConfiguration:UIImage.SymbolConfiguration(pointSize:40,weight:.bold))
    }
}

/// Presentation-only overlay shared by outdoor and indoor navigation (it never owns an AR session):
/// a dark instruction card on top, a quality chip, a status card that appears only when needed,
/// and a bottom sheet with time / distance / arrival, an optional action and end / more.
final class UnifiedNavigationShell: UIView {
    var onClose:(() -> Void)?
    var onMore:(() -> Void)?
    var onPrimaryAction:(() -> Void)?
    private let topCard = UIView(),direction = NavigationManeuverView()
    private let instruction = UILabel(),destination = UILabel()
    private let chip = PaddedLabel(),chipDot = UIView()
    private let statusCard = UIView(),statusDot = UIView(),statusTitle = UILabel(),statusDetail = UILabel()
    private let bottomCard = UIView(),duration = UILabel(),distance = UILabel(),subline = UILabel()
    private let primary = UIButton(type:.system),endButton = UIButton(type:.system),moreButton = UIButton(type:.system)
    private var state:NavigationShellState?
    private var statusBelowChip:NSLayoutConstraint?,statusBelowCard:NSLayoutConstraint?

    override init(frame:CGRect) {
        super.init(frame:frame);backgroundColor = .clear
        // Instruction card.
        topCard.backgroundColor = WayfindingPalette.ink;topCard.layer.cornerRadius = 24;topCard.layer.cornerCurve = .continuous
        topCard.layer.shadowColor = UIColor.black.cgColor;topCard.layer.shadowOpacity = 0.28;topCard.layer.shadowRadius = 16;topCard.layer.shadowOffset = CGSize(width:0,height:8)
        instruction.font = .systemFont(ofSize:30,weight:.heavy);instruction.textColor = .white;instruction.numberOfLines = 2;instruction.adjustsFontSizeToFitWidth = true;instruction.minimumScaleFactor = 0.7
        destination.font = .systemFont(ofSize:14);destination.textColor = UIColor(red:0.79,green:0.82,blue:0.80,alpha:1);destination.numberOfLines = 1
        let texts = UIStackView(arrangedSubviews:[instruction,destination]);texts.axis = .vertical;texts.spacing = 2
        direction.widthAnchor.constraint(equalToConstant:54).isActive = true;direction.heightAnchor.constraint(equalToConstant:54).isActive = true
        let guide = UIStackView(arrangedSubviews:[direction,texts]);guide.alignment = .center;guide.spacing = 16
        pin(guide,in:topCard,insets:UIEdgeInsets(top:18,left:20,bottom:18,right:20))
        // Quality chip (e.g. "定位 ±6 米").
        chip.font = .systemFont(ofSize:13,weight:.medium);chip.textColor = WayfindingPalette.ink;chip.backgroundColor = .white
        chip.layer.cornerRadius = 16;chip.clipsToBounds = true;chip.isHidden = true
        chipDot.layer.cornerRadius = 4;chipDot.translatesAutoresizingMaskIntoConstraints = false;chip.addSubview(chipDot)
        // Status card.
        Style.float(statusCard,radius:20);statusCard.alpha = 0
        statusDot.layer.cornerRadius = 5;statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusTitle.font = .systemFont(ofSize:16,weight:.bold);statusTitle.textColor = WayfindingPalette.ink;statusTitle.numberOfLines = 2
        statusDetail.font = .systemFont(ofSize:14);statusDetail.textColor = WayfindingPalette.secondary;statusDetail.numberOfLines = 3
        let statusText = UIStackView(arrangedSubviews:[statusTitle,statusDetail]);statusText.axis = .vertical;statusText.spacing = 3
        let statusRow = UIStackView(arrangedSubviews:[statusDot,statusText]);statusRow.alignment = .firstBaseline;statusRow.spacing = 10
        pin(statusRow,in:statusCard,insets:UIEdgeInsets(top:14,left:16,bottom:14,right:16))
        // Bottom sheet.
        bottomCard.backgroundColor = .white;bottomCard.layer.cornerRadius = 28;bottomCard.layer.cornerCurve = .continuous
        bottomCard.layer.maskedCorners = [.layerMinXMinYCorner,.layerMaxXMinYCorner]
        bottomCard.layer.shadowColor = WayfindingPalette.ink.cgColor;bottomCard.layer.shadowOpacity = 0.12;bottomCard.layer.shadowRadius = 18;bottomCard.layer.shadowOffset = CGSize(width:0,height:-6)
        duration.font = .systemFont(ofSize:30,weight:.heavy);duration.textColor = WayfindingPalette.ink
        distance.font = .systemFont(ofSize:16,weight:.medium);distance.textColor = WayfindingPalette.secondary
        subline.font = .systemFont(ofSize:14);subline.textColor = WayfindingPalette.secondary;subline.numberOfLines = 1
        subline.adjustsFontSizeToFitWidth = true;subline.minimumScaleFactor = 0.8
        let numbers = UIStackView(arrangedSubviews:[duration,distance,UIView()]);numbers.alignment = .firstBaseline;numbers.spacing = 10
        duration.setContentHuggingPriority(.required,for:.horizontal);distance.setContentHuggingPriority(.required,for:.horizontal)
        let left = UIStackView(arrangedSubviews:[numbers,subline]);left.axis = .vertical;left.spacing = 4
        var endConfig = UIButton.Configuration.filled();endConfig.cornerStyle = .capsule;endConfig.title = "结束"
        endConfig.baseBackgroundColor = UIColor(red:0.953,green:0.914,blue:0.906,alpha:1);endConfig.baseForegroundColor = UIColor(red:0.624,green:0.114,blue:0.071,alpha:1)
        endConfig.contentInsets = NSDirectionalEdgeInsets(top:0,leading:22,bottom:0,trailing:22)
        endConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { var a = $0;a.font = .systemFont(ofSize:16,weight:.bold);return a }
        endButton.configuration = endConfig;endButton.accessibilityLabel = "结束导航";endButton.addTarget(self,action:#selector(closePressed),for:.touchUpInside)
        moreButton.setImage(UIImage(systemName:"ellipsis",withConfiguration:UIImage.SymbolConfiguration(pointSize:18,weight:.bold)),for:.normal)
        moreButton.tintColor = WayfindingPalette.ink;moreButton.backgroundColor = UIColor(white:0.94,alpha:1);moreButton.layer.cornerRadius = 26
        moreButton.accessibilityLabel = "导航选项";moreButton.addTarget(self,action:#selector(morePressed),for:.touchUpInside)
        for b in [endButton,moreButton] { b.heightAnchor.constraint(equalToConstant:52).isActive = true }
        moreButton.widthAnchor.constraint(equalToConstant:52).isActive = true
        let buttons = UIStackView(arrangedSubviews:[moreButton,endButton]);buttons.spacing = 10;buttons.alignment = .center
        buttons.setContentHuggingPriority(.required,for:.horizontal);buttons.setContentCompressionResistancePriority(.required,for:.horizontal)
        let row = UIStackView(arrangedSubviews:[left,buttons]);row.alignment = .center;row.spacing = 12
        var primaryConfig = UIButton.Configuration.filled();primaryConfig.cornerStyle = .capsule;primaryConfig.baseBackgroundColor = WayfindingPalette.route
        primaryConfig.baseForegroundColor = .white
        primaryConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { var a = $0;a.font = .systemFont(ofSize:17,weight:.bold);return a }
        primary.configuration = primaryConfig;primary.heightAnchor.constraint(equalToConstant:54).isActive = true
        primary.addTarget(self,action:#selector(primaryPressed),for:.touchUpInside);primary.isHidden = true
        let sheet = UIStackView(arrangedSubviews:[primary,row]);sheet.axis = .vertical;sheet.spacing = 16
        sheet.translatesAutoresizingMaskIntoConstraints = false;bottomCard.addSubview(sheet)
        for v in [topCard,chip,statusCard,bottomCard] { v.translatesAutoresizingMaskIntoConstraints = false;addSubview(v) }
        NSLayoutConstraint.activate([
            topCard.topAnchor.constraint(equalTo:safeAreaLayoutGuide.topAnchor,constant:8),
            topCard.leadingAnchor.constraint(equalTo:leadingAnchor,constant:12),topCard.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-12),
            chip.topAnchor.constraint(equalTo:topCard.bottomAnchor,constant:12),chip.leadingAnchor.constraint(equalTo:leadingAnchor,constant:24),
            chip.heightAnchor.constraint(equalToConstant:32),
            chipDot.widthAnchor.constraint(equalToConstant:8),chipDot.heightAnchor.constraint(equalToConstant:8),
            chipDot.leadingAnchor.constraint(equalTo:chip.leadingAnchor,constant:13),chipDot.centerYAnchor.constraint(equalTo:chip.centerYAnchor),

            statusCard.leadingAnchor.constraint(equalTo:leadingAnchor,constant:12),statusCard.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-12),
            statusDot.widthAnchor.constraint(equalToConstant:10),statusDot.heightAnchor.constraint(equalToConstant:10),
            bottomCard.leadingAnchor.constraint(equalTo:leadingAnchor),bottomCard.trailingAnchor.constraint(equalTo:trailingAnchor),
            bottomCard.bottomAnchor.constraint(equalTo:bottomAnchor),
            sheet.leadingAnchor.constraint(equalTo:bottomCard.leadingAnchor,constant:20),sheet.trailingAnchor.constraint(equalTo:bottomCard.trailingAnchor,constant:-20),
            sheet.topAnchor.constraint(equalTo:bottomCard.topAnchor,constant:20),sheet.bottomAnchor.constraint(equalTo:bottomCard.safeAreaLayoutGuide.bottomAnchor,constant:-10)
        ])
        statusBelowChip = statusCard.topAnchor.constraint(equalTo:chip.bottomAnchor,constant:10)
        statusBelowCard = statusCard.topAnchor.constraint(equalTo:topCard.bottomAnchor,constant:12)
        statusBelowCard?.isActive = true
        for l in [instruction,destination,statusTitle,statusDetail,duration,distance,subline] { l.adjustsFontForContentSizeCategory = false }
    }
    required init?(coder:NSCoder) { fatalError("init(coder:)") }
    private func pin(_ child:UIView,in parent:UIView,insets i:UIEdgeInsets) {
        child.translatesAutoresizingMaskIntoConstraints = false;parent.addSubview(child)
        NSLayoutConstraint.activate([child.leadingAnchor.constraint(equalTo:parent.leadingAnchor,constant:i.left),child.trailingAnchor.constraint(equalTo:parent.trailingAnchor,constant:-i.right),
                                     child.topAnchor.constraint(equalTo:parent.topAnchor,constant:i.top),child.bottomAnchor.constraint(equalTo:parent.bottomAnchor,constant:-i.bottom)])
    }
    /// The height covered by the bottom sheet, for keeping map content above it.
    var bottomInset:CGFloat { bottomCard.frame.height }

    func update(_ value:NavigationShellState) {
        let previous = state;state = value
        direction.maneuver = value.maneuver
        let text = value.instruction
        if instruction.text != text {
            if previous != nil && !UIAccessibility.isReduceMotionEnabled {
                // The next instruction slides up into place.
                let t = CATransition();t.type = .push;t.subtype = .fromTop;t.duration = 0.28;t.timingFunction = CAMediaTimingFunction(name:.easeOut)
                instruction.layer.add(t,forKey:"instruction")
            }
            instruction.text = text
        }
        destination.text = [value.floorLabel,"前往 \(value.destination)"].compactMap { $0 }.joined(separator:" · ")
        // Time / distance / arrival.
        if let t = value.durationSeconds,t.isFinite,t >= 0,t < 86400 { duration.text = "\(max(1,Int(ceil(t/60)))) 分钟" }
        else { duration.text = value.remainingDistanceM == nil ? "准备中" : "—" }
        distance.text = value.remainingDistanceM.map { NavigationShellState.distance($0) }
        var parts = [String]()
        if let a = value.arrivalTime { let f = DateFormatter();f.locale = Locale(identifier:"en_US_POSIX");f.dateFormat = "HH:mm";parts.append(f.string(from:a)+" 到达") }
        switch value.phase {
        case .outdoor:parts.append("抬起手机看实景")
        case .indoor:parts.append("放平手机看楼层图")
        case .indoorRecovery:parts.append("正在恢复室内位置")
        case .preview:parts.append("确认后出发")
        case .arrived:parts.append("已到达")
        default:break
        }
        subline.text = parts.joined(separator:" · ")
        // Optional action.
        let showPrimary = value.actionTitle != nil
        if primary.configuration?.title != value.actionTitle { primary.configuration?.title = value.actionTitle }
        if primary.isHidden == showPrimary { animateLayout { self.primary.isHidden = !showPrimary;self.primary.alpha = showPrimary ? 1 : 0 } }
        // Status card only when something needs attention.
        if let s = value.status {
            statusTitle.text = s.title;statusDetail.text = s.detail;statusDetail.isHidden = s.detail == nil
            statusDot.backgroundColor = s.level == .error ? UIColor(red:0.73,green:0.11,blue:0.11,alpha:1) : s.level == .attention ? NavigationPalette.attention : WayfindingPalette.route
            if statusCard.alpha < 1 { statusCard.transform = CGAffineTransform(translationX:0,y:-10);animateLayout { self.statusCard.alpha = 1;self.statusCard.transform = .identity } }
        } else if statusCard.alpha > 0 { animateLayout { self.statusCard.alpha = 0 } }
        accessibilityElements = [topCard,statusCard,bottomCard].filter { $0.alpha > 0 }
    }
    /// Location quality chip under the instruction card; nil hides it.
    func setChip(_ text:String?,good:Bool) {
        chip.isHidden = text == nil
        // The status card sits under the chip when there is one, else right under the instruction card.
        statusBelowCard?.isActive = text == nil;statusBelowChip?.isActive = text != nil
        chip.text = text.map { "    "+$0 };chipDot.backgroundColor = good ? UIColor(red:0.08,green:0.50,blue:0.24,alpha:1) : NavigationPalette.attention
    }
    private func animateLayout(_ changes:@escaping () -> Void) {
        UIView.animate(withDuration:UIAccessibility.isReduceMotionEnabled ? 0 : 0.35,delay:0,usingSpringWithDamping:0.85,initialSpringVelocity:0.2,
                       options:[.beginFromCurrentState,.allowUserInteraction]) { changes();self.layoutIfNeeded() }
    }
    /// Let map/AR gestures pass through every non-card area.
    override func point(inside point:CGPoint,with event:UIEvent?) -> Bool {
        subviews.contains { !$0.isHidden && $0.alpha > 0.01 && $0.point(inside:convert(point,to:$0),with:event) }
    }
    @objc private func closePressed() { onClose?() }
    @objc private func morePressed() { onMore?() }
    @objc private func primaryPressed() { onPrimaryAction?() }
}
