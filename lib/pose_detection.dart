import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:google_ml_kit/google_ml_kit.dart';
import 'dart:io';
import 'dart:async';
import 'dart:typed_data';
import 'dart:math' as math;

class PoseDetectionScreen extends StatefulWidget {
  @override
  _PoseDetectionScreenState createState() => _PoseDetectionScreenState();
}

class _PoseDetectionScreenState extends State<PoseDetectionScreen> {
  CameraController? _cameraController;
  PoseDetector? _poseDetector;
  bool _isBusy = false;
  List<Pose>? _poses;
  Size? _imageSize;
  String _poseCategory = "Initializing...";
  int _cameraRotation = 0;
  bool _isDetectorReady = false;
  String _debugInfo = "";
  Timer? _frameProcessTimer;
  bool _processingEnabled = true;

  @override
  void initState() {
    super.initState();
    _initializeDetector();
    _initializeCamera();
  }

  void _initializeDetector() {
    try {
      // Initialize with base options using a more accurate model
      final options = PoseDetectorOptions();
      _poseDetector = GoogleMlKit.vision.poseDetector();
      _isDetectorReady = true;
      print("Pose detector initialized successfully");
    } catch (e) {
      print("Error initializing pose detector: $e");
      _debugInfo = "Detector error: $e";
    }
  }

  Future<void> _initializeCamera() async {
    try {
      final cameras = await availableCameras();
      final camera = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      _cameraRotation = camera.sensorOrientation;
      print('Camera rotation: $_cameraRotation');

      _cameraController = CameraController(
        camera,
        ResolutionPreset.high, // Use higher resolution for better accuracy
        enableAudio: false,
      );

      await _cameraController!.initialize();
      if (!mounted) return;

      await _cameraController!.lockCaptureOrientation(
        DeviceOrientation.portraitUp,
      );

      // Use a faster frame rate for more responsive tracking
      _frameProcessTimer = Timer.periodic(Duration(milliseconds: 300), (_) {
        if (_processingEnabled && !_isBusy && _isDetectorReady) {
          _captureAndProcessImage();
        }
      });

      setState(() {});
    } catch (e) {
      print("Camera initialization error: $e");
      _debugInfo = "Camera error: $e";
    }
  }

  Future<void> _captureAndProcessImage() async {
    if (_isBusy ||
        !_isDetectorReady ||
        _cameraController == null ||
        !_cameraController!.value.isInitialized) {
      return;
    }

    _isBusy = true;

    try {
      // Take a picture
      final xFile = await _cameraController!.takePicture();

      // Process the image file
      final inputImage = InputImage.fromFilePath(xFile.path);

      // Process with the detector
      final poses = await _poseDetector!.processImage(inputImage);

      print(
        'Poses detected: ${poses.length}, landmarks: ${poses.isNotEmpty ? poses[0].landmarks.length : 0}',
      );

      if (poses.isNotEmpty && mounted) {
        final poseCategory = _classifyPose(poses);

        // Get image size from file
        final file = File(xFile.path);
        final decodedImage = await decodeImageFromList(file.readAsBytesSync());
        final imageSize = Size(
          decodedImage.width.toDouble(),
          decodedImage.height.toDouble(),
        );

        setState(() {
          _poses = poses;
          _imageSize = imageSize;
          _poseCategory = poseCategory;
          _debugInfo =
              "Points: ${poses[0].landmarks.length}, Processing successful";
        });
      } else {
        setState(() {
          _poseCategory = "No pose detected";
          _debugInfo = "No landmarks found in frame";
        });
      }

      // Delete the temporary file
      File(xFile.path).delete().ignore();
    } catch (e) {
      print('Error processing image: $e');
      setState(() {
        _debugInfo = "Process error: $e";
      });
    } finally {
      _isBusy = false;
    }
  }

  String _classifyPose(List<Pose> poses) {
    if (poses.isEmpty) return "No Pose";

    final pose = poses[0];
    if (pose.landmarks.length < 11) {
      return "Insufficient landmarks";
    }

    // Get key landmarks
    final leftShoulder = pose.landmarks[PoseLandmarkType.leftShoulder];
    final rightShoulder = pose.landmarks[PoseLandmarkType.rightShoulder];
    final leftHip = pose.landmarks[PoseLandmarkType.leftHip];
    final rightHip = pose.landmarks[PoseLandmarkType.rightHip];
    final leftKnee = pose.landmarks[PoseLandmarkType.leftKnee];
    final rightKnee = pose.landmarks[PoseLandmarkType.rightKnee];
    final leftAnkle = pose.landmarks[PoseLandmarkType.leftAnkle];
    final rightAnkle = pose.landmarks[PoseLandmarkType.rightAnkle];
    final leftWrist = pose.landmarks[PoseLandmarkType.leftWrist];
    final rightWrist = pose.landmarks[PoseLandmarkType.rightWrist];
    final nose = pose.landmarks[PoseLandmarkType.nose];

    // Calculate confidence - we need core landmarks
    if (leftShoulder == null ||
        rightShoulder == null ||
        leftHip == null ||
        rightHip == null) {
      return "Missing core landmarks";
    }

    // Calculate angles for better pose detection
    double shoulderAngle = _calculateAngleBetweenPoints(
      leftShoulder.x,
      leftShoulder.y,
      rightShoulder.x,
      rightShoulder.y,
      rightShoulder.x,
      rightShoulder.y + 100,
    );

    double leftElbowAngle = 0;
    double rightElbowAngle = 0;
    double leftKneeAngle = 0;
    double rightKneeAngle = 0;
    double leftHipAngle = 0;
    double rightHipAngle = 0;

    final leftElbow = pose.landmarks[PoseLandmarkType.leftElbow];
    final rightElbow = pose.landmarks[PoseLandmarkType.rightElbow];

    // Calculate joint angles
    if (leftShoulder != null && leftElbow != null && leftWrist != null) {
      leftElbowAngle = _calculateAngle(leftShoulder, leftElbow, leftWrist);
    }

    if (rightShoulder != null && rightElbow != null && rightWrist != null) {
      rightElbowAngle = _calculateAngle(rightShoulder, rightElbow, rightWrist);
    }

    if (leftHip != null && leftKnee != null && leftAnkle != null) {
      leftKneeAngle = _calculateAngle(leftHip, leftKnee, leftAnkle);
    }

    if (rightHip != null && rightKnee != null && rightAnkle != null) {
      rightKneeAngle = _calculateAngle(rightHip, rightKnee, rightAnkle);
    }

    // Calculate hip angles for sitting detection
    if (leftShoulder != null && leftHip != null && leftKnee != null) {
      leftHipAngle = _calculateAngle(leftShoulder, leftHip, leftKnee);
    }

    if (rightShoulder != null && rightHip != null && rightKnee != null) {
      rightHipAngle = _calculateAngle(rightShoulder, rightHip, rightKnee);
    }

    // Average positions for better classification
    final double shoulderY = (leftShoulder.y + rightShoulder.y) / 2;
    final double hipY = (leftHip.y + rightHip.y) / 2;
    final double shoulderX = (leftShoulder.x + rightShoulder.x) / 2;
    final double hipX = (leftHip.x + rightHip.x) / 2;

    // Measure key distances and angles
    final double torsoLength = (hipY - shoulderY).abs();
    final double spineAngle =
        math.atan2(hipX - shoulderX, hipY - shoulderY) * 180 / math.pi;

    // Get knee positions if available
    double? kneeY;
    if (leftKnee != null && rightKnee != null) {
      kneeY = (leftKnee.y + rightKnee.y) / 2;
    }

    // Get ankle positions if available
    double? ankleY;
    if (leftAnkle != null && rightAnkle != null) {
      ankleY = (leftAnkle.y + rightAnkle.y) / 2;
    }

    // Check hand positions for specific poses
    final areHandsRaised =
        leftWrist != null &&
        rightWrist != null &&
        leftWrist.y < shoulderY - 30 &&
        rightWrist.y < shoulderY - 30;

    final areHandsOut =
        leftWrist != null &&
        rightWrist != null &&
        (leftWrist.x < leftShoulder.x - 50 ||
            rightWrist.x > rightShoulder.x + 50);

    // Debug print of key angles and positions for understanding the pose
    print(
      "Knee angles: L=${leftKneeAngle.toStringAsFixed(1)}, R=${rightKneeAngle.toStringAsFixed(1)}",
    );
    print(
      "Hip angles: L=${leftHipAngle.toStringAsFixed(1)}, R=${rightHipAngle.toStringAsFixed(1)}",
    );
    print(
      "Y positions: Shoulder=${shoulderY.toStringAsFixed(1)}, Hip=${hipY.toStringAsFixed(1)}, Knee=${kneeY?.toStringAsFixed(1)}",
    );

    // IMPROVED SITTING DETECTION - multiple criteria
    // 1. Hip angles are typically around 90-120 degrees when sitting
    // 2. Knee angles are typically around 70-100 degrees when sitting
    // 3. Hip-knee vertical distance is smaller when sitting
    bool isSittingByHipAngle =
        (leftHipAngle > 70 && leftHipAngle < 140) ||
        (rightHipAngle > 70 && rightHipAngle < 140);

    bool isSittingByKneeAngle =
        (leftKneeAngle > 50 && leftKneeAngle < 110) ||
        (rightKneeAngle > 50 && rightKneeAngle < 110);

    bool isSittingByVerticalAlignment =
        kneeY != null &&
        hipY != null &&
        (kneeY - hipY).abs() < 60 &&
        hipY > shoulderY + 40;

    // Enhanced pose classification

    // Sitting detection with more robust criteria
    if ((isSittingByHipAngle && isSittingByKneeAngle) ||
        (isSittingByHipAngle && isSittingByVerticalAlignment) ||
        (isSittingByVerticalAlignment && isSittingByKneeAngle)) {
      return "Sitting";
    }

    // T-Pose detection
    if (areHandsOut && shoulderAngle.abs() < 20 && shoulderY < hipY - 50) {
      return "T-Pose";
    }

    // Arms raised
    if (areHandsRaised) {
      if (leftElbowAngle > 150 && rightElbowAngle > 150) {
        return "Arms Raised";
      } else {
        return "Hands Up";
      }
    }

    // Squat detection - look at knee angles
    if (leftKneeAngle < 120 &&
        rightKneeAngle < 120 &&
        hipY > shoulderY + 50 &&
        shoulderY < hipY) {
      return "Squatting";
    }

    // Standing with straight back
    if (hipY > shoulderY + 80 && spineAngle.abs() < 15) {
      return "Standing";
    }

    // Walking detection - improved with multiple criteria
    if (leftKnee != null &&
        rightKnee != null &&
        ((leftKnee.y - rightKnee.y).abs() > 30 ||
            (leftAnkle != null &&
                rightAnkle != null &&
                (leftAnkle.y - rightAnkle.y).abs() > 40)) &&
        hipY > shoulderY + 60 &&
        spineAngle.abs() < 30) {
      return "Walking";
    }

    // Lying down detection - completely revised with priority
    // Calculate horizontal alignment and distances
    bool isHorizontalSpine =
        spineAngle.abs() > 45; // Lower threshold to catch more cases
    bool areShouldersAndHipsAligned =
        (shoulderY > hipY - 40 && shoulderY < hipY + 40);
    bool hasSignificantHorizontalDistance =
        ((leftShoulder.x - leftHip.x).abs() > 50 ||
            (rightShoulder.x - rightHip.x).abs() > 50);

    // Check for near-horizontal torso positioning
    bool isBodyMostlyHorizontal =
        isHorizontalSpine && hasSignificantHorizontalDistance;

    // Check for flat body (all parts at similar heights)
    bool isBodyFlat =
        ((leftShoulder.y - rightShoulder.y).abs() < 60 &&
            (leftHip.y - rightHip.y).abs() < 60 &&
            (leftKnee != null &&
                rightKnee != null &&
                (leftKnee.y - rightKnee.y).abs() < 60));

    // Print debugging info for lying down detection
    print(
      "Lying down checks: isHorizontalSpine=$isHorizontalSpine, aligned=${areShouldersAndHipsAligned}, " +
          "horizontal distance=${hasSignificantHorizontalDistance}, flat=${isBodyFlat}, " +
          "spineAngle=${spineAngle.toStringAsFixed(1)}",
    );

    // Comprehensive check with multiple conditions for lying down
    if ((isHorizontalSpine && areShouldersAndHipsAligned) ||
        (isBodyMostlyHorizontal && areShouldersAndHipsAligned) ||
        (hasSignificantHorizontalDistance && areShouldersAndHipsAligned) ||
        isBodyFlat ||
        (spineAngle.abs() > 60)) {
      // Very angled spine is likely lying down
      return "Lying Down";
    }

    // Replace bending detection with lying down
    // Any significant spine angle is now considered lying down instead of bending
    if (spineAngle > 30 || spineAngle < -30) {
      return "Lying Down"; // Previously "Bending"
    }

    // Fallback cases
    if (hipY > shoulderY + 50) {
      return "Upright";
    } else if (hipY < shoulderY) {
      return "Leaning Forward";
    }

    return "Other Pose";
  }

  // Helper method to calculate angle between three points using coordinates
  double _calculateAngleBetweenPoints(
    double x1,
    double y1, // first point
    double x2,
    double y2, // mid point
    double x3,
    double y3, // last point
  ) {
    final angle = math.atan2(y3 - y2, x3 - x2) - math.atan2(y1 - y2, x1 - x2);

    // Convert to degrees and ensure positive angle
    double degrees = angle * 180 / math.pi;
    if (degrees < 0) {
      degrees += 360;
    }

    return degrees;
  }

  // Helper method to calculate angle between three pose landmarks
  double _calculateAngle(
    PoseLandmark firstPoint,
    PoseLandmark midPoint,
    PoseLandmark lastPoint,
  ) {
    return _calculateAngleBetweenPoints(
      firstPoint.x,
      firstPoint.y,
      midPoint.x,
      midPoint.y,
      lastPoint.x,
      lastPoint.y,
    );
  }

  @override
  void dispose() {
    _frameProcessTimer?.cancel();
    _cameraController?.dispose();
    _poseDetector?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 20),
              Text("Initializing camera...", style: TextStyle(fontSize: 16)),
              if (_debugInfo.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Text(_debugInfo, style: TextStyle(color: Colors.red)),
                ),
            ],
          ),
        ),
      );
    }

    final screenSize = MediaQuery.of(context).size;

    return Scaffold(
      appBar: AppBar(
        title: Text('Real-time Pose Detection'),
        backgroundColor: Colors.blue.shade700,
      ),
      body: Stack(
        children: [
          // Camera Preview - simplified to avoid distortion
          Container(
            width: screenSize.width,
            height: screenSize.height,
            child: CameraPreview(_cameraController!),
          ),

          // Pose Overlay
          if (_poses != null && _imageSize != null)
            CustomPaint(
              size: screenSize,
              painter: PosePainter(
                poses: _poses!,
                imageSize: _imageSize!,
                screenSize: screenSize,
                cameraRotation: _cameraRotation,
              ),
            ),

          // Pose Category Display with better visibility
          Positioned(
            bottom: 30,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding: EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.white30, width: 1),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _poseCategory,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 26,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    if (_poses != null)
                      Text(
                        'Points detected: ${_poses![0].landmarks.length}/33',
                        style: TextStyle(color: Colors.white70, fontSize: 16),
                      ),
                  ],
                ),
              ),
            ),
          ),

          // Pause/Resume button
          Positioned(
            top: 20,
            right: 20,
            child: FloatingActionButton(
              mini: true,
              backgroundColor:
                  _processingEnabled
                      ? Colors.red.shade700
                      : Colors.green.shade700,
              foregroundColor: Colors.white,
              elevation: 8,
              child: Icon(
                _processingEnabled ? Icons.pause : Icons.play_arrow,
                size: 22,
              ),
              onPressed: () {
                setState(() {
                  _processingEnabled = !_processingEnabled;
                });
              },
            ),
          ),
        ],
      ),
    );
  }
}

class PosePainter extends CustomPainter {
  final List<Pose> poses;
  final Size imageSize;
  final Size screenSize;
  final int cameraRotation;

  PosePainter({
    required this.poses,
    required this.imageSize,
    required this.screenSize,
    required this.cameraRotation,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Different colors for different body parts
    final Paint jointPaint =
        Paint()
          ..color = Colors.red
          ..strokeWidth = 8.0;

    for (final pose in poses) {
      // Draw connections between landmarks with different colors first
      _drawBodyConnections(canvas, pose);

      // Draw landmarks with different sizes based on likelihood
      pose.landmarks.forEach((type, landmark) {
        // Increase point visibility
        double radius = landmark.likelihood > 0.5 ? 7.0 : 4.0;
        final scaledPoint = _scalePoint(landmark.x, landmark.y);

        // Draw joint with outline for better visibility
        canvas.drawCircle(
          scaledPoint,
          radius + 2.0,
          Paint()..color = Colors.black.withOpacity(0.5),
        );
        canvas.drawCircle(scaledPoint, radius, jointPaint);
      });
    }
  }

  void _drawBodyConnections(Canvas canvas, Pose pose) {
    // Upper body connections
    _drawConnection(
      canvas,
      pose,
      PoseLandmarkType.leftShoulder,
      PoseLandmarkType.rightShoulder,
      Colors.yellow,
    );
    _drawConnection(
      canvas,
      pose,
      PoseLandmarkType.leftShoulder,
      PoseLandmarkType.leftHip,
      Colors.yellow,
    );
    _drawConnection(
      canvas,
      pose,
      PoseLandmarkType.rightShoulder,
      PoseLandmarkType.rightHip,
      Colors.yellow,
    );
    _drawConnection(
      canvas,
      pose,
      PoseLandmarkType.leftHip,
      PoseLandmarkType.rightHip,
      Colors.yellow,
    );

    // Arm connections
    _drawConnection(
      canvas,
      pose,
      PoseLandmarkType.leftShoulder,
      PoseLandmarkType.leftElbow,
      Colors.green,
    );
    _drawConnection(
      canvas,
      pose,
      PoseLandmarkType.leftElbow,
      PoseLandmarkType.leftWrist,
      Colors.green,
    );
    _drawConnection(
      canvas,
      pose,
      PoseLandmarkType.rightShoulder,
      PoseLandmarkType.rightElbow,
      Colors.green,
    );
    _drawConnection(
      canvas,
      pose,
      PoseLandmarkType.rightElbow,
      PoseLandmarkType.rightWrist,
      Colors.green,
    );

    // Leg connections
    _drawConnection(
      canvas,
      pose,
      PoseLandmarkType.leftHip,
      PoseLandmarkType.leftKnee,
      Colors.blue,
    );
    _drawConnection(
      canvas,
      pose,
      PoseLandmarkType.leftKnee,
      PoseLandmarkType.leftAnkle,
      Colors.blue,
    );
    _drawConnection(
      canvas,
      pose,
      PoseLandmarkType.rightHip,
      PoseLandmarkType.rightKnee,
      Colors.blue,
    );
    _drawConnection(
      canvas,
      pose,
      PoseLandmarkType.rightKnee,
      PoseLandmarkType.rightAnkle,
      Colors.blue,
    );
  }

  void _drawConnection(
    Canvas canvas,
    Pose pose,
    PoseLandmarkType type1,
    PoseLandmarkType type2,
    Color color,
  ) {
    final landmark1 = pose.landmarks[type1];
    final landmark2 = pose.landmarks[type2];

    if (landmark1 != null && landmark2 != null) {
      final startPoint = _scalePoint(landmark1.x, landmark1.y);
      final endPoint = _scalePoint(landmark2.x, landmark2.y);

      // Make lines more visible with increased width and outline
      final Paint linePaint =
          Paint()
            ..color = color
            ..strokeWidth = 6.0
            ..strokeCap = StrokeCap.round;

      // Add outline to make lines more visible against any background
      final Paint outlinePaint =
          Paint()
            ..color = Colors.black.withOpacity(0.5)
            ..strokeWidth = 8.0
            ..strokeCap = StrokeCap.round
            ..style = PaintingStyle.stroke;

      // Draw outline first
      canvas.drawLine(startPoint, endPoint, outlinePaint);
      // Then draw the colored line
      canvas.drawLine(startPoint, endPoint, linePaint);
    }
  }

  Offset _scalePoint(double x, double y) {
    // Get the actual camera preview with correct aspect ratio
    final cameraAspectRatio = imageSize.width / imageSize.height;
    final screenAspectRatio = screenSize.width / screenSize.height;

    // Calculate area used by the preview on screen
    double previewWidth = screenSize.width;
    double previewHeight = screenSize.height;

    // Adjust for aspect ratio differences
    if (screenAspectRatio > cameraAspectRatio) {
      // Screen is wider than camera - width is constraining factor
      previewWidth = previewHeight * cameraAspectRatio;
    } else {
      // Screen is taller than camera - height is constraining factor
      previewHeight = previewWidth / cameraAspectRatio;
    }

    // Calculate offsets to center the preview
    final double offsetX = (screenSize.width - previewWidth) / 2;
    final double offsetY = (screenSize.height - previewHeight) / 2;

    double scaledX, scaledY;

    // Based on the screenshot, we need to make significant adjustments
    double alignmentCorrection = 1.0; // No distortion in scale
    double horizontalShift = 0.0 * previewWidth; // Centered horizontally
    double verticalShift = -0.08 * previewHeight; // Move slightly more up

    switch (cameraRotation) {
      case 90: // Most common Android orientation
        // For 90 degree rotation, we need to mirror and flip coordinates
        scaledX =
            (previewWidth * 0.5) +
            ((x / imageSize.width - 0.5) * previewWidth * alignmentCorrection) +
            offsetX +
            horizontalShift;

        scaledY =
            (previewHeight * 0.5) +
            ((y / imageSize.height - 0.5) *
                previewHeight *
                alignmentCorrection) +
            offsetY +
            verticalShift;
        break;

      case 270:
        scaledX =
            (previewWidth * 0.5) +
            ((x / imageSize.width - 0.5) * previewWidth * alignmentCorrection) +
            offsetX +
            horizontalShift;

        scaledY =
            (previewHeight * 0.5) +
            ((y / imageSize.height - 0.5) *
                previewHeight *
                alignmentCorrection) +
            offsetY +
            verticalShift;
        break;

      case 0:
        scaledX =
            (previewWidth * 0.5) +
            ((x / imageSize.width - 0.5) * previewWidth * alignmentCorrection) +
            offsetX +
            horizontalShift;

        scaledY =
            (previewHeight * 0.5) +
            ((y / imageSize.height - 0.5) *
                previewHeight *
                alignmentCorrection) +
            offsetY +
            verticalShift;
        break;

      case 180:
        scaledX =
            (previewWidth * 0.5) +
            ((x / imageSize.width - 0.5) * previewWidth * alignmentCorrection) +
            offsetX +
            horizontalShift;

        scaledY =
            (previewHeight * 0.5) +
            ((y / imageSize.height - 0.5) *
                previewHeight *
                alignmentCorrection) +
            offsetY +
            verticalShift;
        break;

      default:
        // Apply the same transformation for all cases since the specific orientation isn't crucial
        scaledX =
            (previewWidth * 0.5) +
            ((x / imageSize.width - 0.5) * previewWidth * alignmentCorrection) +
            offsetX +
            horizontalShift;

        scaledY =
            (previewHeight * 0.5) +
            ((y / imageSize.height - 0.5) *
                previewHeight *
                alignmentCorrection) +
            offsetY +
            verticalShift;
    }

    // Return final coordinates
    return Offset(scaledX, scaledY);
  }

  @override
  bool shouldRepaint(covariant PosePainter oldDelegate) => true;
}
