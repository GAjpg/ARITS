import UIKit

/// Capture guidance in the middle of the screen: a phone glyph swinging left and right (with a
/// little perspective) between two pulsing arrows, and "缓慢左右转动手机". The owner decides when
/// to show it (e.g. hidden once the person turns fast enough, shown again after a still pause).
final class TurnGuideView: UIView {
    private let disc = UIView(),phone = UIImageView(),left = UIImageView(),right = UIImageView(),caption = PaddedLabel()
    private(set) var shown = false

    override init(frame:CGRect) {
        super.init(frame:frame);isUserInteractionEnabled = false;alpha = 0
        disc.backgroundColor = WayfindingPalette.ink.withAlphaComponent(0.55);disc.layer.cornerRadius = 66
        phone.image = UIImage(systemName:"iphone",withConfiguration:UIImage.SymbolConfiguration(pointSize:52,weight:.regular));phone.tintColor = .white
        phone.contentMode = .center
        for (v,name) in [(left,"chevron.left"),(right,"chevron.right")] {
            v.image = UIImage(systemName:name,withConfiguration:UIImage.SymbolConfiguration(pointSize:22,weight:.heavy));v.tintColor = .white;v.alpha = 0.35
        }
        caption.text = "缓慢左右转动手机";caption.font = .systemFont(ofSize:15,weight:.semibold);caption.textColor = .white
        caption.backgroundColor = WayfindingPalette.ink.withAlphaComponent(0.72);caption.layer.cornerRadius = 16;caption.clipsToBounds = true
        for v in [disc,phone,left,right,caption] as [UIView] { v.translatesAutoresizingMaskIntoConstraints = false;addSubview(v) }
        NSLayoutConstraint.activate([
            disc.centerXAnchor.constraint(equalTo:centerXAnchor),disc.topAnchor.constraint(equalTo:topAnchor),
            disc.widthAnchor.constraint(equalToConstant:132),disc.heightAnchor.constraint(equalToConstant:132),
            phone.centerXAnchor.constraint(equalTo:disc.centerXAnchor),phone.centerYAnchor.constraint(equalTo:disc.centerYAnchor),
            left.centerYAnchor.constraint(equalTo:disc.centerYAnchor),left.leadingAnchor.constraint(equalTo:disc.leadingAnchor,constant:14),
            right.centerYAnchor.constraint(equalTo:disc.centerYAnchor),right.trailingAnchor.constraint(equalTo:disc.trailingAnchor,constant:-14),
            caption.topAnchor.constraint(equalTo:disc.bottomAnchor,constant:12),caption.centerXAnchor.constraint(equalTo:centerXAnchor),
            caption.bottomAnchor.constraint(equalTo:bottomAnchor),caption.heightAnchor.constraint(equalToConstant:32),
            widthAnchor.constraint(greaterThanOrEqualToConstant:180)
        ])
    }
    required init?(coder:NSCoder) { fatalError("init(coder:)") }

    func setVisible(_ visible:Bool) {
        guard visible != shown else { return };shown = visible
        if visible { startAnimating() }
        UIView.animate(withDuration:UIAccessibility.isReduceMotionEnabled ? 0 : 0.3,delay:0,options:[.beginFromCurrentState]) {
            self.alpha = visible ? 1 : 0;self.transform = visible ? .identity : CGAffineTransform(scaleX:0.92,y:0.92)
        } completion:{ _ in if !self.shown { self.stopAnimating() } }
    }
    private func startAnimating() {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        // Swing about the vertical axis with perspective, so it reads as turning, not sliding.
        var p = CATransform3DIdentity;p.m34 = -1/220
        let swing = CAKeyframeAnimation(keyPath:"transform")
        swing.values = [-0.55,0.55,-0.55].map { NSValue(caTransform3D:CATransform3DRotate(p,$0,0,1,0)) }
        swing.keyTimes = [0,0.5,1];swing.duration = 2.2;swing.repeatCount = .infinity
        swing.timingFunctions = [CAMediaTimingFunction(name:.easeInEaseOut),CAMediaTimingFunction(name:.easeInEaseOut)]
        phone.layer.add(swing,forKey:"swing")
        for (v,offset) in [(right,0.0),(left,1.1)] {
            let pulse = CABasicAnimation(keyPath:"opacity");pulse.fromValue = 0.25;pulse.toValue = 1;pulse.duration = 1.1
            pulse.autoreverses = true;pulse.repeatCount = .infinity;pulse.beginTime = CACurrentMediaTime()+offset
            pulse.timingFunction = CAMediaTimingFunction(name:.easeInEaseOut);v.layer.add(pulse,forKey:"pulse")
        }
    }
    private func stopAnimating() { [phone,left,right].forEach { $0.layer.removeAllAnimations() } }
}
