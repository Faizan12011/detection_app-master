import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:google_ml_kit/google_ml_kit.dart';
import 'package:google_mlkit_commons/google_mlkit_commons.dart';

import 'dart:io';
import 'dart:async';
import 'dart:typed_data';
import 'dart:math' as math;
import 'package:firebase_database/firebase_database.dart';

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
  List<Pose>? _previousPoses; // Store previous frame poses for interpolation
  double _interpolationFactor = 0.0;
  Timer? _animationTimer;
  int _frameSkipCounter = 0;
  List<Pose>? _predictedPoses; // For advanced motion prediction
  DateTime _lastFrameTime = DateTime.now();
  final List<double> _frameRates = []; // For tracking performance

  // Firebase fields
  DatabaseReference? _sessionRef;
  String? _sessionId;

  @override
  void initState() {
    super.initState();
    _initializeDetector();
    _initializeCamera();
    _initFirebaseSession();
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
        imageFormatGroup: ImageFormatGroup.yuv420, // More efficient format
      );

      await _cameraController!.initialize();
      if (!mounted) return;

      await _cameraController!.lockCaptureOrientation(
        DeviceOrientation.portraitUp,
      );

      // Use still-image capture every 33 ms (~30 fps) for compatibility
      _frameProcessTimer = Timer.periodic(const Duration(milliseconds: 33), (_) {
        if (_processingEnabled && !_isBusy && _isDetectorReady) {
          _captureAndProcessImage();
        }
      });

      // Separate animation timer running at 120fps for ultra-smooth transitions
      _animationTimer = Timer.periodic(Duration(milliseconds: 8), (_) {
        if (_previousPoses != null && _poses != null) {
          // Faster interpolation factor for more responsive animation
          _interpolationFactor += 0.2;
          if (_interpolationFactor > 1.0) _interpolationFactor = 1.0;

          // Only trigger rebuild if we're still interpolating
          if (_interpolationFactor < 1.0) {
            setState(() {});
          }
        }
      });

      setState(() {});
    } catch (e) {
      print("Camera initialization error: $e");
      _debugInfo = "Camera error: $e";
    }
  }

  // Initialize Firebase session for realtime streaming
  Future<void> _initFirebaseSession() async {
    _sessionId = 'live';
    _sessionRef = FirebaseDatabase.instance.ref('sessions/$_sessionId');
    await _sessionRef!.child('metadata').set({
      'fps': 30, // expected fps
      'status': 'live',
      'createdAt': ServerValue.timestamp,
    });
  }

  // Motion prediction method to anticipate pose movement
  List<Pose>? _predictNextPoses() {
    if (_poses == null || _previousPoses == null) return _poses;
    if (_poses!.isEmpty || _previousPoses!.isEmpty) return _poses;

    List<Pose> predictedPoses = [];

    try {
      // Calculate time since last frame to adjust prediction strength
      final now = DateTime.now();
      final millisSinceLastFrame =
          now.difference(_lastFrameTime).inMilliseconds;
      final predictionFactor =
          0.3; // How far ahead to predict (0.3 = 30% of the way to next position)

      for (int i = 0; i < _poses!.length; i++) {
        if (i >= _previousPoses!.length) continue;

        Pose currentPose = _poses![i];
        Pose previousPose = _previousPoses![i];

        // Create a new map of landmarks with predicted positions
        Map<PoseLandmarkType, PoseLandmark> predictedLandmarks = {};

        currentPose.landmarks.forEach((type, landmark) {
          if (previousPose.landmarks.containsKey(type)) {
            var prevLandmark = previousPose.landmarks[type]!;

            // Calculate velocity
            double vx = (landmark.x - prevLandmark.x);
            double vy = (landmark.y - prevLandmark.y);

            // Apply velocity to predict next position
            double predictedX = landmark.x + (vx * predictionFactor);
            double predictedY = landmark.y + (vy * predictionFactor);

            predictedLandmarks[type] = PoseLandmark(
              type: type,
              x: predictedX,
              y: predictedY,
              z: 0,
              likelihood: landmark.likelihood,
            );
          } else {
            predictedLandmarks[type] = landmark;
          }
        });

        // Create predicted pose
        predictedPoses.add(Pose(landmarks: predictedLandmarks));
      }

      return predictedPoses;
    } catch (e) {
      print("Prediction error: $e");
      return _poses; // Fallback to current poses
    }
  }

  // Add pose interpolation method with improved motion
  List<Pose>? _getInterpolatedPoses() {
    if (_poses == null || _previousPoses == null) return _poses;
    if (_interpolationFactor >= 1.0) {
      // Generate next predicted poses when we finish current interpolation
      if (_predictedPoses == null) {
        _predictedPoses = _predictNextPoses();
      }
      return _poses;
    }

    List<Pose> result = [];

    // Calculate eased interpolation factor (accelerate-decelerate)
    double easedFactor =
        _interpolationFactor < 0.5
            ? 2 * _interpolationFactor * _interpolationFactor
            : 1 - math.pow(-2 * _interpolationFactor + 2, 2) / 2;

    // Interpolate between previous poses and current poses
    for (int i = 0; i < _poses!.length; i++) {
      if (i >= _previousPoses!.length) continue;

      Pose currentPose = _poses![i];
      Pose previousPose = _previousPoses![i];

      // Create a new map of landmarks
      Map<PoseLandmarkType, PoseLandmark> interpolatedLandmarks = {};

      // Interpolate each landmark
      currentPose.landmarks.forEach((type, landmark) {
        if (previousPose.landmarks.containsKey(type)) {
          var prevLandmark = previousPose.landmarks[type]!;

          // Linear interpolation of x, y coordinates and likelihood
          double x =
              prevLandmark.x + (landmark.x - prevLandmark.x) * easedFactor;
          double y =
              prevLandmark.y + (landmark.y - prevLandmark.y) * easedFactor;
          double likelihood =
              prevLandmark.likelihood +
              (landmark.likelihood - prevLandmark.likelihood) * easedFactor;

          interpolatedLandmarks[type] = PoseLandmark(
            type: type,
            x: x,
            y: y,
            z: 0, // Z coordinate is often not used in 2D pose detection
            likelihood: likelihood,
          );
        } else {
          // If landmark doesn't exist in previous pose, use the current one
          interpolatedLandmarks[type] = landmark;
        }
      });

      // Create interpolated pose
      result.add(Pose(landmarks: interpolatedLandmarks));
    }

    return result;
  }

  // Process CameraImage from live stream
  void _onCameraImage(CameraImage image) async {
    if (_isBusy || !_isDetectorReady) return;
    _isBusy = true;
    final int startMs = DateTime.now().millisecondsSinceEpoch;

    try {
      // Ensure only YUV420 frames are processed; skip unsupported formats
      if (image.format.group != ImageFormatGroup.yuv420) {
        _isBusy = false;
        return;
      }
      // Convert YUV420 image to bytes for ML Kit
      final bytes = _concatenatePlanes(image.planes);
      final Size imageSize = Size(
        image.width.toDouble(),
        image.height.toDouble(),
      );
      final inputImage = InputImage.fromBytes(
        bytes: bytes,
        metadata: InputImageMetadata(
          size: imageSize,
          rotation: InputImageRotation.rotation0deg,
          format: InputImageFormat.yuv420,
          bytesPerRow: image.planes.first.bytesPerRow,
        ),
      );

      final poses = await _poseDetector!.processImage(inputImage);

      final int endMs = DateTime.now().millisecondsSinceEpoch;
      final processingTime = endMs - startMs;
      _frameRates.add(1000 / processingTime);
      if (_frameRates.length > 10) _frameRates.removeAt(0);
      final avgFps = _frameRates.reduce((a, b) => a + b) / _frameRates.length;

      if (poses.isNotEmpty && mounted) {
        setState(() {
          _previousPoses = _poses;
          _poses = poses;
          _imageSize = imageSize;
          _poseCategory = _classifyPose(poses);
          _debugInfo = "FPS: ${avgFps.toStringAsFixed(1)}";
        });
        _sendPosesToFirebase(poses);
      }
    } catch (e) {
      print('Stream frame error: $e');
    } finally {
      _isBusy = false;
    }
  }

  Uint8List _concatenatePlanes(List<Plane> planes) {
    final WriteBuffer allBytes = WriteBuffer();
    for (final Plane plane in planes) {
      allBytes.putUint8List(plane.bytes);
    }
    return allBytes.done().buffer.asUint8List();
  }

  // Old still-image path kept for fallback
  Future<void> _captureAndProcessImage() async {
    if (_isBusy ||
        !_isDetectorReady ||
        _cameraController == null ||
        !_cameraController!.value.isInitialized) {
      return;
    }

    _isBusy = true;
    DateTime processStart = DateTime.now();

    try {
      // Take a picture
      final xFile = await _cameraController!.takePicture();

      // Process the image file
      final inputImage = InputImage.fromFilePath(xFile.path);

      // Process with the detector
      final poses = await _poseDetector!.processImage(inputImage);

      // Calculate frame rate for monitoring
      final processEnd = DateTime.now();
      final processingTime = processEnd.difference(processStart).inMilliseconds;
      _frameRates.add(1000 / processingTime);
      if (_frameRates.length > 10) _frameRates.removeAt(0);
      double avgFrameRate =
          _frameRates.reduce((a, b) => a + b) / _frameRates.length;

      print(
        'Poses detected: ${poses.length}, processing time: ${processingTime}ms, avg rate: ${avgFrameRate.toStringAsFixed(1)} fps',
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
          // Store previous poses for interpolation
          _previousPoses = _poses;
          _poses = poses;
          _imageSize = imageSize;
          _poseCategory = poseCategory;
          _debugInfo =
              "Points: ${poses[0].landmarks.length}, FPS: ${avgFrameRate.toStringAsFixed(1)}";
          print(poses[0].landmarks.entries);

          // Reset interpolation factor to start smooth transition to new pose
          _interpolationFactor = 0.0;

          // Clear predictions since we have new data
          _predictedPoses = null;

          // Store timestamp for motion prediction
          _lastFrameTime = DateTime.now();
        });

        // Send to Firebase
        _sendPosesToFirebase(poses);
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

  // Convert current pose to flat array and push to Firebase
  void _sendPosesToFirebase(List<Pose> poses) {
    if (_sessionRef == null || poses.isEmpty) return;
    final pose = poses.first;

    // Convert pose to flat list in MediaPipe index order [x0,y0,z0, x1,y1,z1, ...]
    final orderedTypes = [
      PoseLandmarkType.nose, // 0
      PoseLandmarkType.leftEyeInner, // 1
      PoseLandmarkType.leftEye, // 2
      PoseLandmarkType.leftEyeOuter, // 3
      PoseLandmarkType.rightEyeInner, // 4
      PoseLandmarkType.rightEye, // 5
      PoseLandmarkType.rightEyeOuter, // 6
      PoseLandmarkType.leftEar, // 7
      PoseLandmarkType.rightEar, // 8
      PoseLandmarkType.leftMouth, // 9
      PoseLandmarkType.rightMouth, // 10
      PoseLandmarkType.leftShoulder, // 11
      PoseLandmarkType.rightShoulder, // 12
      PoseLandmarkType.leftElbow, // 13
      PoseLandmarkType.rightElbow, // 14
      PoseLandmarkType.leftWrist, // 15
      PoseLandmarkType.rightWrist, // 16
      PoseLandmarkType.leftPinky, // 17
      PoseLandmarkType.rightPinky, // 18
      PoseLandmarkType.leftIndex, // 19
      PoseLandmarkType.rightIndex, // 20
      PoseLandmarkType.leftThumb, // 21
      PoseLandmarkType.rightThumb, // 22
      PoseLandmarkType.leftHip, // 23
      PoseLandmarkType.rightHip, // 24
      PoseLandmarkType.leftKnee, // 25
      PoseLandmarkType.rightKnee, // 26
      PoseLandmarkType.leftAnkle, // 27
      PoseLandmarkType.rightAnkle, // 28
      PoseLandmarkType.leftHeel, // 29
      PoseLandmarkType.rightHeel, // 30
      PoseLandmarkType.leftFootIndex, // 31
      PoseLandmarkType.rightFootIndex, // 32
    ];

    final List<double> kp = [];
    final imgWidth = _imageSize?.width ?? 1.0;
    final imgHeight = _imageSize?.height ?? 1.0;
    for (final type in orderedTypes) {
      final lm = pose.landmarks[type];
      if (lm != null) {
        final xNorm = lm.x / imgWidth;
        final yNorm = lm.y / imgHeight;
        final zNorm = (lm.z ?? 0) / imgWidth;
        kp.addAll([xNorm, yNorm, zNorm]);
      } else {
        kp.addAll([0.0, 0.0, 0.0]);
      }
    }

    // Debug print the pose data being sent
    debugPrint('\n=== Sending Pose Data to Firebase ===');
    debugPrint('Total poses: ${poses.length}');
    debugPrint('Processing pose with ${pose.landmarks.length} landmarks');

    debugPrint('First 3 landmarks (x,y,z):');
    pose.landmarks.entries.take(3).forEach((entry) {
      final type = entry.key.toString().split('.').last;
      final landmark = entry.value;
      debugPrint(
        '  $type: ('
        '${landmark.x.toStringAsFixed(4)}, '
        '${landmark.y.toStringAsFixed(4)}, '
        '${(landmark.z ?? 0).toStringAsFixed(4)})',
      );
    });

    debugPrint('Total data points: ${kp.length}');
    debugPrint(
      'First 10 values: ${kp.take(10).map((v) => v.toStringAsFixed(4)).toList()}',
    );
    debugPrint('==============================\n');
    _sessionRef!
        .child('frames')
        .push()
        .set({'ts': ServerValue.timestamp, 'kp': kp})
        .then((_) async {
          // keep database small: remove frames older than 5 minutes (300 000 ms)
          final cutoff = DateTime.now().millisecondsSinceEpoch - 300000;
          final oldSnap =
              await _sessionRef!
                  .child('frames')
                  .orderByChild('ts')
                  .endAt(cutoff)
                  .get();
          if (oldSnap.exists) {
            for (final child in oldSnap.children) {
              await child.ref.remove();
            }
          }
        });
  }

  String _classifyPose(List<Pose> poses) {
    if (poses.isEmpty) return "No Pose";
    return "Pose"; // simplified classification since only streaming is needed
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
    _animationTimer?.cancel();
    _cameraController?.dispose();
    _poseDetector?.close();
    // mark session ended
    if (_sessionRef != null) {
      _sessionRef!.child('metadata/status').set('ended');
    }
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
          // Camera Preview - optimized setup
          SizedBox.expand(
            child: FittedBox(
              fit: BoxFit.cover,
              child: SizedBox(
                width: _cameraController!.value.previewSize!.height,
                height: _cameraController!.value.previewSize!.width,
                child: CameraPreview(_cameraController!),
              ),
            ),
          ),

          // Pose Overlay - use interpolated poses for smoother animations
          if (_previousPoses != null && _poses != null && _imageSize != null)
            RepaintBoundary(
              child: CustomPaint(
                size: screenSize,
                painter: PosePainter(
                  poses: _getInterpolatedPoses() ?? _poses!,
                  imageSize: _imageSize!,
                  screenSize: screenSize,
                  cameraRotation: _cameraRotation,
                ),
                isComplex: false, // Hint to Flutter that painting is simple
                willChange: true, // Hint that we will repaint frequently
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
            (previewHeight * 0.2) +
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
