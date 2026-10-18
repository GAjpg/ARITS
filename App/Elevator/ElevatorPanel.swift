import UIKit

/// The Android elevator page, carried over almost as-is (teammate's ElevatorView.kt / monitor_live.html,
/// spec NAV_APP_UI_SPEC v1.4): a dark page with the car-floor displays (甲 / 乙), two 3D shafts side by
/// side, floor keys, ▲ / ▼ and a status line. It floats over indoor navigation; the AR session keeps
/// running underneath. Only the route's own direction can be called; the shafts are static.
/// Its colours are the Android page's, a deliberate exception to WayfindingPalette.
final class ElevatorPanel: UIView {
    struct Floor: Equatable { var name:String;var hasDevice:Bool }
    struct Model: Equatable {
        var elevatorName:String
        var floors:[Floor]
        /// Index into `floors` of the floor you are on (the call floor) and of the leg's arrival floor.
        var current:Int?,destination:Int?
        var direction:ElevatorCallDirection
        var phase:ElevatorBLEService.Phase
        var canCall:Bool
        var deviceName:String
    }
    var onCall:(() -> Void)?
    var onClose:(() -> Void)?
    private(set) var shown = false

    enum Ink {
        static func hex(_ v:UInt32,_ a:CGFloat = 1) -> UIColor {
            UIColor(red:CGFloat(v >> 16 & 0xFF)/255,green:CGFloat(v >> 8 & 0xFF)/255,blue:CGFloat(v & 0xFF)/255,alpha:a)
        }
        static let page = hex(0x04070C),card = hex(0x0F1B29),line = hex(0x2A4763),textH = hex(0xE6EEF5),textS = hex(0x8FA6BC)
        static let accent = hex(0x2E9E5B),accentDim = hex(0x123A22),display = hex(0x5BE7A0),warn = hex(0xE8B04B),bad = hex(0xE06A6A)
        static let dspFill = hex(0x0B1622),dspLine = hex(0x1E3A54),dspDim = hex(0x3D5A6F),pill = hex(0x16283C),ghost = hex(0x1D2E45),off = hex(0x587089)
    }

    private let backdrop = UIControl(),card = UIView()
    private let back = UIButton(type:.system),titleLabel = UILabel(),dot = UIView()
    private let carA = UILabel(),carB = UILabel(),capA = UILabel(),capB = UILabel()
    private let boxA = UIView(),boxB = UIView()
    private let shaftA = ElevatorShaftView(yaw:0.42),shaftB = ElevatorShaftView(yaw:-0.42)
    private let fbA = PaddedPill(),fbB = PaddedPill()
    private let floorsCaption = UILabel(),floorRow = UIStackView()
    private let upButton = UIButton(type:.system),downButton = UIButton(type:.system)
    private let plan = UILabel(),state = UILabel()
    private var model:Model?

    override init(frame:CGRect) {
        super.init(frame:frame)
        isHidden = true
        backdrop.backgroundColor = UIColor(white:0,alpha:0.45);backdrop.alpha = 0
        backdrop.addTarget(self,action:#selector(closeTap),for:.touchUpInside)
        backdrop.translatesAutoresizingMaskIntoConstraints = false;addSubview(backdrop)
        card.backgroundColor = Ink.page;card.layer.cornerRadius = 24;card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1;card.layer.borderColor = Ink.line.cgColor;card.clipsToBounds = true
        card.translatesAutoresizingMaskIntoConstraints = false;addSubview(card)

        // Header: ← 返回 · 电梯呼叫 · connection dot
        var bc = UIButton.Configuration.plain();bc.image = UIImage(systemName:"chevron.left",withConfiguration:UIImage.SymbolConfiguration(pointSize:15,weight:.bold))
        bc.title = "返回";bc.imagePadding = 4;bc.baseForegroundColor = Ink.textH;bc.contentInsets = .init(top:8,leading:4,bottom:8,trailing:8)
        bc.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { var a = $0;a.font = .systemFont(ofSize:15,weight:.semibold);return a }
        back.configuration = bc;back.addTarget(self,action:#selector(closeTap),for:.touchUpInside)
        titleLabel.text = "电梯呼叫";titleLabel.font = .systemFont(ofSize:17,weight:.bold);titleLabel.textColor = Ink.textH;titleLabel.textAlignment = .center
        dot.layer.cornerRadius = 5;dot.translatesAutoresizingMaskIntoConstraints = false
        let header = UIView()
        for v in [back,titleLabel,dot] as [UIView] { v.translatesAutoresizingMaskIntoConstraints = false;header.addSubview(v) }

        // Car-floor displays, equal size, side by side above the shafts.
        for (box,number,caption,text) in [(boxA,carA,capA,"甲梯 轿厢在几层"),(boxB,carB,capB,"乙梯")] {
            box.backgroundColor = Ink.dspFill;box.layer.cornerRadius = 16;box.layer.borderWidth = 1;box.layer.borderColor = Ink.dspLine.cgColor
            number.font = .monospacedDigitSystemFont(ofSize:46,weight:.bold);number.textAlignment = .center;number.text = "--"
            number.layer.shadowColor = Ink.display.cgColor;number.layer.shadowRadius = 9;number.layer.shadowOffset = .zero
            caption.font = .systemFont(ofSize:11);caption.textColor = Ink.textS;caption.textAlignment = .center;caption.text = text
            let stack = UIStackView(arrangedSubviews:[number,caption]);stack.axis = .vertical;stack.spacing = 3
            stack.translatesAutoresizingMaskIntoConstraints = false;box.addSubview(stack)
            NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo:box.centerXAnchor),stack.centerYAnchor.constraint(equalTo:box.centerYAnchor),
                                         box.heightAnchor.constraint(equalToConstant:88)])
        }
        let displays = UIStackView(arrangedSubviews:[boxA,boxB]);displays.spacing = 10;displays.distribution = .fillEqually

        // Two shafts with their label (top) and floor pill (bottom).
        var shafts = [UIView]()
        for (shaft,fb,name) in [(shaftA,fbA,"甲梯"),(shaftB,fbB,"乙梯")] {
            let holder = UIView();holder.layer.cornerRadius = 15;holder.layer.borderWidth = 1;holder.layer.borderColor = Ink.line.cgColor;holder.clipsToBounds = true
            let lab = PaddedPill();lab.text = name;lab.font = .systemFont(ofSize:11);lab.textColor = Ink.hex(0xBBD3E8);lab.backgroundColor = Ink.hex(0x0E1A28)
            fb.font = .monospacedDigitSystemFont(ofSize:12,weight:.regular);fb.backgroundColor = Ink.hex(0x0A1520);fb.borderColor = Ink.dspLine
            for v in [shaft,lab,fb] as [UIView] { v.translatesAutoresizingMaskIntoConstraints = false;holder.addSubview(v) }
            NSLayoutConstraint.activate([shaft.leadingAnchor.constraint(equalTo:holder.leadingAnchor),shaft.trailingAnchor.constraint(equalTo:holder.trailingAnchor),
                                         shaft.topAnchor.constraint(equalTo:holder.topAnchor),shaft.bottomAnchor.constraint(equalTo:holder.bottomAnchor),
                                         lab.centerXAnchor.constraint(equalTo:holder.centerXAnchor),lab.topAnchor.constraint(equalTo:holder.topAnchor,constant:7),
                                         fb.centerXAnchor.constraint(equalTo:holder.centerXAnchor),fb.bottomAnchor.constraint(equalTo:holder.bottomAnchor,constant:-8)])
            shafts.append(holder)
        }
        let shaftRow = UIStackView(arrangedSubviews:shafts);shaftRow.spacing = 8;shaftRow.distribution = .fillEqually
        let hint = UILabel();hint.text = "井道可拖动旋转";hint.font = .systemFont(ofSize:11.5);hint.textColor = Ink.textS;hint.textAlignment = .center

        floorsCaption.text = "呼叫楼层";floorsCaption.font = .systemFont(ofSize:12);floorsCaption.textColor = Ink.textS
        floorRow.spacing = 6;floorRow.alignment = .center
        let floorLine = UIStackView(arrangedSubviews:[floorsCaption,floorRow,UIView()]);floorLine.spacing = 10;floorLine.alignment = .center

        for (button,up) in [(upButton,true),(downButton,false)] {
            var c = UIButton.Configuration.filled();c.cornerStyle = .fixed;c.background.cornerRadius = 14;c.imagePadding = 6
            c.image = UIImage(systemName:up ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill",withConfiguration:UIImage.SymbolConfiguration(pointSize:14,weight:.bold))
            c.title = up ? "上行" : "下行"
            c.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { var a = $0;a.font = .systemFont(ofSize:17,weight:.bold);return a }
            button.configuration = c;button.addTarget(self,action:#selector(callTap),for:.touchUpInside)
            button.heightAnchor.constraint(equalToConstant:56).isActive = true
        }
        let directions = UIStackView(arrangedSubviews:[upButton,downButton]);directions.spacing = 10;directions.distribution = .fillEqually
        for l in [plan,state] { l.textAlignment = .center;l.numberOfLines = 2 }
        plan.font = .systemFont(ofSize:12.5);plan.textColor = Ink.textS;state.font = .systemFont(ofSize:13,weight:.semibold)

        let column = UIStackView(arrangedSubviews:[header,displays,shaftRow,hint,floorLine,directions,plan,state])
        column.axis = .vertical;column.spacing = 12;column.setCustomSpacing(6,after:shaftRow);column.setCustomSpacing(6,after:plan)
        column.translatesAutoresizingMaskIntoConstraints = false;card.addSubview(column)
        // The shafts take whatever height is left.
        for v in column.arrangedSubviews { v.setContentHuggingPriority(v === shaftRow ? UILayoutPriority(1) : .required,for:.vertical) }
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo:leadingAnchor),backdrop.trailingAnchor.constraint(equalTo:trailingAnchor),
            backdrop.topAnchor.constraint(equalTo:topAnchor),backdrop.bottomAnchor.constraint(equalTo:bottomAnchor),
            card.leadingAnchor.constraint(equalTo:safeAreaLayoutGuide.leadingAnchor,constant:12),card.trailingAnchor.constraint(equalTo:safeAreaLayoutGuide.trailingAnchor,constant:-12),
            card.topAnchor.constraint(equalTo:safeAreaLayoutGuide.topAnchor,constant:8),
            card.bottomAnchor.constraint(equalTo:safeAreaLayoutGuide.bottomAnchor,constant:-8),
            column.leadingAnchor.constraint(equalTo:card.leadingAnchor,constant:14),column.trailingAnchor.constraint(equalTo:card.trailingAnchor,constant:-14),
            column.topAnchor.constraint(equalTo:card.topAnchor,constant:10),column.bottomAnchor.constraint(equalTo:card.bottomAnchor,constant:-16),
            header.heightAnchor.constraint(equalToConstant:44),
            back.leadingAnchor.constraint(equalTo:header.leadingAnchor,constant:-4),back.centerYAnchor.constraint(equalTo:header.centerYAnchor),
            titleLabel.centerXAnchor.constraint(equalTo:header.centerXAnchor),titleLabel.centerYAnchor.constraint(equalTo:header.centerYAnchor),
            dot.trailingAnchor.constraint(equalTo:header.trailingAnchor,constant:-6),dot.centerYAnchor.constraint(equalTo:header.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant:10),dot.heightAnchor.constraint(equalToConstant:10),
            shaftRow.heightAnchor.constraint(greaterThanOrEqualToConstant:170)
        ])
    }
    required init?(coder:NSCoder) { fatalError("init(coder:)") }

    func update(_ m:Model) {
        guard m != model else { return }
        let floorsChanged = m.floors != model?.floors || m.current != model?.current || m.destination != model?.destination
        model = m
        let here = m.current.map { m.floors[$0].name },there = m.destination.map { m.floors[$0].name }
        // 甲梯: the car is taken to be on your floor (you are in its lobby); 乙梯 has no reading.
        carA.text = here ?? "--";carA.textColor = here == nil ? Ink.dspDim : Ink.display;carA.layer.shadowOpacity = here == nil ? 0 : 0.3
        carB.text = "--";carB.textColor = Ink.dspDim;carB.layer.shadowOpacity = 0
        fbA.text = here ?? "--";fbA.textColor = here == nil ? Ink.off : Ink.display
        fbB.text = "--";fbB.textColor = Ink.off
        if floorsChanged {
            let names = m.floors.map(\.name)
            let lo = min(m.current ?? 0,m.destination ?? m.current ?? 0),hi = max(m.current ?? 0,m.destination ?? m.current ?? 0)
            // Two floors in view, like the Android page: yours and the next one towards the arrival floor.
            let band:(Int,Int) = hi-lo <= 1 ? (lo,max(lo,hi)) : (m.direction == .up ? (lo,lo+1) : (hi-1,hi))
            for s in [shaftA,shaftB] { s.floors = names.isEmpty ? ["--"] : names;s.band = band }
            shaftA.carIndex = m.current;shaftB.carIndex = nil
            floorRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for (i,f) in m.floors.enumerated() {
                let p = PaddedPill();p.text = f.name;p.font = .systemFont(ofSize:12,weight:i == m.current ? .bold : .regular)
                p.backgroundColor = i == m.current ? Ink.accentDim : Ink.pill;p.borderColor = i == m.current ? Ink.accent : Ink.line
                p.borderWidth = i == m.current ? 2 : 1;p.textColor = i == m.current ? Ink.accent : Ink.textS;p.alpha = f.hasDevice ? 1 : 0.4
                p.insets = .init(top:5,left:11,bottom:5,right:11);floorRow.addArrangedSubview(p)
            }
        }
        let calling = m.phase == .waitingConfirmation,up = m.direction == .up
        for (button,isUp) in [(upButton,true),(downButton,false)] {
            let mine = isUp == up,enabled = mine && m.canCall && !calling
            var c = button.configuration
            c?.baseBackgroundColor = enabled ? Ink.accent : mine && calling ? Ink.accentDim : Ink.ghost
            c?.baseForegroundColor = enabled ? .white : mine && calling ? Ink.display : Ink.off
            c?.showsActivityIndicator = mine && calling
            button.configuration = c;button.isEnabled = enabled;button.alpha = mine ? 1 : 0.55
        }
        let verb = up ? "上行" : "下行"
        plan.text = [there.map { "去 \($0) → 按 \(here ?? "本层") 的\(verb)" } ?? "按 \(here ?? "本层") 的\(verb)",
                     m.canCall || calling || m.phase == .confirmed || m.phase == .unconfirmed ? "\(m.deviceName) 在线" : "\(m.deviceName) 未连接"].joined(separator:" · ")
        let (text,color):(String,UIColor) = {
            switch m.phase {
            case .unavailable:return ("呼梯装置暂不可用",Ink.bad)
            case .discovering:return ("正在寻找呼梯装置…",Ink.textS)
            case .discovered,.connecting:return ("正在连接呼梯装置…",Ink.textS)
            case .ready:return ("点\(verb)呼叫电梯",Ink.textH)
            case .waitingConfirmation:return ("正在呼叫…",Ink.textH)
            case .confirmed:return ("已呼叫，请等电梯",Ink.display)
            case .unconfirmed:return ("没有收到确认，可以再按一次",Ink.warn)
            }
        }()
        state.text = text;state.textColor = color
        let online = m.canCall || calling || m.phase == .confirmed || m.phase == .unconfirmed
        dot.backgroundColor = online ? Ink.hex(0x3FD37F) : m.phase == .unavailable ? Ink.bad : Ink.hex(0x555566)
        dot.layer.shadowColor = Ink.hex(0x3FD37F).cgColor;dot.layer.shadowRadius = 4;dot.layer.shadowOffset = .zero;dot.layer.shadowOpacity = online ? 0.9 : 0
    }

    func setVisible(_ visible:Bool) {
        guard visible != shown else { return };shown = visible
        let reduce = UIAccessibility.isReduceMotionEnabled
        layoutIfNeeded()
        if visible {
            isHidden = false;card.transform = CGAffineTransform(translationX:0,y:reduce ? 0 : 60);card.alpha = 0
            UIView.animate(withDuration:reduce ? 0 : 0.5,delay:0,usingSpringWithDamping:0.86,initialSpringVelocity:0.2,options:[.allowUserInteraction]) {
                self.card.transform = .identity;self.card.alpha = 1;self.backdrop.alpha = 1
            }
            UISelectionFeedbackGenerator().selectionChanged()
        } else {
            UIView.animate(withDuration:reduce ? 0 : 0.25,animations:{
                self.card.transform = CGAffineTransform(translationX:0,y:reduce ? 0 : 40);self.card.alpha = 0;self.backdrop.alpha = 0
            }) { _ in if !self.shown { self.isHidden = true } }
        }
    }
    @objc private func closeTap() { onClose?() }
    @objc private func callTap() { onCall?() }
}

/// A capsule label with padding and an optional border (the Android page's pills).
final class PaddedPill: UILabel {
    var insets = UIEdgeInsets(top:3,left:12,bottom:3,right:12) { didSet { invalidateIntrinsicContentSize() } }
    var borderColor:UIColor = ElevatorPanel.Ink.line { didSet { layer.borderColor = borderColor.cgColor } }
    var borderWidth:CGFloat = 1 { didSet { layer.borderWidth = borderWidth } }
    override init(frame:CGRect) { super.init(frame:frame);layer.borderWidth = 1;layer.borderColor = borderColor.cgColor;layer.masksToBounds = true;textAlignment = .center }
    required init?(coder:NSCoder) { fatalError("init(coder:)") }
    override func drawText(in rect:CGRect) { super.drawText(in:rect.inset(by:insets)) }
    override var intrinsicContentSize:CGSize {
        let s = super.intrinsicContentSize;return CGSize(width:s.width+insets.left+insets.right,height:s.height+insets.top+insets.bottom)
    }
    override func layoutSubviews() { super.layoutSubviews();layer.cornerRadius = bounds.height/2 }
}

/// The Android page's 3D shaft (same constants and projection as ElevatorView.kt): glass walls, pit,
/// frame, slabs, rails, hall doors with call panels, machine, counterweight, ropes, and the car when
/// its floor is known. The framed floors are solid, the others ghosted and faded into the dark.
/// Static: redrawn only when dragged or when its data changes.
final class ElevatorShaftView: UIView {
    var floors:[String] = ["1F","2F"] { didSet { setNeedsDisplay() } }
    var band:(lo:Int,hi:Int) = (0,1) { didSet { setNeedsDisplay() } }
    var carIndex:Int? { didSet { setNeedsDisplay() } }
    private var yaw:Double,pitch = -0.13

    private let shaftHalf = 0.80,carHalf = 0.66,carHalfH = 1.05,floorGap = 2.60,carClear = 0.06
    private let pitDepth = 0.45,headroom = 1.00,slabBorder = 0.11,dist = 9.0,near = 0.15,ghostAlpha = 0.26
    private let light:(Double,Double,Double) = (0.40,0.80,0.45)

    init(yaw:Double) {
        self.yaw = yaw;super.init(frame:.zero)
        isOpaque = false;backgroundColor = .clear;contentMode = .redraw
        addGestureRecognizer(UIPanGestureRecognizer(target:self,action:#selector(pan(_:))))
    }
    required init?(coder:NSCoder) { fatalError("init(coder:)") }
    @objc private func pan(_ g:UIPanGestureRecognizer) {
        let t = g.translation(in:self);g.setTranslation(.zero,in:self)
        yaw += Double(t.x)*0.012;pitch = min(0.12,max(-0.80,pitch+Double(t.y)*0.005));setNeedsDisplay()
    }

    private enum Face { case quad([CGPoint],UIColor),line(CGPoint,CGPoint,UIColor),text(String,CGPoint,UIColor) }
    private func slabY(_ i:Int) -> Double { Double(i)*floorGap }
    private func carCenterY(_ i:Int) -> Double { slabY(i)+carHalfH+carClear }
    private var doorH:Double { carHalfH*2-0.18 }

    override func draw(_ rect:CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(),!floors.isEmpty else { return }
        let w = Double(bounds.width),h = Double(bounds.height)
        // Background: radial gradient from #101F33 (50%, 30%) to #070D16 at 72%.
        let colors = [ElevatorPanel.Ink.hex(0x101F33).cgColor,ElevatorPanel.Ink.hex(0x070D16).cgColor] as CFArray
        if let g = CGGradient(colorsSpace:CGColorSpaceCreateDeviceRGB(),colors:colors,locations:[0,1]) {
            let c = CGPoint(x:w/2,y:h*0.3),r = 0.72*hypot(max(w/2,w/2),max(h*0.3,h*0.7))
            ctx.drawRadialGradient(g,startCenter:c,startRadius:0,endCenter:c,endRadius:r,options:[.drawsAfterEndLocation])
        }
        let n = floors.count,lo = min(max(0,band.lo),n-1),hi = min(max(lo,band.hi),n-1)
        let shaftBottom = slabY(0)-pitDepth,shaftTop = carCenterY(n-1)+carHalfH+headroom
        let viewBottom = slabY(lo)-1.00,viewTop = slabY(hi+1)+0.80
        let viewCenterY = (viewBottom+viewTop)/2,viewHeight = viewTop-viewBottom
        let bandBottom = slabY(lo),bandTop = slabY(hi+1)
        let focal = (h*0.96)*dist/viewHeight,cx = w/2,cyc = h/2
        let cy = cos(yaw),sy = sin(yaw),cp = cos(pitch),sp = sin(pitch)
        let carY = carCenterY(carIndex.map { min(max(0,$0),n-1) } ?? lo)
        func cwYFor(_ y:Double) -> Double {
            let t = min(1,max(0,(y-carCenterY(0))/max(1e-6,carCenterY(max(1,n-1))-carCenterY(0))))
            let top = shaftTop-0.75,bottom = shaftBottom+0.85;return top+t*(bottom-top)
        }
        let cwY = cwYFor(carY)
        func depth(_ x:Double,_ y:Double,_ z:Double) -> Double { (y-viewCenterY)*sp+(-x*sy+z*cy)*cp+dist }
        func project(_ x:Double,_ y:Double,_ z:Double) -> CGPoint {
            let yy = y-viewCenterY,rx = x*cy+z*sy,rz0 = -x*sy+z*cy
            let ry = yy*cp-rz0*sp,rz = max(yy*sp+rz0*cp+dist,near),s = focal/rz
            return CGPoint(x:cx+rx*s,y:cyc-ry*s)
        }
        var faces:[(depth:Double,face:Face)] = []
        func ghost(_ y:Double) -> Bool { y < bandBottom || y > bandTop }
        func shade(_ hex:UInt32,_ a:Double,_ b:Double) -> UIColor {
            let f = min(max(b,0.18),1.35)
            let r = min(255,Double(hex >> 16 & 0xFF)*f),g = min(255,Double(hex >> 8 & 0xFF)*f),bl = min(255,Double(hex & 0xFF)*f)
            return UIColor(red:CGFloat(floor(r)/255),green:CGFloat(floor(g)/255),blue:CGFloat(floor(bl)/255),alpha:CGFloat(a/255))
        }
        func quad(_ v:[Double],_ hex:UInt32,_ alpha:Double) {
            let ax = v[3]-v[0],ay = v[4]-v[1],az = v[5]-v[2],bx = v[6]-v[0],by = v[7]-v[1],bz = v[8]-v[2]
            var nx = ay*bz-az*by,ny = az*bx-ax*bz,nz = ax*by-ay*bx
            let nl = sqrt(nx*nx+ny*ny+nz*nz);if nl > 1e-6 { nx /= nl;ny /= nl;nz /= nl }
            let rnx = nx*cy+nz*sy,rnz0 = -nx*sy+nz*cy,rny = ny*cp-rnz0*sp,rnz = ny*sp+rnz0*cp
            let b = 0.34+0.66*abs(rnx*light.0+rny*light.1+rnz*light.2)
            var pts = [CGPoint](),d = 0.0,ys = 0.0
            for k in 0..<4 { pts.append(project(v[k*3],v[k*3+1],v[k*3+2]));d += depth(v[k*3],v[k*3+1],v[k*3+2]);ys += v[k*3+1] }
            let g = ghost(ys/4)
            faces.append((d/4,.quad(pts,shade(hex,g ? alpha*ghostAlpha : alpha,b*(g ? 0.62 : 1)))))
        }
        func line(_ x0:Double,_ y0:Double,_ z0:Double,_ x1:Double,_ y1:Double,_ z1:Double,_ c:UIColor) {
            faces.append(((depth(x0,y0,z0)+depth(x1,y1,z1))/2,.line(project(x0,y0,z0),project(x1,y1,z1),ghost((y0+y1)/2) ? UIColor(red:122/255,green:152/255,blue:180/255,alpha:0.20) : c)))
        }
        func text(_ s:String,_ x:Double,_ y:Double,_ z:Double) {
            faces.append((depth(x,y,z),.text(s,project(x,y,z),ghost(y) ? UIColor(red:130/255,green:158/255,blue:185/255,alpha:0.42) : ElevatorPanel.Ink.hex(0xC6DCF0))))
        }
        func box(_ x:Double,_ y:Double,_ z:Double,_ hx:Double,_ hy:Double,_ hz:Double,_ hex:UInt32,_ a:Double) {
            quad([x-hx,y-hy,z-hz,x+hx,y-hy,z-hz,x+hx,y+hy,z-hz,x-hx,y+hy,z-hz],hex,a)
            quad([x-hx,y-hy,z+hz,x+hx,y-hy,z+hz,x+hx,y+hy,z+hz,x-hx,y+hy,z+hz],hex,a)
            quad([x-hx,y-hy,z-hz,x-hx,y-hy,z+hz,x-hx,y+hy,z+hz,x-hx,y+hy,z-hz],hex,a)
            quad([x+hx,y-hy,z-hz,x+hx,y-hy,z+hz,x+hx,y+hy,z+hz,x+hx,y+hy,z-hz],hex,a)
            quad([x-hx,y+hy,z-hz,x+hx,y+hy,z-hz,x+hx,y+hy,z+hz,x-hx,y+hy,z+hz],hex,a)
            quad([x-hx,y-hy,z-hz,x+hx,y-hy,z-hz,x+hx,y-hy,z+hz,x-hx,y-hy,z+hz],hex,a)
        }
        func rect(_ s:Double,_ y:Double,_ c:UIColor) { line(-s,y,-s,s,y,-s,c);line(s,y,-s,s,y,s,c);line(s,y,s,-s,y,s,c);line(-s,y,s,-s,y,-s,c) }

        let frame = ElevatorPanel.Ink.hex(0x9FC0DE),soft = UIColor(red:159/255,green:192/255,blue:222/255,alpha:0.78)
        let s = shaftHalf,b = shaftBottom,t = shaftTop
        // Glass walls, pit
        quad([-s,b,-s,s,b,-s,s,t,-s,-s,t,-s],0x3E6FA8,34);quad([-s,b,s,s,b,s,s,t,s,-s,t,s],0x3E6FA8,34)
        quad([-s,b,-s,-s,b,s,-s,t,s,-s,t,-s],0x3E6FA8,34);quad([s,b,-s,s,b,s,s,t,s,s,t,-s],0x3E6FA8,34)
        quad([-s,b,-s,s,b,-s,s,b,s,-s,b,s],0x16304A,255)
        // Top ring, posts, floor lines
        rect(s,t,frame)
        line(-s,b,-s,-s,t,-s,frame);line(s,b,-s,s,t,-s,frame);line(-s,b,s,-s,t,s,frame);line(s,b,s,s,t,s,frame)
        for i in 0..<n { rect(s,slabY(i)+0.02,soft) }
        // Rails
        let railX = carHalf+0.02,rail = ElevatorPanel.Ink.hex(0xB9D2E8)
        for rx in [-railX,railX] { line(rx,b,-0.05,rx,t,-0.05,rail);line(rx,b,0.05,rx,t,0.05,rail) }
        // Hall doors and call panels
        let zf = -shaftHalf+0.02,hd = carHalf*0.86,dh = doorH
        for i in 0..<n {
            let y0 = slabY(i)+0.06,y1 = y0+dh
            quad([-hd,y0,zf+0.01,hd,y0,zf+0.01,hd,y1,zf+0.01,-hd,y1,zf+0.01],0x8FA9C2,58)
            line(-hd,y0,zf,hd,y0,zf,soft);line(-hd,y1,zf,hd,y1,zf,soft)
            line(-hd,y0,zf,-hd,y1,zf,soft);line(hd,y0,zf,hd,y1,zf,soft)
            line(0,y0,zf,0,y1,zf,soft);line(-hd,y0,zf,hd,y0,zf,ElevatorPanel.Ink.hex(0x0E2438))
            let px = hd+0.09
            box(px,y0+dh*0.62,zf+0.01,0.035,0.11,0.015,0x2A3E52,255)
            box(px,y0+dh*0.62+0.05,zf-0.005,0.012,0.012,0.006,0x7CE0A0,255)
        }
        // Slab rings
        let bb = slabBorder
        for i in 0..<n {
            let y = slabY(i)
            quad([-s,y,s-bb,s,y,s-bb,s,y,s,-s,y,s],0x24405C,255);quad([-s,y,-s,s,y,-s,s,y,-s+bb,-s,y,-s+bb],0x24405C,255)
            quad([-s,y,-s+bb,-s+bb,y,-s+bb,-s+bb,y,s-bb,-s,y,s-bb],0x24405C,255);quad([s-bb,y,-s+bb,s,y,-s+bb,s,y,s-bb,s-bb,y,s-bb],0x24405C,255)
        }
        // Machine, counterweight, ropes
        box(0,t-0.22,0,0.55,0.09,0.34,0x7C93A6,255);box(0,t-0.40,0,0.16,0.13,0.13,0x5E7080,255)
        let cwX = 0.40,cwZ = shaftHalf-0.22
        box(cwX,cwY,cwZ,0.16,0.58,0.10,0x4A5A66,255)
        for k in 1...3 { let py = cwY-0.58+Double(k)*0.29;line(cwX-0.16,py,cwZ-0.101,cwX+0.16,py,cwZ-0.101,ElevatorPanel.Ink.hex(0x38454E)) }
        let rope = UIColor(red:175/255,green:196/255,blue:214/255,alpha:0.75),sheaveY = t-0.46
        for dx in [-0.10,0,0.10] { line(dx,carY+carHalfH,0,dx,sheaveY,0,rope) }
        for dx in [-0.05,0.05] { line(cwX+dx,cwY+0.58,cwZ,cwX+dx,sheaveY,cwZ,rope) }
        // Car
        if carIndex != nil {
            let c = carHalf,y0 = carY-carHalfH,y1 = carY+carHalfH
            quad([-c,y1,-c,c,y1,-c,c,y1,c,-c,y1,c],0x456A8E,255);quad([-c,y0,-c,c,y0,-c,c,y0,c,-c,y0,c],0x1B2E40,255)
            quad([-c,y0,-c,-c,y0,c,-c,y1,c,-c,y1,-c],0x33536F,255);quad([c,y0,-c,c,y0,c,c,y1,c,c,y1,-c],0x33536F,255)
            quad([-c,y0,c,c,y0,c,c,y1,c,-c,y1,c],0x22384E,255)
            let zF = -c,doorL = carHalf*0.92,headerY = y0+doorH+0.12
            func front(_ x0:Double,_ x1:Double,_ ya:Double,_ yb:Double,_ hex:UInt32) { quad([x0,ya,zF,x1,ya,zF,x1,yb,zF,x0,yb,zF],hex,255) }
            front(-c,c,headerY,y1,0x24435E);front(-c,c,y0,y0+0.06,0x24435E)
            front(-c,-0.03,y0+0.06,headerY,0x86AECF);front(0.03,c,y0+0.06,headerY,0x86AECF);front(-0.03,0.03,y0+0.06,headerY,0xF0C070)
            let header = ElevatorPanel.Ink.hex(0x24435E)
            line(-doorL,y0+0.06,zF,-doorL,headerY,zF,header);line(doorL,y0+0.06,zF,doorL,headerY,zF,header)
            let trim = ElevatorPanel.Ink.hex(0x28405A),railY = y0+carHalfH*1.05,skirtY = y0+0.10
            for sx in [-c,c] { let ox = sx < 0 ? -0.006 : 0.006;line(sx+ox,railY,-c,sx+ox,railY,c,trim);line(sx+ox,skirtY,-c,sx+ox,skirtY,c,trim) }
        }
        for i in 0..<n { text(floors[i],-0.30,slabY(i)+0.34,-shaftHalf+0.04) }

        // Painter's order, far to near.
        let font = UIFont.systemFont(ofSize:13,weight:.bold)
        ctx.setLineWidth(1.1)
        for (_,f) in faces.sorted(by: { $0.depth > $1.depth }) {
            switch f {
            case .quad(let p,let c):
                ctx.setFillColor(c.cgColor);ctx.beginPath();ctx.move(to:p[0]);for q in p.dropFirst() { ctx.addLine(to:q) };ctx.closePath();ctx.fillPath()
            case .line(let a,let z,let c):
                ctx.setStrokeColor(c.cgColor);ctx.beginPath();ctx.move(to:a);ctx.addLine(to:z);ctx.strokePath()
            case .text(let s,let p,let c):
                (s as NSString).draw(at:CGPoint(x:p.x,y:p.y-font.ascender),withAttributes:[.font:font,.foregroundColor:c])
            }
        }
        // Fade the ghosted floors at the top and bottom into the dark.
        let fade = [UIColor(red:3/255,green:7/255,blue:12/255,alpha:0.82).cgColor,UIColor(red:3/255,green:7/255,blue:12/255,alpha:0).cgColor] as CFArray
        if let g = CGGradient(colorsSpace:CGColorSpaceCreateDeviceRGB(),colors:fade,locations:[0,1]) {
            ctx.drawLinearGradient(g,start:CGPoint(x:0,y:0),end:CGPoint(x:0,y:h*0.22),options:[])
            ctx.drawLinearGradient(g,start:CGPoint(x:0,y:h),end:CGPoint(x:0,y:h*0.78),options:[])
        }
    }
}

/// Settings → 电梯呼叫页预览: the page over a camera stand-in with sample floors (2F → 4F). The
/// buttons only play the call states; nothing is sent to any device.
final class ElevatorPanelPreviewController: UIViewController {
    private let panel = ElevatorPanel()
    private var model = ElevatorPanel.Model(elevatorName:"示例电梯",floors:["1F","2F","3F","4F"].map { .init(name:$0,hasDevice:$0 == "2F" || $0 == "3F") },
                                            current:1,destination:3,direction:.up,phase:.ready,canCall:true,deviceName:"ELEV-2F（预览）")
    init() { super.init(nibName:nil,bundle:nil);modalPresentationStyle = .overFullScreen;modalTransitionStyle = .crossDissolve }
    required init?(coder:NSCoder) { fatalError("init(coder:)") }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red:0.29,green:0.32,blue:0.30,alpha:1)
        let note = UILabel();note.text = "预览：按钮只演示状态，不会呼叫电梯";note.font = .systemFont(ofSize:13);note.textColor = UIColor(white:1,alpha:0.7)
        note.translatesAutoresizingMaskIntoConstraints = false;view.addSubview(note)
        panel.translatesAutoresizingMaskIntoConstraints = false;view.addSubview(panel)
        NSLayoutConstraint.activate([note.centerXAnchor.constraint(equalTo:view.centerXAnchor),note.centerYAnchor.constraint(equalTo:view.centerYAnchor),
                                     panel.leadingAnchor.constraint(equalTo:view.leadingAnchor),panel.trailingAnchor.constraint(equalTo:view.trailingAnchor),
                                     panel.topAnchor.constraint(equalTo:view.topAnchor),panel.bottomAnchor.constraint(equalTo:view.bottomAnchor)])
        panel.onClose = { [weak self] in self?.panel.setVisible(false);DispatchQueue.main.asyncAfter(deadline:.now()+0.25) { self?.dismiss(animated:false) } }
        panel.onCall = { [weak self] in
            guard let self else { return }
            self.set(.waitingConfirmation)
            DispatchQueue.main.asyncAfter(deadline:.now()+1.2) { [weak self] in self?.set(.confirmed) }
            DispatchQueue.main.asyncAfter(deadline:.now()+4) { [weak self] in self?.set(.ready) }
        }
        panel.update(model)
    }
    override func viewDidAppear(_ animated:Bool) { super.viewDidAppear(animated);panel.setVisible(true) }
    private func set(_ phase:ElevatorBLEService.Phase) { model.phase = phase;panel.update(model) }
}
