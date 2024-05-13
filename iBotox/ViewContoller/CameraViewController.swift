//
//  CameraViewController.swift
//  iBotox
//
//  Created by Tanveer Ashraf on 14/04/2024.
//
import AVFoundation
import MediaPipeTasksVision
import UIKit

/**
 * The view controller is responsible for performing detection on incoming frames from the live camera and presenting the frames with the
 * landmark of the landmarked faces to the user.
 */
class CameraViewController: UIViewController {
    
  private struct Constants {
    static let edgeOffset: CGFloat = 2.0
  }
  
  weak var inferenceResultDeliveryDelegate: InferenceResultDeliveryDelegate?
  weak var interfaceUpdatesDelegate: InterfaceUpdatesDelegate?
  
  @IBOutlet weak var previewView: UIView!
  @IBOutlet weak var cameraUnavailableLabel: UILabel!
  @IBOutlet weak var resumeButton: UIButton!
  @IBOutlet weak var overlayView: OverlayView!
  
  private var isSessionRunning = false
  private var isObserving = false
  private let backgroundQueue = DispatchQueue(label: "com.google.mediapipe.cameraController.backgroundQueue")
  
  // MARK: Controllers that manage functionality
  // Handles all the camera related functionality
  private lazy var cameraFeedService = CameraFeedService(previewView: previewView)
  
  private let faceLandmarkerServiceQueue = DispatchQueue(
    label: "com.google.mediapipe.cameraController.faceLandmarkerServiceQueue",
    attributes: .concurrent)
  
  // Queuing reads and writes to faceLandmarkerService using the Apple recommended way
  // as they can be read and written from multiple threads and can result in race conditions.
  private var _faceLandmarkerService: FaceLandmarkerService?
  private var faceLandmarkerService: FaceLandmarkerService? {
    get {
      faceLandmarkerServiceQueue.sync {
        return self._faceLandmarkerService
      }
    }
    set {
      faceLandmarkerServiceQueue.async(flags: .barrier) {
        self._faceLandmarkerService = newValue
      }
    }
  }
    
#if !targetEnvironment(simulator)
  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    initializeFaceLandmarkerServiceOnSessionResumption()
    cameraFeedService.startLiveCameraSession {[weak self] cameraConfiguration in
      DispatchQueue.main.async {
        switch cameraConfiguration {
        case .failed:
          self?.presentVideoConfigurationErrorAlert()
        case .permissionDenied:
          self?.presentCameraPermissionsDeniedAlert()
        default:
          break
        }
      }
    }
  }
  
  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    cameraFeedService.stopSession()
    clearFaceLandmarkerServiceOnSessionInterruption()
  }
  
  override func viewDidLoad() {
    super.viewDidLoad()
    cameraFeedService.delegate = self
    overlayView.delegate = self
    overlayView.instructionsDelegate = self
        
      overlayView.cameraFeedService = cameraFeedService
      
      NotificationCenter.default.addObserver(
              self,
              selector: #selector(orientationDidChange(_:)),
              name: UIDevice.orientationDidChangeNotification,
              object: nil
          )
      overlayView.presentAlert = { [weak self] title, message in
                  let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
                  alert.addAction(UIAlertAction(title: "OK", style: .default))
                  self?.present(alert, animated: true)
              }

    // Do any additional setup after loading the view.
  }
  
    deinit {
        NotificationCenter.default.removeObserver(self, name: UIDevice.orientationDidChangeNotification, object: nil)
    }
    
 override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    cameraFeedService.updateVideoPreviewLayer(toFrame: previewView.bounds)
    overlayView.presentInitialInstructions() // Call the method here
 }

  
  override func viewWillLayoutSubviews() {
    super.viewWillLayoutSubviews()
    cameraFeedService.updateVideoPreviewLayer(toFrame: previewView.bounds)
  }
#endif
  
  // Resume camera session when click button resume
  @IBAction func onClickResume(_ sender: Any) {
    cameraFeedService.resumeInterruptedSession {[weak self] isSessionRunning in
      if isSessionRunning {
        self?.resumeButton.isHidden = true
        self?.cameraUnavailableLabel.isHidden = true
        self?.initializeFaceLandmarkerServiceOnSessionResumption()
      }
    }
  }
  
  private func presentCameraPermissionsDeniedAlert() {
    let alertController = UIAlertController(
      title: "Camera Permissions Denied",
      message:
        "Camera permissions have been denied for this app. You can change this by going to Settings",
      preferredStyle: .alert)
    
    let cancelAction = UIAlertAction(title: "Cancel", style: .cancel, handler: nil)
    let settingsAction = UIAlertAction(title: "Settings", style: .default) { (action) in
      UIApplication.shared.open(
        URL(string: UIApplication.openSettingsURLString)!, options: [:], completionHandler: nil)
    }
    alertController.addAction(cancelAction)
    alertController.addAction(settingsAction)
    
    present(alertController, animated: true, completion: nil)
  }
  
  private func presentVideoConfigurationErrorAlert() {
    let alert = UIAlertController(
      title: "Camera Configuration Failed",
      message: "There was an error while configuring camera.",
      preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))
    
    self.present(alert, animated: true)
  }
  
  private func initializeFaceLandmarkerServiceOnSessionResumption() {
    clearAndInitializeFaceLandmarkerService()
    startObserveConfigChanges()
  }
  
    @objc func orientationDidChange(_ notification: Notification) {
        overlayView.realignDotsForNewOrientation()
    }

    
  @objc private func clearAndInitializeFaceLandmarkerService() {
    faceLandmarkerService = nil
    faceLandmarkerService = FaceLandmarkerService
      .liveStreamFaceLandmarkerService(
        modelPath: InferenceConfigurationManager.sharedInstance.modelPath,
        numFaces: InferenceConfigurationManager.sharedInstance.numFaces,
        minFaceDetectionConfidence: InferenceConfigurationManager.sharedInstance.minFaceDetectionConfidence,
        minFacePresenceConfidence: InferenceConfigurationManager.sharedInstance.minFacePresenceConfidence,
        minTrackingConfidence: InferenceConfigurationManager.sharedInstance.minTrackingConfidence,
        liveStreamDelegate: self)
  }
  
  private func clearFaceLandmarkerServiceOnSessionInterruption() {
    stopObserveConfigChanges()
    faceLandmarkerService = nil
  }
  
  private func startObserveConfigChanges() {
    NotificationCenter.default
      .addObserver(self,
                   selector: #selector(clearAndInitializeFaceLandmarkerService),
                   name: InferenceConfigurationManager.notificationName,
                   object: nil)
    isObserving = true
  }
  
  private func stopObserveConfigChanges() {
    if isObserving {
      NotificationCenter.default
        .removeObserver(self,
                        name:InferenceConfigurationManager.notificationName,
                        object: nil)
    }
    isObserving = false
  }
}

extension CameraViewController: CameraFeedServiceDelegate {
  
  func didOutput(sampleBuffer: CMSampleBuffer, orientation: UIImage.Orientation) {
    let currentTimeMs = Date().timeIntervalSince1970 * 1000
    // Pass the pixel buffer to mediapipe
    backgroundQueue.async { [weak self] in
      self?.faceLandmarkerService?.detectAsync(
        sampleBuffer: sampleBuffer,
        orientation: orientation,
        timeStamps: Int(currentTimeMs))
    }
  }
  
  // MARK: Session Handling Alerts
  func sessionWasInterrupted(canResumeManually resumeManually: Bool) {
    // Updates the UI when session is interupted.
    if resumeManually {
      resumeButton.isHidden = false
    } else {
      cameraUnavailableLabel.isHidden = false
    }
    clearFaceLandmarkerServiceOnSessionInterruption()
  }
  
  func sessionInterruptionEnded() {
    // Updates UI once session interruption has ended.
    cameraUnavailableLabel.isHidden = true
    resumeButton.isHidden = true
    initializeFaceLandmarkerServiceOnSessionResumption()
  }
  
  func didEncounterSessionRuntimeError() {
    // Handles session run time error by updating the UI and providing a button if session can be
    // manually resumed.
    resumeButton.isHidden = false
    clearFaceLandmarkerServiceOnSessionInterruption()
  }
}

// MARK: FaceLandmarkerServiceLiveStreamDelegate
extension CameraViewController: FaceLandmarkerServiceLiveStreamDelegate {

  func faceLandmarkerService(
    _ faceLandmarkerService: FaceLandmarkerService,
    didFinishDetection result: ResultBundle?,
    error: Error?) {
      DispatchQueue.main.async { [weak self] in
        guard let weakSelf = self else { return }
        weakSelf.inferenceResultDeliveryDelegate?.didPerformInference(result: result)
        guard let faceLandmarkerResult = result?.faceLandmarkerResults.first as? FaceLandmarkerResult else { return }
        let imageSize = weakSelf.cameraFeedService.videoResolution
        let faceOverlays = OverlayView.faceOverlays(
          fromMultipleFaceLandmarks: faceLandmarkerResult.faceLandmarks,
          inferredOnImageOfSize: imageSize,
          ovelayViewSize: weakSelf.overlayView.bounds.size,
          imageContentMode: weakSelf.overlayView.imageContentMode,
          andOrientation: UIImage.Orientation.from(
            deviceOrientation: UIDevice.current.orientation))
        weakSelf.overlayView.draw(faceOverlays: faceOverlays,
                         inBoundsOfContentImageOfSize: imageSize,
                         imageContentMode: weakSelf.cameraFeedService.videoGravity.contentMode)
        weakSelf.overlayView.updateYMarkPositions()
          weakSelf.overlayView.updateTargets()
      }
    }
}


extension CameraViewController: OverlayViewDelegate {
    func presentResultsViewController(with screenshot: UIImage?, scoreMessage: String?, onTargetInjections: [Injection]?) { // Modify this function to include onTargetInjections
        let storyboard = UIStoryboard(name: "Main", bundle: nil)
        if let resultsVC = storyboard.instantiateViewController(withIdentifier: "ResultsViewController") as? ResultsViewController {
            resultsVC.modalPresentationStyle = .fullScreen
            resultsVC.screenshot = screenshot
            resultsVC.scoreMessage = scoreMessage
            resultsVC.onTargetInjections = onTargetInjections // Pass the injections here
            self.present(resultsVC, animated: true, completion: nil)
        }
    }
}


extension CameraViewController: OverlayViewInstructionsDelegate {
    func presentInstructions(with message: [String]) {
        let instructionsVC = InstructionsViewController()
        instructionsVC.message = message
        instructionsVC.modalPresentationStyle = .formSheet // or .pageSheet

        instructionsVC.isModalInPresentation = false
        present(instructionsVC, animated: true)
    }
}



// MARK: - AVLayerVideoGravity Extension
extension AVLayerVideoGravity {
  var contentMode: UIView.ContentMode {
    switch self {
    case .resizeAspectFill:
      return .scaleAspectFill
    case .resizeAspect:
      return .scaleAspectFit
    case .resize:
      return .scaleToFill
    default:
      return .scaleAspectFill
    }
  }
}