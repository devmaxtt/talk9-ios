/*
 *  Copyright (C) 2018-2019 Savoir-faire Linux Inc.
 *
 *  Author: Quentin Muret <quentin.muret@savoirfairelinux.com>
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 3 of the License, or
 *  (at your option) any later version.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with this program; if not, write to the Free Software
 *  Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301 USA.
 */

import Reusable
import UIKit
import AVFoundation
import AudioToolbox
import RxSwift
import PhotosUI

class ScanViewController: UIViewController, StoryboardBased, AVCaptureMetadataOutputObjectsDelegate, ViewModelBased, PHPickerViewControllerDelegate {
    // MARK: outlets
    @IBOutlet weak var header: UIView!
    @IBOutlet weak var scanImage: UIImageView!
    @IBOutlet weak var searchTitle: UILabel!
    @IBOutlet weak var bottomMarginTitleConstraint: NSLayoutConstraint!
    @IBOutlet weak var bottomCloseButtonConstraint: NSLayoutConstraint!
    let disposeBag = DisposeBag()
    var onCodeScanned: ((String) -> Void)?

    // MARK: variables
    private static let invalidScanMinTime: TimeInterval = 5
    let systemSoundId: SystemSoundID = 1016

    typealias VMType = ScanViewModel

    var scannedQrCode: Bool = false
    var lastInvalidScanTime: Date?
    private var decodingOverlay: UIView?
    private var decodingOverlayWork: DispatchWorkItem?
    // captureSession manages capture activity and coordinates between input device and captures outputs
    var captureSession: AVCaptureSession?
    var videoPreviewLayer: AVCaptureVideoPreviewLayer?
    var viewModel: ScanViewModel!
    // Empty Rectangle with border to outline detected QR or BarCode
    lazy var codeFrame: UIView = {
        let cFrame = UIView()
        cFrame.layer.borderColor = UIColor.cyan.cgColor
        cFrame.layer.borderWidth = 2
        cFrame.layer.cornerRadius = 4
        cFrame.frame = CGRect.zero
        cFrame.translatesAutoresizingMaskIntoConstraints = false
        return cFrame
    }()

    // MARK: functions
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        captureSession?.stopRunning()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        DispatchQueue.global(qos: .background).async { [weak self] in
            self?.captureSession?.startRunning()
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        if UIDevice.current.hasNotch {
            self.bottomMarginTitleConstraint.constant = 45
            self.bottomCloseButtonConstraint.constant = 17
        } else {
            self.bottomMarginTitleConstraint.constant = 35
            self.bottomCloseButtonConstraint.constant = 25
        }
        self.setupGalleryButton()
        // AVCaptureDevice allows us to reference a physical capture device (video in our case)
        let captureDevice = AVCaptureDevice.default(for: AVMediaType.video)

        if let captureDevice = captureDevice {

            do {

                captureSession = AVCaptureSession()

                // CaptureSession needs an input to capture Data from
                let input = try AVCaptureDeviceInput(device: captureDevice)
                captureSession?.addInput(input)

                // CaptureSession needs and output to transfer Data to
                let captureMetadataOutput = AVCaptureMetadataOutput()
                captureSession?.addOutput(captureMetadataOutput)

                // We tell our Output the expected Meta-data type
                captureMetadataOutput.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
                captureMetadataOutput.metadataObjectTypes = [.code128, .qr, .ean13, .ean8, .code39, .upce, .aztec, .pdf417]

                // The videoPreviewLayer displays video in conjunction with the captureSession
                videoPreviewLayer = AVCaptureVideoPreviewLayer(session: captureSession!)
                if videoPreviewLayer?.connection?.isVideoMirroringSupported ?? false {
                    videoPreviewLayer?.connection?.automaticallyAdjustsVideoMirroring = false
                    videoPreviewLayer?.connection?.isVideoMirrored = false
                }
                videoPreviewLayer?.videoGravity = .resizeAspectFill
                videoPreviewLayer?.frame = view.bounds
                self.searchTitle.text = L10n.Global.search
                view.layer.addSublayer(videoPreviewLayer!)
                view.bringSubviewToFront(header)
                view.bringSubviewToFront(self.scanImage)
                DispatchQueue.global(qos: .background).async { [weak self] in
                    self?.captureSession?.startRunning()
                }
            } catch { print("Error") }
        }
        self.updateOrientation()
        NotificationCenter.default.rx
            .notification(UIDevice.orientationDidChangeNotification)
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: {[weak self] (_) in
                guard let self = self,
                      UIDevice.current.portraitOrLandscape else { return }
                self.videoPreviewLayer?.frame = self.view.bounds
                self.updateOrientation()
                self.view.layoutSubviews()
                self.view.layer.layoutSublayers()
            })
            .disposed(by: self.disposeBag)
    }

    func updateOrientation() {
        if self.videoPreviewLayer?.connection!.isVideoOrientationSupported ?? false {
            self.videoPreviewLayer?.connection?.videoOrientation = AVCaptureVideoOrientation(ScreenHelper.currentOrientation())
        }
    }

    // the metadataOutput function informs our delegate (the ScanViewController) that the captureOutput emitted a new metaData Object
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {

        if !self.scannedQrCode {
            if metadataObjects.isEmpty {
                print("no objects returned")
                return
            }
            guard let metaDataObject = metadataObjects[0] as? AVMetadataMachineReadableCodeObject else { return }
            guard let stringCodeValue = metaDataObject.stringValue else {
                return
            }

            view.addSubview(codeFrame)

            // transformedMetaDataObject returns layer coordinates/height/width from visual properties
            guard let metaDataCoordinates = videoPreviewLayer?.transformedMetadataObject(for: metaDataObject) else {
                return
            }

            // Those coordinates are assigned to our codeFrame
            codeFrame.frame = metaDataCoordinates.bounds

            if let jamiId = self.jamiId(fromScanned: stringCodeValue) {
                AudioServicesPlayAlertSound(systemSoundId)
                print("jamiId : " + jamiId)
                onCodeScanned?(jamiId)
                self.scannedQrCode = true
            } else {
                if let lastTime = lastInvalidScanTime,
                   Date().timeIntervalSince(lastTime) < Self.invalidScanMinTime {
                    return
                }
                lastInvalidScanTime = Date()
                let alert = UIAlertController(title: L10n.Scan.badQrCode, message: "", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: L10n.Global.ok, style: .default, handler: nil))
                self.present(alert, animated: true, completion: nil)
            }
        }
    }

    @IBAction func closeScan(_ sender: Any) {
        self.dismiss(animated: true, completion: nil)
    }

    /// Resolves a scanned code to a Jami id.
    ///
    /// Accepts a bare id and a `jami:`/`ring:` uri, plus the Talk9 deep links
    /// Android shares (`https://talk9.co/id/<x>`, `talk9://id/<x>`). Those carry
    /// the id in the path, so they have to be unwrapped before `JamiURI`, which
    /// only understands bare ids and jami uris. See ANDROID_PARITY.md §1.10.
    ///
    /// Swarm links resolve to nil: this screen adds a contact, and the callback
    /// downstream (`showConversationFromQRCode`) takes a contact id only.
    private func jamiId(fromScanned text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if let url = URL(string: trimmed), let link = DeepLink(url: url) {
            switch link {
            case .user(let jamiId):
                return jamiId
            case .conversation:
                return nil
            }
        }

        let uri = JamiURI(from: trimmed)
        return uri.isJami ? uri.hash : nil
    }

    // MARK: - Gallery QR support

    private func setupGalleryButton() {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        let symbol = UIImage(systemName: "photo.on.rectangle")
        button.setImage(symbol, for: .normal)
        button.tintColor = .white
        button.accessibilityLabel = NSLocalizedString("scan.openGallery",
                                                     value: "Open photo library",
                                                     comment: "Accessibility label for the gallery button on the QR scan screen")
        button.addTarget(self, action: #selector(openPhotoLibrary), for: .touchUpInside)
        self.header.addSubview(button)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 30),
            button.heightAnchor.constraint(equalToConstant: 30),
            button.trailingAnchor.constraint(equalTo: self.header.trailingAnchor, constant: -14),
            button.centerYAnchor.constraint(equalTo: self.searchTitle.centerYAnchor)
        ])
    }

    @objc private func openPhotoLibrary() {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        self.present(picker, animated: true, completion: nil)
    }

    // MARK: - PHPickerViewControllerDelegate

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true, completion: nil)
        guard let provider = results.first?.itemProvider,
              provider.canLoadObject(ofClass: UIImage.self) else { return }
        // Claim the scan for the duration. The capture session keeps running behind
        // the picker, so a code drifting into frame while we decode would call
        // onCodeScanned() a second time and race this one to the callback. This is
        // the same flag the camera path sets once it has a result; the failure path
        // below clears it so the camera can carry on.
        scannedQrCode = true
        scheduleDecodingOverlay()
        provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
            guard let self = self else { return }
            // Already off the main thread here, and CIDetector at high accuracy on a
            // 12 MP photo is not instant — decode before hopping back.
            let decoded = (object as? UIImage).flatMap { self.decodeQRCode(from: $0) }
            DispatchQueue.main.async { self.finishGalleryDecode(decoded) }
        }
    }

    private func finishGalleryDecode(_ decoded: String?) {
        cancelDecodingOverlay()
        // The sheet can be dismissed while a decode is in flight; presenting an
        // alert or navigating from a detached view controller does nothing useful.
        guard viewIfLoaded?.window != nil else { return }
        guard let stringValue = decoded else {
            scannedQrCode = false
            presentInvalidQRAlert(message: NSLocalizedString("scan.qrCodeNotFound",
                                                             value: "No QR code found in the selected image",
                                                             comment: "Shown when the picked image contains no QR code"))
            return
        }
        guard let jamiId = jamiId(fromScanned: stringValue) else {
            scannedQrCode = false
            presentInvalidQRAlert(message: "")
            return
        }
        AudioServicesPlayAlertSound(systemSoundId)
        onCodeScanned?(jamiId)
        // scannedQrCode stays set: this screen is done.
    }

    // MARK: - Decoding overlay

    /// Shown only if decoding outlasts the delay. A photo that decodes in
    /// 200 ms would otherwise flash a spinner for a single frame, which reads
    /// worse than the brief pause it replaces.
    private static let overlayDelay: TimeInterval = 0.3

    private func scheduleDecodingOverlay() {
        cancelDecodingOverlay()
        let work = DispatchWorkItem { [weak self] in self?.installDecodingOverlay() }
        decodingOverlayWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.overlayDelay, execute: work)
    }

    private func cancelDecodingOverlay() {
        decodingOverlayWork?.cancel()
        decodingOverlayWork = nil
        decodingOverlay?.removeFromSuperview()
        decodingOverlay = nil
    }

    private func installDecodingOverlay() {
        guard decodingOverlay == nil, isViewLoaded else { return }
        let overlay = UIView()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        let spinner = UIActivityIndicatorView(style: .large)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.color = .white
        spinner.startAnimating()
        overlay.addSubview(spinner)
        view.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: view.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            spinner.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: overlay.centerYAnchor)
        ])
        decodingOverlay = overlay
    }

    private func decodeQRCode(from image: UIImage) -> String? {
        guard let ciImage = CIImage(image: image) ?? image.cgImage.flatMap({ CIImage(cgImage: $0) }) else {
            return nil
        }
        let detector = CIDetector(ofType: CIDetectorTypeQRCode,
                                  context: nil,
                                  options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        let features = detector?.features(in: ciImage) ?? []
        for feature in features {
            if let qrFeature = feature as? CIQRCodeFeature, let value = qrFeature.messageString {
                return value
            }
        }
        return nil
    }

    private func presentInvalidQRAlert(message: String) {
        let alert = UIAlertController(title: L10n.Scan.badQrCode, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.Global.ok, style: .default, handler: nil))
        self.present(alert, animated: true, completion: nil)
    }
}
