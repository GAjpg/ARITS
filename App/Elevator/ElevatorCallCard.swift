import UIKit

/// The hall-call card at the bottom right of indoor navigation when the next leg is a bound
/// elevator: elevator name, car floor ("—" until the device reports it), and one call button whose
/// direction comes from this elevator leg. Shown as soon as the elevator is within range; the
/// button stays grey until the Bluetooth board is ready. Tapping elsewhere on the card opens details.
final class ElevatorCallCard: UIView {
    struct Model: Equatable {
        var elevatorName:String
        var carFloor:String?
        var direction:ElevatorCallDirection
        var phase:ElevatorBLEService.Phase
        var canCall:Bool
    }
    var onCall:(() -> Void)?
    var onDetails:(() -> Void)?
    private let caption = UILabel(),floorLabel = UILabel(),chevron = UIImageView(),details = UIControl()
    private let button = UIButton(type:.system),note = UILabel(),noteDot = UIView()
    private var model:Model?

    override init(frame:CGRect) {
        super.init(frame:frame)
        Style.float(self,radius:22);alpha = 0;isHidden = true
        caption.font = .systemFont(ofSize:13);caption.textColor = WayfindingPalette.secondary
        floorLabel.font = .systemFont(ofSize:22,weight:.heavy);floorLabel.textColor = WayfindingPalette.ink
        chevron.image = UIImage(systemName:"chevron.right",withConfiguration:UIImage.SymbolConfiguration(pointSize:13,weight:.bold));chevron.tintColor = WayfindingPalette.secondary
        let texts = UIStackView(arrangedSubviews:[caption,floorLabel]);texts.axis = .vertical;texts.spacing = 1;texts.isUserInteractionEnabled = false
        chevron.contentMode = .center;chevron.setContentHuggingPriority(.required,for:.horizontal);chevron.setContentCompressionResistancePriority(.required,for:.horizontal)
        texts.setContentHuggingPriority(.defaultLow,for:.horizontal)
        let head = UIStackView(arrangedSubviews:[texts,chevron]);head.alignment = .center;head.isUserInteractionEnabled = false
        head.translatesAutoresizingMaskIntoConstraints = false;details.addSubview(head)
        details.addTarget(self,action:#selector(detailsTap),for:.touchUpInside);details.accessibilityTraits = .button
        var c = UIButton.Configuration.filled();c.cornerStyle = .capsule;c.imagePadding = 6
        c.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { var a = $0;a.font = .systemFont(ofSize:16,weight:.bold);return a }
        button.configuration = c;button.addTarget(self,action:#selector(callTap),for:.touchUpInside)
        note.font = .systemFont(ofSize:12);note.textColor = WayfindingPalette.secondary;note.numberOfLines = 2
        noteDot.layer.cornerRadius = 3;noteDot.translatesAutoresizingMaskIntoConstraints = false
        let noteRow = UIStackView(arrangedSubviews:[noteDot,note]);noteRow.alignment = .center;noteRow.spacing = 6
        let column = UIStackView(arrangedSubviews:[details,button,noteRow]);column.axis = .vertical;column.spacing = 10
        column.translatesAutoresizingMaskIntoConstraints = false;addSubview(column)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant:184),
            column.leadingAnchor.constraint(equalTo:leadingAnchor,constant:14),column.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-14),
            column.topAnchor.constraint(equalTo:topAnchor,constant:14),column.bottomAnchor.constraint(equalTo:bottomAnchor,constant:-12),
            head.leadingAnchor.constraint(equalTo:details.leadingAnchor),head.trailingAnchor.constraint(equalTo:details.trailingAnchor),
            head.topAnchor.constraint(equalTo:details.topAnchor),head.bottomAnchor.constraint(equalTo:details.bottomAnchor),
            button.heightAnchor.constraint(equalToConstant:46),
            noteDot.widthAnchor.constraint(equalToConstant:6),noteDot.heightAnchor.constraint(equalToConstant:6)
        ])
    }
    required init?(coder:NSCoder) { fatalError("init(coder:)") }

    func update(_ m:Model) {
        guard m != model else { return };model = m
        caption.text = "\(m.elevatorName) · 轿厢"
        floorLabel.text = m.carFloor.map { "\($0) 层" } ?? "— 层"
        details.accessibilityLabel = "\(m.elevatorName)，轿厢所在楼层\(m.carFloor ?? "未知")，查看详情"
        let up = m.direction == .up
        var c = button.configuration
        c?.title = up ? "呼叫上行" : "呼叫下行"
        c?.image = UIImage(systemName:up ? "arrow.up" : "arrow.down",withConfiguration:UIImage.SymbolConfiguration(pointSize:14,weight:.heavy))
        let enabled = m.canCall && m.phase != .waitingConfirmation
        c?.baseBackgroundColor = enabled ? NavigationPalette.attention : UIColor(red:0.90,green:0.91,blue:0.92,alpha:1)
        c?.baseForegroundColor = enabled ? .white : WayfindingPalette.secondary
        c?.showsActivityIndicator = m.phase == .waitingConfirmation
        button.configuration = c;button.isEnabled = enabled
        let (text,color):(String,UIColor) = {
            switch m.phase {
            case .unavailable:return ("呼梯装置暂不可用",NavigationPalette.attention)
            case .discovering:return ("正在寻找呼梯装置…",WayfindingPalette.secondary)
            case .discovered,.connecting:return ("正在连接呼梯装置…",WayfindingPalette.secondary)
            case .ready:return ("从本层呼叫",WayfindingPalette.route)
            case .waitingConfirmation:return ("已发送，等待装置确认",WayfindingPalette.route)
            case .confirmed:return ("装置已响应，请等电梯",UIColor(red:0.08,green:0.50,blue:0.24,alpha:1))
            case .unconfirmed:return ("未收到确认，可再按一次",NavigationPalette.attention)
            }
        }()
        note.text = text;noteDot.backgroundColor = color
        if m.phase == .confirmed { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    }
    /// Springs in (or out) at the bottom right.
    func setVisible(_ visible:Bool) {
        guard visible != wanted else { return };wanted = visible
        if visible && isHidden { isHidden = false;transform = CGAffineTransform(scaleX:0.85,y:0.85).translatedBy(x:20,y:20) }
        UIView.animate(withDuration:UIAccessibility.isReduceMotionEnabled ? 0 : 0.45,delay:0,usingSpringWithDamping:0.8,initialSpringVelocity:0.3,options:[.beginFromCurrentState,.allowUserInteraction],animations:{
            self.alpha = visible ? 1 : 0;self.transform = visible ? .identity : CGAffineTransform(scaleX:0.9,y:0.9)
        }) { _ in
            // A hide interrupted by a show must not hide the card afterwards.
            if !self.wanted { self.isHidden = true;self.transform = .identity }
        }
    }
    private var wanted = false
    @objc private func callTap() { UIImpactFeedbackGenerator(style:.medium).impactOccurred();onCall?() }
    @objc private func detailsTap() { onDetails?() }
}

/// Settings → 电梯呼叫按钮. Off: no elevator features and no Bluetooth. After connecting: within 25 m
/// of a bound elevator scan for its board and show the card once connected. When near (default):
/// show the card within 25 m; it stays grey until the board is connected.
enum ElevatorCallMode: String,CaseIterable {
    case off,afterConnected,whenNear
    static let key = "nav.elevatorCallMode"
    static var current:ElevatorCallMode {
        get { UserDefaults.standard.string(forKey:key).flatMap(ElevatorCallMode.init(rawValue:)) ?? .whenNear }
        set { UserDefaults.standard.set(newValue.rawValue,forKey:key) }
    }
    var title:String { switch self { case .off:return "关闭";case .afterConnected:return "连接后显示";case .whenNear:return "接近时显示" } }
    var detail:String {
        switch self {
        case .off:return "完全不用电梯功能，不会连接呼梯装置。"
        case .afterConnected:return "距电梯 25 米内开始寻找呼梯装置，连接成功后才显示呼梯按钮。"
        case .whenNear:return "距电梯 25 米内就显示呼梯按钮，连接成功前不能按。"
        }
    }
    func showsCard(_ phase:ElevatorBLEService.Phase) -> Bool {
        switch self {
        case .off:return false
        case .whenNear:return true
        case .afterConnected:return [.ready,.waitingConfirmation,.confirmed,.unconfirmed].contains(phase)
        }
    }
}
