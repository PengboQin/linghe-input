import SwiftUI
import AVFoundation

struct PairingScannerView:UIViewControllerRepresentable {
    let scanned:(URL)->Void
    func makeUIViewController(context:Context)->ScannerController { ScannerController(scanned:scanned) }
    func updateUIViewController(_ controller:ScannerController,context:Context) {}
    static func dismantleUIViewController(_ controller:ScannerController,coordinator:()) { controller.stop() }
}
final class ScannerController:UIViewController,AVCaptureMetadataOutputObjectsDelegate {
    private let capture=AVCaptureSession(),queue=DispatchQueue(label:"PrivateInput.pair-scanner")
    private let scanned:(URL)->Void
    private var preview:AVCaptureVideoPreviewLayer?,finished=false
    private let message=UILabel()
    init(scanned:@escaping(URL)->Void) { self.scanned=scanned;super.init(nibName:nil,bundle:nil) }
    required init?(coder:NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad();view.backgroundColor = .black
        message.text="将另一台设备的接入二维码放入画面";message.textColor = .white;message.textAlignment = .center;message.numberOfLines=0
        message.translatesAutoresizingMaskIntoConstraints=false;view.addSubview(message)
        NSLayoutConstraint.activate([message.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:24),message.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-24),message.bottomAnchor.constraint(equalTo:view.safeAreaLayoutGuide.bottomAnchor,constant:-24)])
        switch AVCaptureDevice.authorizationStatus(for:.video) {
        case .authorized: configure()
        case .notDetermined: AVCaptureDevice.requestAccess(for:.video) { allowed in DispatchQueue.main.async { if allowed { self.configure() } else {self.message.text="相机未获授权，可返回输入六位接入码"} } }
        default:message.text="相机未获授权，可返回输入六位接入码"
        }
    }
    private func configure() {
        guard !finished else { return }
        guard let camera=AVCaptureDevice.default(for:.video),let input=try? AVCaptureDeviceInput(device:camera),capture.canAddInput(input) else {message.text="相机暂不可用，可返回输入六位接入码";return}
        capture.addInput(input);let output=AVCaptureMetadataOutput()
        guard capture.canAddOutput(output) else {return};capture.addOutput(output)
        output.setMetadataObjectsDelegate(self,queue:.main);output.metadataObjectTypes=[.qr]
        let preview=AVCaptureVideoPreviewLayer(session:capture);preview.videoGravity = .resizeAspectFill;self.preview=preview;view.layer.insertSublayer(preview,at:0)
        queue.async { self.capture.startRunning() }
    }
    override func viewDidLayoutSubviews() {super.viewDidLayoutSubviews();preview?.frame=view.bounds}
    func metadataOutput(_ output:AVCaptureMetadataOutput,didOutput objects:[AVMetadataObject],from connection:AVCaptureConnection) {
        guard !finished,let text=(objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue,let url=URL(string:text),url.scheme=="privateinput",url.host=="pair" else {return}
        finished=true;stop();scanned(url)
    }
    func stop() {finished=true;queue.async {self.capture.stopRunning()} }
}
