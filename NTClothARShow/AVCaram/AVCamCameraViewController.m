/*
See LICENSE folder for this sample’s licensing information.

Abstract:
Implements the view controller for the camera interface.
*/
@import AVFoundation;
@import Photos;

#import "AVCamCameraViewController.h"
#import "AVCamPreviewView.h"
#import "AVCamPhotoCaptureDelegate.h"
#import "MobileNet.h"
#import <AVFoundation/AVFoundation.h>

static void*  SessionRunningContext = &SessionRunningContext;
static void*  SystemPressureContext = &SystemPressureContext;

typedef NS_ENUM(NSInteger, AVCamSetupResult) {
    AVCamSetupResultSuccess,
    AVCamSetupResultCameraNotAuthorized,
    AVCamSetupResultSessionConfigurationFailed
};

typedef NS_ENUM(NSInteger, AVCamCaptureMode) {
    AVCamCaptureModePhoto = 0,
    AVCamCaptureModeMovie = 1
};

typedef NS_ENUM(NSInteger, AVCamLivePhotoMode) {
    AVCamLivePhotoModeOn,
    AVCamLivePhotoModeOff
};

typedef NS_ENUM(NSInteger, AVCamDepthDataDeliveryMode) {
    AVCamDepthDataDeliveryModeOn,
    AVCamDepthDataDeliveryModeOff
};

typedef NS_ENUM(NSInteger, AVCamPortraitEffectsMatteDeliveryMode) {
    AVCamPortraitEffectsMatteDeliveryModeOn,
    AVCamPortraitEffectsMatteDeliveryModeOff
};

@interface AVCaptureDeviceDiscoverySession (Utilities)

- (NSInteger)uniqueDevicePositionsCount;

@end

@implementation AVCaptureDeviceDiscoverySession (Utilities)

- (NSInteger)uniqueDevicePositionsCount
{
    NSMutableArray<NSNumber* >* uniqueDevicePositions = [NSMutableArray array];
    
    for (AVCaptureDevice* device in self.devices) {
        if (![uniqueDevicePositions containsObject:@(device.position)]) {
            [uniqueDevicePositions addObject:@(device.position)];
        }
    }
    
    return uniqueDevicePositions.count;
}

@end

@interface AVCamCameraViewController () <AVCaptureFileOutputRecordingDelegate,AVCaptureVideoDataOutputSampleBufferDelegate>

// Session management.
@property (nonatomic, weak) IBOutlet AVCamPreviewView* previewView;
@property (nonatomic, weak) IBOutlet UISegmentedControl* captureModeControl;

@property (nonatomic) AVCamSetupResult setupResult;
@property (nonatomic) dispatch_queue_t sessionQueue;
@property (nonatomic) AVCaptureSession* session;
@property (nonatomic, getter=isSessionRunning) BOOL sessionRunning;
@property (nonatomic) AVCaptureDeviceInput* videoDeviceInput;

// Device configuration.
@property (nonatomic, weak) IBOutlet UIButton* cameraButton;
@property (nonatomic, weak) IBOutlet UILabel* cameraUnavailableLabel;
@property (nonatomic) AVCaptureDeviceDiscoverySession* videoDeviceDiscoverySession;

// Capturing photos.
@property (nonatomic, weak) IBOutlet UIButton* photoButton;
@property (nonatomic, weak) IBOutlet UIButton* livePhotoModeButton;
@property (nonatomic) AVCamLivePhotoMode livePhotoMode;
@property (nonatomic, weak) IBOutlet UILabel* capturingLivePhotoLabel;
@property (nonatomic, weak) IBOutlet UIButton* depthDataDeliveryButton;
@property (nonatomic) AVCamDepthDataDeliveryMode depthDataDeliveryMode;
@property (nonatomic, weak) IBOutlet UIButton* portraitEffectsMatteDeliveryButton;
@property (nonatomic) AVCamPortraitEffectsMatteDeliveryMode portraitEffectsMatteDeliveryMode;

@property (nonatomic) AVCapturePhotoOutput* photoOutput;
@property (nonatomic) AVCaptureVideoDataOutput* videoOutput;

@property (nonatomic) NSMutableDictionary<NSNumber* , AVCamPhotoCaptureDelegate* >* inProgressPhotoCaptureDelegates;
@property (nonatomic) NSInteger inProgressLivePhotoCapturesCount;

// Recording movies.
@property (nonatomic, weak) IBOutlet UIButton* recordButton;
@property (nonatomic, weak) IBOutlet UIButton* resumeButton;

@property (nonatomic, strong) AVCaptureMovieFileOutput* movieFileOutput;
@property (nonatomic) UIBackgroundTaskIdentifier backgroundRecordingID;

/**
 衣服分类
 */
@property (nonatomic, strong) NSArray *clothsCategories;

@property (nonatomic, strong) UIImageView *clothImageView;//展示图片

@property (strong, nonatomic)AVPlayer *myPlayer;//播放器
@property (strong, nonatomic)AVPlayerItem *item;//播放单元
@property (strong, nonatomic)AVPlayerLayer *playerLayer;//播放界面（layer）
@end

@implementation AVCamCameraViewController

#pragma mark View Controller Life Cycle

- (void) viewDidLoad
{
    [super viewDidLoad];
    
    // Disable UI. The UI is enabled if and only if the session starts running.
    self.cameraButton.enabled = NO;
    self.recordButton.enabled = NO;
    self.photoButton.enabled = NO;
    self.livePhotoModeButton.enabled = NO;
    self.captureModeControl.enabled = NO;
    self.depthDataDeliveryButton.enabled = NO;
    self.portraitEffectsMatteDeliveryButton.enabled = NO;
    
    self.recordButton.hidden = YES;
    self.captureModeControl.hidden = YES;
    self.livePhotoModeButton.hidden = YES;
    self.depthDataDeliveryButton.hidden = YES;
    self.portraitEffectsMatteDeliveryButton.hidden = YES;
    
    // Create the AVCaptureSession.
    self.session = [[AVCaptureSession alloc] init];
    
    // Create a device discovery session.
    NSArray<AVCaptureDeviceType>* deviceTypes = @[AVCaptureDeviceTypeBuiltInWideAngleCamera, AVCaptureDeviceTypeBuiltInDualCamera, AVCaptureDeviceTypeBuiltInTrueDepthCamera];
    self.videoDeviceDiscoverySession = [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:deviceTypes mediaType:AVMediaTypeVideo position:AVCaptureDevicePositionUnspecified];
    
    // Set up the preview view.
    self.previewView.session = self.session;
    
    // Communicate with the session and other session objects on this queue.
    self.sessionQueue = dispatch_queue_create("session queue", DISPATCH_QUEUE_SERIAL);
    
    self.setupResult = AVCamSetupResultSuccess;
    
    /*
     Check video authorization status. Video access is required and audio
     access is optional. If audio access is denied, audio is not recorded
     during movie recording.
    */
    switch ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo])
    {
        case AVAuthorizationStatusAuthorized:
        {
            // The user has previously granted access to the camera.
            break;
        }
        case AVAuthorizationStatusNotDetermined:
        {
            /*
             The user has not yet been presented with the option to grant
             video access. We suspend the session queue to delay session
             setup until the access request has completed.
             
             Note that audio access will be implicitly requested when we
             create an AVCaptureDeviceInput for audio during session setup.
            */
            dispatch_suspend(self.sessionQueue);
            [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
                if (!granted) {
                    self.setupResult = AVCamSetupResultCameraNotAuthorized;
                }
                dispatch_resume(self.sessionQueue);
            }];
            break;
        }
        default:
        {
            // The user has previously denied access.
            self.setupResult = AVCamSetupResultCameraNotAuthorized;
            break;
        }
    }
    
    /*
     Setup the capture session.
     In general, it is not safe to mutate an AVCaptureSession or any of its
     inputs, outputs, or connections from multiple threads at the same time.
     
     Don't perform these tasks on the main queue because
     AVCaptureSession.startRunning() is a blocking call, which can
     take a long time. We dispatch session setup to the sessionQueue, so
     that the main queue isn't blocked, which keeps the UI responsive.
    */
    dispatch_async(self.sessionQueue, ^{
        [self configureSession];
    });
}

- (void) viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    
    dispatch_async(self.sessionQueue, ^{
        switch (self.setupResult)
        {
            case AVCamSetupResultSuccess:
            {
                // Only setup observers and start the session running if setup succeeded.
                [self addObservers];
                [self.session startRunning];
                self.sessionRunning = self.session.isRunning;
                break;
            }
            case AVCamSetupResultCameraNotAuthorized:
            {
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSString* message = NSLocalizedString(@"AVCam doesn't have permission to use the camera, please change privacy settings", @"Alert message when the user has denied access to the camera");
                    UIAlertController* alertController = [UIAlertController alertControllerWithTitle:@"AVCam" message:message preferredStyle:UIAlertControllerStyleAlert];
                    UIAlertAction* cancelAction = [UIAlertAction actionWithTitle:NSLocalizedString(@"OK", @"Alert OK button") style:UIAlertActionStyleCancel handler:nil];
                    [alertController addAction:cancelAction];
                    // Provide quick access to Settings.
                    UIAlertAction* settingsAction = [UIAlertAction actionWithTitle:NSLocalizedString(@"Settings", @"Alert button to open Settings") style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
                        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:UIApplicationOpenSettingsURLString] options:@{} completionHandler:nil];
                    }];
                    [alertController addAction:settingsAction];
                    [self presentViewController:alertController animated:YES completion:nil];
                });
                break;
            }
            case AVCamSetupResultSessionConfigurationFailed:
            {
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSString* message = NSLocalizedString(@"Unable to capture media", @"Alert message when something goes wrong during capture session configuration");
                    UIAlertController* alertController = [UIAlertController alertControllerWithTitle:@"AVCam" message:message preferredStyle:UIAlertControllerStyleAlert];
                    UIAlertAction* cancelAction = [UIAlertAction actionWithTitle:NSLocalizedString(@"OK", @"Alert OK button") style:UIAlertActionStyleCancel handler:nil];
                    [alertController addAction:cancelAction];
                    [self presentViewController:alertController animated:YES completion:nil];
                });
                break;
            }
        }
    });
}

- (void) viewDidDisappear:(BOOL)animated
{
    dispatch_async(self.sessionQueue, ^{
        if (self.setupResult == AVCamSetupResultSuccess) {
            [self.session stopRunning];
            [self removeObservers];
        }
    });
    
    [super viewDidDisappear:animated];
}

- (BOOL) shouldAutorotate
{
    // Disable autorotation of the interface when recording is in progress.
    return !self.movieFileOutput.isRecording;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations
{
    return UIInterfaceOrientationMaskAll;
}

- (void) viewWillTransitionToSize:(CGSize)size
        withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator
{
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    
    UIDeviceOrientation deviceOrientation = [UIDevice currentDevice].orientation;
    
    if (UIDeviceOrientationIsPortrait(deviceOrientation) || UIDeviceOrientationIsLandscape(deviceOrientation)) {
        self.previewView.videoPreviewLayer.connection.videoOrientation = (AVCaptureVideoOrientation)deviceOrientation;
    }
}

#pragma mark 按钮事件
- (IBAction)onButtonActionClose:(id)sender{
    
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark Session Management

// Call this on the session queue.
- (void) configureSession
{
    if (self.setupResult != AVCamSetupResultSuccess) {
        return;
    }
    
    NSError* error = nil;
    
    [self.session beginConfiguration];
    
    /*
     We do not create an AVCaptureMovieFileOutput when setting up the session because
     Live Photo is not supported when AVCaptureMovieFileOutput is added to the session.
    */
    self.session.sessionPreset = AVCaptureSessionPresetPhoto;
    
    // Add video input.
    
    // Choose the back dual camera if available, otherwise default to a wide angle camera.
    AVCaptureDevice* videoDevice = [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInDualCamera mediaType:AVMediaTypeVideo position:AVCaptureDevicePositionBack];
    if (!videoDevice) {
        // If a rear dual camera is not available, default to the rear wide angle camera.
        videoDevice = [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera mediaType:AVMediaTypeVideo position:AVCaptureDevicePositionBack];
        
        // In the event that the rear wide angle camera isn't available, default to the front wide angle camera.
        if (!videoDevice) {
            videoDevice = [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera mediaType:AVMediaTypeVideo position:AVCaptureDevicePositionFront];
        }
    }
    AVCaptureDeviceInput* videoDeviceInput = [AVCaptureDeviceInput deviceInputWithDevice:videoDevice error:&error];
    if (!videoDeviceInput) {
        NSLog(@"Could not create video device input: %@", error);
        self.setupResult = AVCamSetupResultSessionConfigurationFailed;
        [self.session commitConfiguration];
        return;
    }
    if ([self.session canAddInput:videoDeviceInput]) {
        [self.session addInput:videoDeviceInput];
        self.videoDeviceInput = videoDeviceInput;
        
        dispatch_async(dispatch_get_main_queue(), ^{
            /*
             Dispatch video streaming to the main queue because AVCaptureVideoPreviewLayer is the backing layer for PreviewView.
             You can manipulate UIView only on the main thread.
             Note: As an exception to the above rule, it is not necessary to serialize video orientation changes
             on the AVCaptureVideoPreviewLayer’s connection with other session manipulation.
             
             Use the status bar orientation as the initial video orientation. Subsequent orientation changes are
             handled by CameraViewController.viewWillTransition(to:with:).
            */
            UIInterfaceOrientation statusBarOrientation = [UIApplication sharedApplication].statusBarOrientation;
            AVCaptureVideoOrientation initialVideoOrientation = AVCaptureVideoOrientationPortrait;
            if (statusBarOrientation != UIInterfaceOrientationUnknown) {
                initialVideoOrientation = (AVCaptureVideoOrientation)statusBarOrientation;
            }
            
            self.previewView.videoPreviewLayer.connection.videoOrientation = initialVideoOrientation;
        });
    }
    else {
        NSLog(@"Could not add video device input to the session");
        self.setupResult = AVCamSetupResultSessionConfigurationFailed;
        [self.session commitConfiguration];
        return;
    }
    
    // Add audio input.
    AVCaptureDevice* audioDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
    AVCaptureDeviceInput* audioDeviceInput = [AVCaptureDeviceInput deviceInputWithDevice:audioDevice error:&error];
    if (!audioDeviceInput) {
        NSLog(@"Could not create audio device input: %@", error);
    }
    if ([self.session canAddInput:audioDeviceInput]) {
        [self.session addInput:audioDeviceInput];
    }
    else {
        NSLog(@"Could not add audio device input to the session");
    }
    
    // Add photo output.
    AVCapturePhotoOutput* photoOutput = [[AVCapturePhotoOutput alloc] init];
    if ([self.session canAddOutput:photoOutput]) {
        [self.session addOutput:photoOutput];
        self.photoOutput = photoOutput;
        
        self.photoOutput.highResolutionCaptureEnabled = YES;
        self.photoOutput.livePhotoCaptureEnabled = self.photoOutput.livePhotoCaptureSupported;
        self.photoOutput.depthDataDeliveryEnabled = self.photoOutput.depthDataDeliverySupported;
        self.photoOutput.portraitEffectsMatteDeliveryEnabled = self.photoOutput.portraitEffectsMatteDeliverySupported;
        
        self.livePhotoMode = self.photoOutput.livePhotoCaptureSupported ? AVCamLivePhotoModeOn : AVCamLivePhotoModeOff;
        self.depthDataDeliveryMode = self.photoOutput.depthDataDeliverySupported ? AVCamDepthDataDeliveryModeOn : AVCamDepthDataDeliveryModeOff;
        self.portraitEffectsMatteDeliveryMode = self.photoOutput.portraitEffectsMatteDeliverySupported ? AVCamPortraitEffectsMatteDeliveryModeOn : AVCamPortraitEffectsMatteDeliveryModeOff;
        
        self.inProgressPhotoCaptureDelegates = [NSMutableDictionary dictionary];
        self.inProgressLivePhotoCapturesCount = 0;
    }
    else {
        NSLog(@"Could not add photo output to the session");
        self.setupResult = AVCamSetupResultSessionConfigurationFailed;
        [self.session commitConfiguration];
        return;
    }
    
    //添加视频流
    AVCaptureVideoDataOutput *videoOutput = [[AVCaptureVideoDataOutput alloc] init];
    if ([self.session canAddOutput:videoOutput]) {
        
        [self.session addOutput:videoOutput];
        // Configure your output.
        dispatch_queue_t queue = dispatch_queue_create("AVCaptureVideoDataOutput", NULL);
        [videoOutput setSampleBufferDelegate:self queue:queue];
        // Specify the pixel format
        videoOutput.videoSettings = [NSDictionary dictionaryWithObjectsAndKeys:
                                [NSNumber numberWithInt:kCVPixelFormatType_32BGRA], kCVPixelBufferPixelFormatTypeKey,
                                [NSNumber numberWithInt: 320], (id)kCVPixelBufferWidthKey,
                                [NSNumber numberWithInt: 240], (id)kCVPixelBufferHeightKey,
                                nil];
        // minFrameDuration.
        self.videoDeviceInput.device.activeVideoMinFrameDuration = CMTimeMake(1, 15);
        
        self.videoOutput = videoOutput;
    }
    
    self.backgroundRecordingID = UIBackgroundTaskInvalid;
    
    [self.session commitConfiguration];
}

- (IBAction) resumeInterruptedSession:(id)sender
{
    dispatch_async(self.sessionQueue, ^{
        /*
         The session might fail to start running, e.g., if a phone or FaceTime call is still
         using audio or video. A failure to start the session running will be communicated via
         a session runtime error notification. To avoid repeatedly failing to start the session
         running, we only try to restart the session running in the session runtime error handler
         if we aren't trying to resume the session running.
        */
        [self.session startRunning];
        self.sessionRunning = self.session.isRunning;
        if (!self.session.isRunning) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSString* message = NSLocalizedString(@"Unable to resume", @"Alert message when unable to resume the session running");
                UIAlertController* alertController = [UIAlertController alertControllerWithTitle:@"AVCam" message:message preferredStyle:UIAlertControllerStyleAlert];
                UIAlertAction* cancelAction = [UIAlertAction actionWithTitle:NSLocalizedString(@"OK", @"Alert OK button") style:UIAlertActionStyleCancel handler:nil];
                [alertController addAction:cancelAction];
                [self presentViewController:alertController animated:YES completion:nil];
            });
        }
        else {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.resumeButton.hidden = YES;
            });
        }
    });
}

- (IBAction) toggleCaptureMode:(UISegmentedControl*)captureModeControl
{
    if (captureModeControl.selectedSegmentIndex == AVCamCaptureModePhoto) {
        self.recordButton.enabled = NO;
        
        dispatch_async(self.sessionQueue, ^{
            /*
             Remove the AVCaptureMovieFileOutput from the session because Live Photo
             capture is not supported when an AVCaptureMovieFileOutput is connected to the session.
            */
            [self.session beginConfiguration];
            [self.session removeOutput:self.movieFileOutput];
            self.session.sessionPreset = AVCaptureSessionPresetPhoto;
            
            self.movieFileOutput = nil;
            
            if (self.photoOutput.livePhotoCaptureSupported) {
                self.photoOutput.livePhotoCaptureEnabled = YES;
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.livePhotoModeButton.enabled = YES;
                    self.livePhotoModeButton.hidden = NO;
                });
            }
            
            if (self.photoOutput.depthDataDeliverySupported) {
                self.photoOutput.depthDataDeliveryEnabled = YES;
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.depthDataDeliveryButton.hidden = NO;
                    self.depthDataDeliveryButton.enabled = YES;
                });
            }
            
            if (self.photoOutput.portraitEffectsMatteDeliverySupported) {
                self.photoOutput.portraitEffectsMatteDeliveryEnabled = YES;
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.portraitEffectsMatteDeliveryButton.hidden = NO;
                    self.portraitEffectsMatteDeliveryButton.enabled = YES;
                });
            }
            
            [self.session commitConfiguration];
        });
    }
    else if (captureModeControl.selectedSegmentIndex == AVCamCaptureModeMovie) {
        self.livePhotoModeButton.hidden = YES;
        self.depthDataDeliveryButton.hidden = YES;
        self.portraitEffectsMatteDeliveryButton.hidden = YES;
        
        dispatch_async(self.sessionQueue, ^{
            AVCaptureMovieFileOutput* movieFileOutput = [[AVCaptureMovieFileOutput alloc] init];
            
            if ([self.session canAddOutput:movieFileOutput])
            {
                [self.session beginConfiguration];
                [self.session addOutput:movieFileOutput];
                self.session.sessionPreset = AVCaptureSessionPresetHigh;
                AVCaptureConnection* connection = [movieFileOutput connectionWithMediaType:AVMediaTypeVideo];
                if (connection.isVideoStabilizationSupported) {
                    connection.preferredVideoStabilizationMode = AVCaptureVideoStabilizationModeAuto;
                }
                [self.session commitConfiguration];
                
                self.movieFileOutput = movieFileOutput;
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.recordButton.enabled = YES;
                });
            }
        });
    }
}

#pragma mark Device Configuration

- (IBAction) changeCamera:(id)sender
{
    self.cameraButton.enabled = NO;
    self.recordButton.enabled = NO;
    self.photoButton.enabled = NO;
    self.livePhotoModeButton.enabled = NO;
    self.captureModeControl.enabled = NO;
    
    dispatch_async(self.sessionQueue, ^{
        AVCaptureDevice* currentVideoDevice = self.videoDeviceInput.device;
        AVCaptureDevicePosition currentPosition = currentVideoDevice.position;
        
        AVCaptureDevicePosition preferredPosition;
        AVCaptureDeviceType preferredDeviceType;
        
        switch (currentPosition)
        {
            case AVCaptureDevicePositionUnspecified:
            case AVCaptureDevicePositionFront:
                preferredPosition = AVCaptureDevicePositionBack;
                preferredDeviceType = AVCaptureDeviceTypeBuiltInDualCamera;
                break;
            case AVCaptureDevicePositionBack:
                preferredPosition = AVCaptureDevicePositionFront;
                preferredDeviceType = AVCaptureDeviceTypeBuiltInTrueDepthCamera;
                break;
        }
        
        NSArray<AVCaptureDevice* >* devices = self.videoDeviceDiscoverySession.devices;
        AVCaptureDevice* newVideoDevice = nil;
        
        // First, look for a device with both the preferred position and device type.
        for (AVCaptureDevice* device in devices) {
            if (device.position == preferredPosition && [device.deviceType isEqualToString:preferredDeviceType]) {
                newVideoDevice = device;
                break;
            }
        }
        
        // Otherwise, look for a device with only the preferred position.
        if (!newVideoDevice) {
            for (AVCaptureDevice* device in devices) {
                if (device.position == preferredPosition) {
                    newVideoDevice = device;
                    break;
                }
            }
        }
        
        if (newVideoDevice) {
            AVCaptureDeviceInput* videoDeviceInput = [AVCaptureDeviceInput deviceInputWithDevice:newVideoDevice error:NULL];
            
            [self.session beginConfiguration];
            
            // Remove the existing device input first, since using the front and back camera simultaneously is not supported.
            [self.session removeInput:self.videoDeviceInput];
            
            if ([self.session canAddInput:videoDeviceInput]) {
                [[NSNotificationCenter defaultCenter] removeObserver:self name:AVCaptureDeviceSubjectAreaDidChangeNotification object:currentVideoDevice];
                
                [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(subjectAreaDidChange:) name:AVCaptureDeviceSubjectAreaDidChangeNotification object:newVideoDevice];
                
                [self.session addInput:videoDeviceInput];
                self.videoDeviceInput = videoDeviceInput;
            }
            else {
                [self.session addInput:self.videoDeviceInput];
            }
            
            AVCaptureConnection* movieFileOutputConnection = [self.movieFileOutput connectionWithMediaType:AVMediaTypeVideo];
            if (movieFileOutputConnection.isVideoStabilizationSupported) {
                movieFileOutputConnection.preferredVideoStabilizationMode = AVCaptureVideoStabilizationModeAuto;
            }
            
            /*
             Set Live Photo capture and depth data delivery if it is supported. When changing cameras, the
             `livePhotoCaptureEnabled` and `depthDataDeliveryEnabled` properties of the AVCapturePhotoOutput gets set to NO when
             a video device is disconnected from the session. After the new video device is
             added to the session, re-enable Live Photo capture and depth data delivery if they are supported.
            */
            self.photoOutput.livePhotoCaptureEnabled = self.photoOutput.livePhotoCaptureSupported;
            self.photoOutput.depthDataDeliveryEnabled = self.photoOutput.depthDataDeliverySupported;
            self.photoOutput.portraitEffectsMatteDeliveryEnabled = self.photoOutput.portraitEffectsMatteDeliverySupported;
            
            [self.session commitConfiguration];
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            self.cameraButton.enabled = YES;
            self.recordButton.enabled = self.captureModeControl.selectedSegmentIndex == AVCamCaptureModeMovie;
            self.photoButton.enabled = YES;
            self.livePhotoModeButton.enabled = YES;
            self.captureModeControl.enabled = YES;
            self.depthDataDeliveryButton.enabled = self.photoOutput.isDepthDataDeliveryEnabled;
            self.depthDataDeliveryButton.hidden = !self.photoOutput.depthDataDeliverySupported;
            self.portraitEffectsMatteDeliveryButton.enabled = self.photoOutput.isPortraitEffectsMatteDeliveryEnabled;
            self.portraitEffectsMatteDeliveryButton.hidden = !self.photoOutput.portraitEffectsMatteDeliverySupported;
        });
    });
}

- (IBAction) focusAndExposeTap:(UIGestureRecognizer*)gestureRecognizer
{
    CGPoint devicePoint = [self.previewView.videoPreviewLayer captureDevicePointOfInterestForPoint:[gestureRecognizer locationInView:gestureRecognizer.view]];
    [self focusWithMode:AVCaptureFocusModeAutoFocus exposeWithMode:AVCaptureExposureModeAutoExpose atDevicePoint:devicePoint monitorSubjectAreaChange:YES];
}

- (void) focusWithMode:(AVCaptureFocusMode)focusMode
        exposeWithMode:(AVCaptureExposureMode)exposureMode
         atDevicePoint:(CGPoint)point
monitorSubjectAreaChange:(BOOL)monitorSubjectAreaChange
{
    dispatch_async(self.sessionQueue, ^{
        AVCaptureDevice* device = self.videoDeviceInput.device;
        NSError* error = nil;
        if ([device lockForConfiguration:&error]) {
            /*
             Setting (focus/exposure)PointOfInterest alone does not initiate a (focus/exposure) operation.
             Call set(Focus/Exposure)Mode() to apply the new point of interest.
            */
            if (device.isFocusPointOfInterestSupported && [device isFocusModeSupported:focusMode]) {
                device.focusPointOfInterest = point;
                device.focusMode = focusMode;
            }
            
            if (device.isExposurePointOfInterestSupported && [device isExposureModeSupported:exposureMode]) {
                device.exposurePointOfInterest = point;
                device.exposureMode = exposureMode;
            }
            
            device.subjectAreaChangeMonitoringEnabled = monitorSubjectAreaChange;
            [device unlockForConfiguration];
        }
        else {
            NSLog(@"Could not lock device for configuration: %@", error);
        }
    });
}

#pragma mark Capturing Photos

- (IBAction) capturePhoto:(id)sender
{
    [self.session stopRunning];
    [self dismissViewControllerAnimated:YES completion:nil];
    return;
    /*
     Retrieve the video preview layer's video orientation on the main queue before
     entering the session queue. We do this to ensure UI elements are accessed on
     the main thread and session configuration is done on the session queue.
    */
    AVCaptureVideoOrientation videoPreviewLayerVideoOrientation = self.previewView.videoPreviewLayer.connection.videoOrientation;
    
    dispatch_async(self.sessionQueue, ^{
        
        // Update the photo output's connection to match the video orientation of the video preview layer.
        AVCaptureConnection* photoOutputConnection = [self.photoOutput connectionWithMediaType:AVMediaTypeVideo];
        photoOutputConnection.videoOrientation = videoPreviewLayerVideoOrientation;
        
        AVCapturePhotoSettings* photoSettings;
        // Capture HEIF photos when supported, with the flash set to enable auto- and high-resolution photos.
        if ([self.photoOutput.availablePhotoCodecTypes containsObject:AVVideoCodecTypeHEVC]) {
            photoSettings = [AVCapturePhotoSettings photoSettingsWithFormat:@{ AVVideoCodecKey : AVVideoCodecTypeHEVC }];
        }
        else {
            photoSettings = [AVCapturePhotoSettings photoSettings];
        }
        
        if (self.videoDeviceInput.device.isFlashAvailable) {
            photoSettings.flashMode = AVCaptureFlashModeAuto;
        }
        photoSettings.highResolutionPhotoEnabled = YES;
        if (photoSettings.availablePreviewPhotoPixelFormatTypes.count > 0) {
            photoSettings.previewPhotoFormat = @{ (NSString*)kCVPixelBufferPixelFormatTypeKey : photoSettings.availablePreviewPhotoPixelFormatTypes.firstObject };
        }
        if (self.livePhotoMode == AVCamLivePhotoModeOn && self.photoOutput.livePhotoCaptureSupported) { // Live Photo capture is not supported in movie mode.
            NSString* livePhotoMovieFileName = [NSUUID UUID].UUIDString;
            NSString* livePhotoMovieFilePath = [NSTemporaryDirectory() stringByAppendingPathComponent:[livePhotoMovieFileName stringByAppendingPathExtension:@"mov"]];
            photoSettings.livePhotoMovieFileURL = [NSURL fileURLWithPath:livePhotoMovieFilePath];
        }
        
        photoSettings.depthDataDeliveryEnabled = (self.depthDataDeliveryMode == AVCamDepthDataDeliveryModeOn && self.photoOutput.isDepthDataDeliveryEnabled);
        
        photoSettings.portraitEffectsMatteDeliveryEnabled = (self.portraitEffectsMatteDeliveryMode == AVCamPortraitEffectsMatteDeliveryModeOn && self.photoOutput.isPortraitEffectsMatteDeliveryEnabled);
        
        // Use a separate object for the photo capture delegate to isolate each capture life cycle.
        AVCamPhotoCaptureDelegate* photoCaptureDelegate = [[AVCamPhotoCaptureDelegate alloc] initWithRequestedPhotoSettings:photoSettings willCapturePhotoAnimation:^{
            dispatch_async(dispatch_get_main_queue(), ^{
                self.previewView.videoPreviewLayer.opacity = 0.0;
                [UIView animateWithDuration:0.25 animations:^{
                    self.previewView.videoPreviewLayer.opacity = 1.0;
                }];
            });
        } livePhotoCaptureHandler:^(BOOL capturing) {
            /*
             Because Live Photo captures can overlap, we need to keep track of the
             number of in progress Live Photo captures to ensure that the
             Live Photo label stays visible during these captures.
            */
            dispatch_async(self.sessionQueue, ^{
                if (capturing) {
                    self.inProgressLivePhotoCapturesCount++;
                }
                else {
                    self.inProgressLivePhotoCapturesCount--;
                }
                
                NSInteger inProgressLivePhotoCapturesCount = self.inProgressLivePhotoCapturesCount;
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (inProgressLivePhotoCapturesCount > 0) {
                        self.capturingLivePhotoLabel.hidden = NO;
                    }
                    else if (inProgressLivePhotoCapturesCount == 0) {
                        self.capturingLivePhotoLabel.hidden = YES;
                    }
                    else {
                        NSLog(@"Error: In progress Live Photo capture count is less than 0.");
                    }
                });
            });
        } completionHandler:^(AVCamPhotoCaptureDelegate* photoCaptureDelegate) {
            // When the capture is complete, remove a reference to the photo capture delegate so it can be deallocated.
            dispatch_async(self.sessionQueue, ^{
                self.inProgressPhotoCaptureDelegates[@(photoCaptureDelegate.requestedPhotoSettings.uniqueID)] = nil;
            });
        }];
        
        /*
         The Photo Output keeps a weak reference to the photo capture delegate so
         we store it in an array to maintain a strong reference to this object
         until the capture is completed.
        */
        self.inProgressPhotoCaptureDelegates[@(photoCaptureDelegate.requestedPhotoSettings.uniqueID)] = photoCaptureDelegate;
        
        [self.photoOutput capturePhotoWithSettings:photoSettings delegate:photoCaptureDelegate];
    });
}

- (IBAction) toggleLivePhotoMode:(UIButton*)livePhotoModeButton
{
    dispatch_async(self.sessionQueue, ^{
        self.livePhotoMode = (self.livePhotoMode == AVCamLivePhotoModeOn) ? AVCamLivePhotoModeOff : AVCamLivePhotoModeOn;
        AVCamLivePhotoMode livePhotoMode = self.livePhotoMode;
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (livePhotoMode == AVCamLivePhotoModeOn) {
                [self.livePhotoModeButton setImage:[UIImage imageNamed:@"LivePhotoON"] forState:UIControlStateNormal];
            }
            else {
                [self.livePhotoModeButton setImage:[UIImage imageNamed:@"LivePhotoOFF"] forState:UIControlStateNormal];
            }
        });
    });
}

- (IBAction) toggleDepthDataDeliveryMode:(UIButton*)depthDataDeliveryButton
{
    dispatch_async(self.sessionQueue, ^{
        self.depthDataDeliveryMode = (self.depthDataDeliveryMode == AVCamDepthDataDeliveryModeOn) ? AVCamDepthDataDeliveryModeOff : AVCamDepthDataDeliveryModeOn;
        AVCamDepthDataDeliveryMode depthDataDeliveryMode = self.depthDataDeliveryMode;
        if (depthDataDeliveryMode == AVCamDepthDataDeliveryModeOff) {
            self.portraitEffectsMatteDeliveryMode = AVCamPortraitEffectsMatteDeliveryModeOff;
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (depthDataDeliveryMode == AVCamDepthDataDeliveryModeOn) {
                [self.depthDataDeliveryButton setImage:[UIImage imageNamed:@"DepthON"] forState:UIControlStateNormal];
            }
            else {
                [self.depthDataDeliveryButton setImage:[UIImage imageNamed:@"DepthOFF"] forState:UIControlStateNormal];
                [self.portraitEffectsMatteDeliveryButton setImage:[UIImage imageNamed:@"PortraitMatteOFF"] forState:UIControlStateNormal];
            }
        });
    });
}

- (IBAction) togglePortraitEffectsMatteDeliveryMode:(UIButton*)portraitEffectsMatteDeliveryButton
{
    dispatch_async(self.sessionQueue, ^{
        if (self.portraitEffectsMatteDeliveryMode == AVCamPortraitEffectsMatteDeliveryModeOn) {
            self.portraitEffectsMatteDeliveryMode = AVCamPortraitEffectsMatteDeliveryModeOff;
        }
        else {
            self.portraitEffectsMatteDeliveryMode = (self.depthDataDeliveryMode == AVCamDepthDataDeliveryModeOff) ? AVCamPortraitEffectsMatteDeliveryModeOff : AVCamPortraitEffectsMatteDeliveryModeOn;
        }
        AVCamPortraitEffectsMatteDeliveryMode portraitEffectsMatteDeliveryMode = self.portraitEffectsMatteDeliveryMode;
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (portraitEffectsMatteDeliveryMode == AVCamPortraitEffectsMatteDeliveryModeOn) {
                [self.portraitEffectsMatteDeliveryButton setImage:[UIImage imageNamed:@"PortraitMatteON"] forState:UIControlStateNormal];
            }
            else {
                [self.portraitEffectsMatteDeliveryButton setImage:[UIImage imageNamed:@"PortraitMatteOFF"] forState:UIControlStateNormal];
            }
        });
    });
}

#pragma mark Recording Movies

- (IBAction) toggleMovieRecording:(id)sender
{
    /*
     Disable the Camera button until recording finishes, and disable
     the Record button until recording starts or finishes.
     
     See the AVCaptureFileOutputRecordingDelegate methods.
    */
    self.cameraButton.enabled = NO;
    self.recordButton.enabled = NO;
    self.captureModeControl.enabled = NO;
    
    /*
     Retrieve the video preview layer's video orientation on the main queue
     before entering the session queue. We do this to ensure UI elements are
     accessed on the main thread and session configuration is done on the session queue.
    */
    AVCaptureVideoOrientation videoPreviewLayerVideoOrientation = self.previewView.videoPreviewLayer.connection.videoOrientation;
    
    dispatch_async(self.sessionQueue, ^{
        if (!self.movieFileOutput.isRecording) {
            if ([UIDevice currentDevice].isMultitaskingSupported) {
                /*
                 Setup background task.
                 This is needed because the -[captureOutput:didFinishRecordingToOutputFileAtURL:fromConnections:error:]
                 callback is not received until AVCam returns to the foreground unless you request background execution time.
                 This also ensures that there will be time to write the file to the photo library when AVCam is backgrounded.
                 To conclude this background execution, -[endBackgroundTask:] is called in
                 -[captureOutput:didFinishRecordingToOutputFileAtURL:fromConnections:error:] after the recorded file has been saved.
                */
                self.backgroundRecordingID = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:nil];
            }
            
            // Update the orientation on the movie file output video connection before starting recording.
            AVCaptureConnection* movieFileOutputConnection = [self.movieFileOutput connectionWithMediaType:AVMediaTypeVideo];
            movieFileOutputConnection.videoOrientation = videoPreviewLayerVideoOrientation;
            
            // Use HEVC codec if supported
            if ([self.movieFileOutput.availableVideoCodecTypes containsObject:AVVideoCodecTypeHEVC]) {
                [self.movieFileOutput setOutputSettings:@{ AVVideoCodecKey : AVVideoCodecTypeHEVC } forConnection:movieFileOutputConnection];
            }
            
            // Start recording to a temporary file.
            NSString* outputFileName = [NSUUID UUID].UUIDString;
            NSString* outputFilePath = [NSTemporaryDirectory() stringByAppendingPathComponent:[outputFileName stringByAppendingPathExtension:@"mov"]];
            NSURL* outputURL = [NSURL fileURLWithPath:outputFilePath];
            [self.movieFileOutput startRecordingToOutputFileURL:outputURL recordingDelegate:self];
        }
        else {
            [self.movieFileOutput stopRecording];
        }
    });
}

- (void) captureOutput:(AVCaptureFileOutput*)captureOutput
didStartRecordingToOutputFileAtURL:(NSURL*)fileURL
       fromConnections:(NSArray*)connections
{
    // Enable the Record button to let the user stop recording.
    dispatch_async(dispatch_get_main_queue(), ^{
        self.recordButton.enabled = YES;
        [self.recordButton setImage:[UIImage imageNamed:@"CaptureStop"] forState:UIControlStateNormal];
    });
}

- (void) captureOutput:(AVCaptureFileOutput*)captureOutput
didFinishRecordingToOutputFileAtURL:(NSURL*)outputFileURL
       fromConnections:(NSArray*)connections
                 error:(NSError*)error
{
    /*
     currentBackgroundRecordingID is used to end the background task
     associated with the current recording. It allows a new recording to be started
     and associated with a new UIBackgroundTaskIdentifier, once the movie file output's
     `recording` property is back to NO.
     Since a unique file path for each recording is used, a new recording will
     not overwrite a recording currently being saved.
    */
    UIBackgroundTaskIdentifier currentBackgroundRecordingID = self.backgroundRecordingID;
    self.backgroundRecordingID = UIBackgroundTaskInvalid;
    
    dispatch_block_t cleanUp = ^{
        if ([[NSFileManager defaultManager] fileExistsAtPath:outputFileURL.path]) {
            [[NSFileManager defaultManager] removeItemAtPath:outputFileURL.path error:NULL];
        }
        
        if (currentBackgroundRecordingID != UIBackgroundTaskInvalid) {
            [[UIApplication sharedApplication] endBackgroundTask:currentBackgroundRecordingID];
        }
    };
    
    BOOL success = YES;
    
    if (error) {
        NSLog(@"Movie file finishing error: %@", error);
        success = [error.userInfo[AVErrorRecordingSuccessfullyFinishedKey] boolValue];
    }
    if (success) {
        // Check authorization status.
        [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus status) {
            if (status == PHAuthorizationStatusAuthorized) {
                // Save the movie file to the photo library and cleanup.
                [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
                    PHAssetResourceCreationOptions* options = [[PHAssetResourceCreationOptions alloc] init];
                    options.shouldMoveFile = YES;
                    PHAssetCreationRequest* creationRequest = [PHAssetCreationRequest creationRequestForAsset];
                    [creationRequest addResourceWithType:PHAssetResourceTypeVideo fileURL:outputFileURL options:options];
                } completionHandler:^(BOOL success, NSError* error) {
                    if (!success) {
                        NSLog(@"AVCam couldn't save the movie to your photo library: %@", error);
                    }
                    cleanUp();
                }];
            }
            else {
                cleanUp();
            }
        }];
    }
    else {
        cleanUp();
    }
    
    // Enable the Camera and Record buttons to let the user switch camera and start another recording.
    dispatch_async(dispatch_get_main_queue(), ^{
        // Only enable the ability to change camera if the device has more than one camera.
        self.cameraButton.enabled = (self.videoDeviceDiscoverySession.uniqueDevicePositionsCount > 1);
        self.recordButton.enabled = YES;
        self.captureModeControl.enabled = YES;
        [self.recordButton setImage:[UIImage imageNamed:@"CaptureVideo"] forState:UIControlStateNormal];
    });
}

#pragma mark AVCaptureVideoDataOutputSampleBufferDelegate
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection{
    
    UIImage *outputImage = [self imageFromSampleBuffer:sampleBuffer];
    NSLog(@"%@",outputImage);
    CVPixelBufferRef referenceImageBufferRef = [self pixelBufferFromCGImage:outputImage.CGImage];
    if (referenceImageBufferRef) {
        
        MobileNet *mobileNetModel = [[MobileNet alloc] init];
        NSError *error = nil;
        MobileNetOutput *mobileNetOutput = [mobileNetModel predictionFromImage:referenceImageBufferRef error:&error];
        if (!error) {
            
            NSLog(@"%@",mobileNetOutput.classLabel);
//            NSLog(@"%@",mobileNetOutput.classLabelProbs);
            if ([self isClothsCategory:mobileNetOutput.classLabel]) {
                //通知主线程刷新
                dispatch_async(dispatch_get_main_queue(), ^{
                    
                    UIAlertController* alertController = [UIAlertController alertControllerWithTitle:@"识别到衣服" message:mobileNetOutput.classLabel preferredStyle:UIAlertControllerStyleAlert];
                    UIAlertAction* cancelAction = [UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleCancel handler:^(UIAlertAction * _Nonnull action) {
                        
                        if ([action.title isEqualToString:@"确定"]) {
                            
                            //展示图片
                            [self.clothImageView setImage:[UIImage imageNamed:@"cloth"]];
                            
                            [self.session startRunning];
                            
                            //播放视频
                            if (self.myPlayer) {
                                
                                [self.myPlayer pause];
                                self.myPlayer = nil;
                                [self.playerLayer removeFromSuperlayer];
                            }
                            // 1.获取URL(远程/本地)
                             NSURL *url = [[NSBundle mainBundle] URLForResource:@"testAir.mp4" withExtension:nil];
//                            NSURL *url = [NSURL URLWithString:@"http://v1.mukewang.com/a45016f4-08d6-4277-abe6-bcfd5244c201/L.mp4"];
                            // 2.创建AVPlayerItem
                            AVPlayerItem *item = [AVPlayerItem playerItemWithURL:url];
                            // 3.创建AVPlayer
                            self.myPlayer = [AVPlayer playerWithPlayerItem:item];
                            // 4.添加AVPlayerLayer
                            AVPlayerLayer *layer = [AVPlayerLayer playerLayerWithPlayer:self.myPlayer];
                            layer.frame = CGRectMake(0, 0, self.view.bounds.size.width, self.view.bounds.size.height/2.0);
                            self.playerLayer = layer;
                            [self.previewView.layer addSublayer:self.playerLayer];
                            [self.myPlayer play];
                        }
                    }];
                    [alertController addAction:cancelAction];
                    [self.session stopRunning];
                    [self presentViewController:alertController animated:YES completion:nil];
                });
            }
            
        }else{
            
            NSLog(@"%@",error.description);
        }
    }
}

#pragma mark KVO and Notifications

- (void) addObservers
{
    [self.session addObserver:self forKeyPath:@"running" options:NSKeyValueObservingOptionNew context:SessionRunningContext];
    [self addObserver:self forKeyPath:@"videoDeviceInput.device.systemPressureState" options:NSKeyValueObservingOptionNew context:SystemPressureContext];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(subjectAreaDidChange:) name:AVCaptureDeviceSubjectAreaDidChangeNotification object:self.videoDeviceInput.device];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(sessionRuntimeError:) name:AVCaptureSessionRuntimeErrorNotification object:self.session];
    
    /*
     A session can only run when the app is full screen. It will be interrupted
     in a multi-app layout, introduced in iOS 9, see also the documentation of
     AVCaptureSessionInterruptionReason. Add observers to handle these session
     interruptions and show a preview is paused message. See the documentation
     of AVCaptureSessionWasInterruptedNotification for other interruption reasons.
    */
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(sessionWasInterrupted:) name:AVCaptureSessionWasInterruptedNotification object:self.session];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(sessionInterruptionEnded:) name:AVCaptureSessionInterruptionEndedNotification object:self.session];
}

- (void) removeObservers
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    
    [self.session removeObserver:self forKeyPath:@"running" context:SessionRunningContext];
    [self removeObserver:self forKeyPath:@"videoDeviceInput.device.systemPressureState" context:SystemPressureContext];
}

- (void) observeValueForKeyPath:(NSString*)keyPath
                       ofObject:(id)object
                         change:(NSDictionary*)change
                        context:(void*)context
{
    if (context == SessionRunningContext) {
        BOOL isSessionRunning = [change[NSKeyValueChangeNewKey] boolValue];
        BOOL livePhotoCaptureSupported = self.photoOutput.livePhotoCaptureSupported;
        BOOL livePhotoCaptureEnabled = self.photoOutput.livePhotoCaptureEnabled;
        BOOL depthDataDeliverySupported = self.photoOutput.depthDataDeliverySupported;
        BOOL depthDataDeliveryEnabled = self.photoOutput.depthDataDeliveryEnabled;
        BOOL portraitEffectsMatteDeliverySupported = self.photoOutput.portraitEffectsMatteDeliverySupported;
        BOOL portraitEffectsMatteDeliveryEnabled = self.photoOutput.portraitEffectsMatteDeliveryEnabled;
        
        dispatch_async(dispatch_get_main_queue(), ^{
            // Only enable the ability to change camera if the device has more than one camera.
            self.cameraButton.enabled = isSessionRunning && (self.videoDeviceDiscoverySession.uniqueDevicePositionsCount > 1);
            self.recordButton.enabled = isSessionRunning && (self.captureModeControl.selectedSegmentIndex == AVCamCaptureModeMovie);
            self.photoButton.enabled = isSessionRunning;
            self.captureModeControl.enabled = isSessionRunning;
            self.livePhotoModeButton.enabled = isSessionRunning && livePhotoCaptureEnabled;
            self.livePhotoModeButton.hidden = !(isSessionRunning && livePhotoCaptureSupported);
            self.depthDataDeliveryButton.enabled = isSessionRunning && depthDataDeliveryEnabled ;
            self.depthDataDeliveryButton.hidden = !(isSessionRunning && depthDataDeliverySupported);
            self.portraitEffectsMatteDeliveryButton.enabled = isSessionRunning && portraitEffectsMatteDeliveryEnabled;
            self.portraitEffectsMatteDeliveryButton.hidden = !(isSessionRunning && portraitEffectsMatteDeliverySupported);
        });
    }
    else if (context == SystemPressureContext) {
        AVCaptureSystemPressureState* systemPressureState = change[NSKeyValueChangeNewKey];
        [self setRecommendedFrameRateRangeForPressureState:systemPressureState];
    }
    else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

- (void) subjectAreaDidChange:(NSNotification*)notification
{
    CGPoint devicePoint = CGPointMake(0.5, 0.5);
    [self focusWithMode:AVCaptureFocusModeContinuousAutoFocus exposeWithMode:AVCaptureExposureModeContinuousAutoExposure atDevicePoint:devicePoint monitorSubjectAreaChange:NO];
}

- (void) sessionRuntimeError:(NSNotification*)notification
{
    NSError* error = notification.userInfo[AVCaptureSessionErrorKey];
    NSLog(@"Capture session runtime error: %@", error);
    
    // If media services were reset, and the last start succeeded, restart the session.
    if (error.code == AVErrorMediaServicesWereReset) {
        dispatch_async(self.sessionQueue, ^{
            if (self.isSessionRunning) {
                [self.session startRunning];
                self.sessionRunning = self.session.isRunning;
            }
            else {
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.resumeButton.hidden = NO;
                });
            }
        });
    }
    else {
        self.resumeButton.hidden = NO;
    }
}

- (void) setRecommendedFrameRateRangeForPressureState:(AVCaptureSystemPressureState*)systemPressureState
{
    /*
     The frame rates used here are for demonstrative purposes only for this app.
     Your frame rate throttling may be different depending on your app's camera configuration.
    */
    AVCaptureSystemPressureLevel pressureLevel = [systemPressureState level];
    if (pressureLevel == AVCaptureSystemPressureLevelSerious || pressureLevel == AVCaptureSystemPressureLevelCritical) {
        if (![self.movieFileOutput isRecording] && [self.videoDeviceInput.device lockForConfiguration:nil]) {
            NSLog(@"WARNING: Reached elevated system pressure level: %@. Throttling frame rate.", pressureLevel);
            self.videoDeviceInput.device.activeVideoMinFrameDuration = CMTimeMake(1, 20);
            self.videoDeviceInput.device.activeVideoMaxFrameDuration = CMTimeMake(1, 15);
            [self.videoDeviceInput.device unlockForConfiguration];
        }
    }
    else if (pressureLevel == AVCaptureSystemPressureLevelShutdown) {
        NSLog(@"Session stopped running due to shutdown system pressure level.");
    }
}

- (void) sessionWasInterrupted:(NSNotification*)notification
{
    /*
     In some scenarios we want to enable the user to resume the session running.
     For example, if music playback is initiated via control center while
     using AVCam, then the user can let AVCam resume
     the session running, which will stop music playback. Note that stopping
     music playback in control center will not automatically resume the session
     running. Also note that it is not always possible to resume, see -[resumeInterruptedSession:].
    */
    BOOL showResumeButton = NO;
    
    AVCaptureSessionInterruptionReason reason = [notification.userInfo[AVCaptureSessionInterruptionReasonKey] integerValue];
    NSLog(@"Capture session was interrupted with reason %ld", (long)reason);
    
    if (reason == AVCaptureSessionInterruptionReasonAudioDeviceInUseByAnotherClient ||
        reason == AVCaptureSessionInterruptionReasonVideoDeviceInUseByAnotherClient) {
        showResumeButton = YES;
    }
    else if (reason == AVCaptureSessionInterruptionReasonVideoDeviceNotAvailableWithMultipleForegroundApps) {
        // Fade-in a label to inform the user that the camera is unavailable.
        self.cameraUnavailableLabel.alpha = 0.0;
        self.cameraUnavailableLabel.hidden = NO;
        [UIView animateWithDuration:0.25 animations:^{
            self.cameraUnavailableLabel.alpha = 1.0;
        }];
    }
    else if (reason == AVCaptureSessionInterruptionReasonVideoDeviceNotAvailableDueToSystemPressure) {
        NSLog(@"Session stopped running due to shutdown system pressure level.");
    }
    
    if (showResumeButton) {
        // Fade-in a button to enable the user to try to resume the session running.
        self.resumeButton.alpha = 0.0;
        self.resumeButton.hidden = NO;
        [UIView animateWithDuration:0.25 animations:^{
            self.resumeButton.alpha = 1.0;
        }];
    }
}

- (void) sessionInterruptionEnded:(NSNotification*)notification
{
    NSLog(@"Capture session interruption ended");
    
    if (!self.resumeButton.hidden) {
        [UIView animateWithDuration:0.25 animations:^{
            self.resumeButton.alpha = 0.0;
        } completion:^(BOOL finished) {
            self.resumeButton.hidden = YES;
        }];
    }
    if (!self.cameraUnavailableLabel.hidden) {
        [UIView animateWithDuration:0.25 animations:^{
            self.cameraUnavailableLabel.alpha = 0.0;
        } completion:^(BOOL finished) {
            self.cameraUnavailableLabel.hidden = YES;
        }];
    }
}

#pragma mark 衣服分类校验
- (UIImageView *)clothImageView{
    
    if (!_clothImageView) {
        
        UIImageView *clothImageView = [[UIImageView alloc] initWithFrame:CGRectMake(self.previewView.frame.size.width-100, 0, 100, 100)];
        _clothImageView = clothImageView;
        [self.previewView addSubview:_clothImageView];
    }
    return _clothImageView;
}

- (BOOL)isClothsCategory:(NSString *)categoryName{
    
    BOOL isExist = NO;
    if (!_clothsCategories) {
        
        _clothsCategories = [self clothsCategories];
    }
    for (NSString *clothCategory in _clothsCategories) {
        
        if ([categoryName containsString:clothCategory]) {
            
            isExist = YES;
            break;
        }
    }
    return isExist;
}

- (NSArray *)clothsCategories{
    
    /*@"男衬衣shirt、女衬衣blouse、长裤pants、短裤shorts、牛仔裤jeans、T恤T-shirt、大衣coat、西服suit、内衣underwear、毛衣swear、短裙skirt、连衣裙dress
     羽绒服down cost、夹克衫jacket、背心vest、西裤trousers、连衣裤overalls、鞋shoe、包ticket、外套wrap、上衣doublet\tops、下装bottoms、运动衫jersey、羊毛衫cardigan、毛线衫sweater",
     */
    NSString *clothsCategory = @"shirt,blouse,pants,shorts,jeans,coat,suit,underwear,swear,skirt,dress,jacket,down,vest,trousers,overalls,shoe,ticket,wrap,logo,doublet,tops,bottoms,jersey,cardigan,sweater";
    NSArray *clothsCategories = [clothsCategory componentsSeparatedByString:@","];
    return clothsCategories;
}

// Create a UIImage from sample buffer data
- (UIImage *) imageFromSampleBuffer:(CMSampleBufferRef) sampleBuffer
{
    // Get a CMSampleBuffer's Core Video image buffer for the media data
    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    // Lock the base address of the pixel buffer
    CVPixelBufferLockBaseAddress(imageBuffer, 0);
    
    // Get the number of bytes per row for the pixel buffer
    void *baseAddress = CVPixelBufferGetBaseAddress(imageBuffer);
    
    // Get the number of bytes per row for the pixel buffer
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer);
    // Get the pixel buffer width and height
    size_t width = CVPixelBufferGetWidth(imageBuffer);
    size_t height = CVPixelBufferGetHeight(imageBuffer);
    
    // Create a device-dependent RGB color space
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    
    // Create a bitmap graphics context with the sample buffer data
    CGContextRef context = CGBitmapContextCreate(baseAddress, width, height, 8,
                                                 bytesPerRow, colorSpace, kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    // Create a Quartz image from the pixel data in the bitmap graphics context
    CGImageRef quartzImage = CGBitmapContextCreateImage(context);
    // Unlock the pixel buffer
    CVPixelBufferUnlockBaseAddress(imageBuffer,0);
    
    // Free up the context and color space
    CGContextRelease(context);
    CGColorSpaceRelease(colorSpace);
    
    // Create an image object from the Quartz image
    UIImage *image = [UIImage imageWithCGImage:quartzImage];
    
    // Release the Quartz image
    CGImageRelease(quartzImage);
    
    return (image);
}

- (CVPixelBufferRef)pixelBufferFromCGImage:(CGImageRef)image{
    
    NSDictionary *options = [NSDictionary dictionaryWithObjectsAndKeys:
                             [NSNumber numberWithBool:YES], kCVPixelBufferCGImageCompatibilityKey,
                             [NSNumber numberWithBool:YES], kCVPixelBufferCGBitmapContextCompatibilityKey,
                             nil];
    
    CVPixelBufferRef pxbuffer = NULL;
    
    CGFloat frameWidth = 224;//CGImageGetWidth(image);
    CGFloat frameHeight = 224;//CGImageGetHeight(image);
    
    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault,
                                          frameWidth,
                                          frameHeight,
                                          kCVPixelFormatType_32ARGB,
                                          (__bridge CFDictionaryRef) options,
                                          &pxbuffer);
    
    NSParameterAssert(status == kCVReturnSuccess && pxbuffer != NULL);
    
    CVPixelBufferLockBaseAddress(pxbuffer, 0);
    void *pxdata = CVPixelBufferGetBaseAddress(pxbuffer);
    NSParameterAssert(pxdata != NULL);
    
    CGColorSpaceRef rgbColorSpace = CGColorSpaceCreateDeviceRGB();
    
    CGContextRef context = CGBitmapContextCreate(pxdata,
                                                 frameWidth,
                                                 frameHeight,
                                                 8,
                                                 CVPixelBufferGetBytesPerRow(pxbuffer),
                                                 rgbColorSpace,
                                                 (CGBitmapInfo)kCGImageAlphaNoneSkipFirst);
    NSParameterAssert(context);
    CGContextConcatCTM(context, CGAffineTransformIdentity);
    CGContextDrawImage(context, CGRectMake(0,
                                           0,
                                           frameWidth,
                                           frameHeight),
                       image);
    CGColorSpaceRelease(rgbColorSpace);
    CGContextRelease(context);
    
    CVPixelBufferUnlockBaseAddress(pxbuffer, 0);
    
    return pxbuffer;
}

#pragma mark 在相机上添加视频流
- (void)d{
    
    
}
@end
