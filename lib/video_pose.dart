import 'package:flutter/material.dart';
import 'package:google_ml_kit/google_ml_kit.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import 'dart:math' as math;
import 'dart:async';
import 'dart:ui' as ui;
import 'dart:typed_data';
import 'package:video_player/video_player.dart';
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';
import 'package:image/image.dart' as img;
import 'dart:convert';
import 'package:path/path.dart' as path;
import 'package:share_plus/share_plus.dart';

class VideoPose extends StatefulWidget {
  @override
  _VideoPoseState createState() => _VideoPoseState();
}

class _VideoPoseState extends State<VideoPose> with TickerProviderStateMixin {
  XFile? _videoFile;
  PoseDetector? _poseDetector;
  bool _isProcessing = false;
  bool _processingComplete = false;
  double _processingProgress = 0.0;
  String _debugInfo = "";
  List<Pose>? _currentPoses;
  VideoPlayerController? _videoController;
  String _poseCategory = "Unknown";
  bool _isDetectorReady = false;
  Timer? _positionUpdateTimer;
  int _frameCount = 0;
  Stopwatch _fpsStopwatch = Stopwatch();
  int _lastFpsUpdate = 0;
  String _fpsInfo = "";

  // New: Map to store pre-processed poses at each video position (in milliseconds)
  final Map<int, List<Pose>> _processedPoses = {};
  final Map<int, String> _processedCategories = {};
  int _totalFrames = 0;
  int _processedFrames = 0;

  // We don't need simulation mode anymore since we pre-process
  // bool _useSimulationMode = false;
  bool _extractingFrames = false;
  bool _startUI = true;

  // Add variables for recording and exporting
  bool _isRecordingPoses = false;
  List<Map<String, dynamic>> _recordedPoseFrames = [];
  String _exportStatus = "";
  int _recordedFrameCount = 0;
  bool _showExportButton = false;

  @override
  void initState() {
    super.initState();
    _initializePoseDetector();
    // Initialize the key for video player screenshots
    _videoPlayerKey = GlobalKey();

    // Update poses more frequently with a timer for smoother animation
    _positionUpdateTimer = Timer.periodic(Duration(milliseconds: 16), (_) {
      if (_videoController?.value.isPlaying ?? false) {
        _onVideoPositionChanged();
      }
    });
  }

  Future<void> _initializePoseDetector() async {
    try {
      // Initialize with base options using a more accurate model
      final options = PoseDetectorOptions(
        mode: PoseDetectionMode.single,
        model: PoseDetectionModel.accurate,
      );
      _poseDetector = PoseDetector(options: options);
      _isDetectorReady = true;
      print("Pose detector initialized successfully");
    } catch (e) {
      print("Error initializing pose detector: $e");
      _debugInfo = "Detector error: $e";
    }
  }

  Future<void> _pickVideo() async {
    final imagePicker = ImagePicker();

    setState(() {
      _isProcessing = true;
      _processingComplete = false;
      _debugInfo = "Opening gallery...";
      _currentPoses = null;
      _videoController?.dispose();
      _videoController = null;
      _poseCategory = "Unknown";
      _processingProgress = 0.0;

      // Clear any previous processed poses
      _processedPoses.clear();
      _processedCategories.clear();
      _totalFrames = 0;
      _processedFrames = 0;
    });

    try {
      final pickedVideo = await imagePicker.pickVideo(
        source: ImageSource.gallery,
        maxDuration: Duration(minutes: 5),
      );

      if (pickedVideo != null) {
        _videoFile = pickedVideo;
        print("Video selected: ${pickedVideo.path}");

        // Initialize video player and process frames
        await _initializeVideoPlayer();
      } else {
        setState(() {
          _isProcessing = false;
          _debugInfo = "No video selected";
        });
      }
    } catch (e) {
      print("Error picking video: $e");
      setState(() {
        _isProcessing = false;
        _debugInfo = "Error selecting video: $e";
      });
    }
  }

  Future<void> _initializeVideoPlayer() async {
    setState(() {
      _isProcessing = true;
      _debugInfo = "Initializing video player...";
    });

    try {
      _videoController = VideoPlayerController.file(File(_videoFile!.path));
      await _videoController!.initialize();
      _videoController!.addListener(_onVideoPositionChanged);

      setState(() {
        _isProcessing = true;
        _debugInfo = "Video initialized. Processing frames...";
        _startUI = false;
      });

      // Process video frames to extract poses
      await _processVideoFrames();

      // Force set processing complete flag
      if (_videoController != null && _videoController!.value.isInitialized) {
        setState(() {
          _processingComplete = true;
          print(
            "Force set _processingComplete = true after video player initialization",
          );
        });
      }
    } catch (e) {
      setState(() {
        _isProcessing = false;
        _debugInfo = "Error initializing video: $e";
      });
    }
  }

  Future<void> _processVideoFrames() async {
    if (_videoController == null || !_videoController!.value.isInitialized) {
      setState(() {
        _debugInfo = "Video not initialized";
        _isProcessing = false;
      });
      return;
    }

    setState(() {
      _isProcessing = true;
      _extractingFrames = true;
      _processingProgress = 0.0;
      _debugInfo = "Starting video processing";
      _processedPoses.clear();
      _processedCategories.clear();
    });

    try {
      final Duration videoDuration = _videoController!.value.duration;
      // Process frames more frequently (reduced from 200ms to 100ms for smoother animation)
      final int intervalMs = 100;
      final int totalTimeMs = videoDuration.inMilliseconds;
      final int totalFramesToProcess = (totalTimeMs / intervalMs).ceil();

      _totalFrames = totalFramesToProcess;
      _processedFrames = 0;

      for (int i = 0; i < totalFramesToProcess; i++) {
        if (!_isProcessing) break; // Allow cancellation

        final int timeMs = i * intervalMs;
        if (timeMs >= totalTimeMs) break;

        // Seek to the position
        await _videoController!.seekTo(Duration(milliseconds: timeMs));
        // Give time for the frame to render (reduced for faster processing)
        await Future.delayed(Duration(milliseconds: 20));

        // Capture and process the frame
        final image = await _captureVideoFrame();
        if (image == null) {
          setState(() {
            _debugInfo = "Failed to capture frame at ${timeMs}ms";
          });
          continue;
        }

        // Process the captured image
        final inputImage = InputImage.fromFile(image);
        final List<Pose> poses = await _poseDetector!.processImage(inputImage);

        if (poses.isNotEmpty) {
          _processedPoses[timeMs] = poses;
          _processedCategories[timeMs] = _classifyPose(poses.first);
        }

        // Update progress
        _processedFrames++;
        setState(() {
          _processingProgress = _processedFrames / _totalFrames;
          _debugInfo = "Processed $_processedFrames/$_totalFrames frames";
        });

        await Future.delayed(
          Duration(milliseconds: 2),
        ); // Reduced delay to prevent UI freeze
      }

      setState(() {
        _isProcessing = false;
        _extractingFrames = false;
        _processingComplete = true;
        _startUI = false;
        _debugInfo =
            "Processing complete. Generated poses for ${_processedPoses.length} frames.";
      });

      // Reset to beginning and pause
      await _videoController!.seekTo(Duration.zero);
      _videoController!.pause();

      // Set initial pose if available
      if (_processedPoses.isNotEmpty) {
        final firstKey = _processedPoses.keys.first;
        setState(() {
          _currentPoses = _processedPoses[firstKey];
          _poseCategory = _processedCategories[firstKey] ?? "Unknown";
        });
      }
    } catch (e) {
      setState(() {
        _isProcessing = false;
        _extractingFrames = false;
        _debugInfo = "Error processing video: $e";
      });
    }
  }

  Future<File?> _captureVideoFrame() async {
    try {
      // Get the render object from the key
      final RenderRepaintBoundary boundary =
          _videoPlayerKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;

      // Capture the image with a higher pixel ratio for better quality
      final ui.Image image = await boundary.toImage(pixelRatio: 2.0);
      final ByteData? byteData = await image.toByteData(
        format: ui.ImageByteFormat.png,
      );

      if (byteData == null) {
        setState(() {
          _debugInfo = "Failed to get image data";
        });
        return null;
      }

      // Create a temporary file
      final tempDir = await getTemporaryDirectory();
      final tempFile = File(
        '${tempDir.path}/frame_${DateTime.now().millisecondsSinceEpoch}.png',
      );

      // Write the image to the file
      await tempFile.writeAsBytes(byteData.buffer.asUint8List());

      return tempFile;
    } catch (e) {
      setState(() {
        _debugInfo = "Error capturing frame: $e";
      });
      return null;
    }
  }

  void _onVideoPositionChanged() {
    if (_videoController == null || !_processingComplete) return;
    if (_processedPoses.isEmpty) return;

    // Find the closest timestamp
    final currentTimeMs = _videoController!.value.position.inMilliseconds;
    int? closestTimestamp;
    int smallestDifference = 1000000; // Large initial value

    for (final timestamp in _processedPoses.keys) {
      final difference = (timestamp - currentTimeMs).abs();
      if (difference < smallestDifference) {
        smallestDifference = difference;
        closestTimestamp = timestamp;
      }
    }

    if (closestTimestamp != null) {
      // Record pose if we're in recording mode
      if (_isRecordingPoses && _videoController!.value.isPlaying) {
        final poses = _processedPoses[closestTimestamp]!;
        if (poses.isNotEmpty) {
          // Only record every 3rd frame to avoid too much data
          if (_recordedFrameCount % 3 == 0) {
            _recordedPoseFrames.add(
              _convertPoseToUnityFormat(poses.first, currentTimeMs),
            );
          }
          _recordedFrameCount++;

          // Update status periodically
          if (_recordedFrameCount % 30 == 0) {
            setState(() {
              _exportStatus = "Recording: ${_recordedPoseFrames.length} frames";
            });
          }
        }
      }

      // Always update to keep animation smooth (removed the equality check)
      setState(() {
        _currentPoses = _processedPoses[closestTimestamp!];
        _poseCategory = _processedCategories[closestTimestamp] ?? "Unknown";
      });
    }
  }

  // New method for pose interpolation
  List<Pose>? _interpolatePoses(
    List<Pose> startPoses,
    List<Pose> endPoses,
    double factor,
  ) {
    if (startPoses.isEmpty || endPoses.isEmpty) return null;
    if (startPoses.length != endPoses.length) return null;

    List<Pose> interpolatedPoses = [];

    for (int i = 0; i < startPoses.length; i++) {
      Pose startPose = startPoses[i];
      Pose endPose = endPoses[i];

      // Create a new map of landmarks
      Map<PoseLandmarkType, PoseLandmark> interpolatedLandmarks = {};

      // Interpolate each landmark
      startPose.landmarks.forEach((type, startLandmark) {
        if (endPose.landmarks.containsKey(type)) {
          var endLandmark = endPose.landmarks[type]!;

          // Linear interpolation of x, y coordinates and likelihood
          double x =
              startLandmark.x + (endLandmark.x - startLandmark.x) * factor;
          double y =
              startLandmark.y + (endLandmark.y - startLandmark.y) * factor;
          double likelihood =
              startLandmark.likelihood +
              (endLandmark.likelihood - startLandmark.likelihood) * factor;

          interpolatedLandmarks[type] = PoseLandmark(
            type: type,
            x: x,
            y: y,
            z: 0, // Z coordinate is often not used in 2D pose detection
            likelihood: likelihood,
          );
        } else {
          // If landmark doesn't exist in end pose, use the start one
          interpolatedLandmarks[type] = startLandmark;
        }
      });

      // Create interpolated pose
      interpolatedPoses.add(Pose(landmarks: interpolatedLandmarks));
    }

    return interpolatedPoses;
  }

  Uint8List _convertImageToNV21(img.Image image) {
    final int width = image.width;
    final int height = image.height;

    // NV21 format size: Y + UV where Y is width*height and UV is width*height/2
    final int ySize = width * height;
    final int uvSize = width * height ~/ 2;
    final Uint8List nv21 = Uint8List(ySize + uvSize);

    // Fill Y channel (luminance)
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        // Get color values
        final pixel = image.getPixelSafe(x, y);
        final r = pixel.r.toInt();
        final g = pixel.g.toInt();
        final b = pixel.b.toInt();

        // Calculate Y (luminance)
        final int yValue = ((0.299 * r) + (0.587 * g) + (0.114 * b)).round();
        nv21[y * width + x] = yValue;
      }
    }

    // Fill VU (chroma) interleaved
    int uvIndex = ySize;
    for (int y = 0; y < height; y += 2) {
      for (int x = 0; x < width; x += 2) {
        // Sample 2x2 block and average the colors
        int totalR = 0, totalG = 0, totalB = 0;
        int count = 0;

        for (int yy = y; yy < y + 2 && yy < height; yy++) {
          for (int xx = x; xx < x + 2 && xx < width; xx++) {
            final pixel = image.getPixelSafe(xx, yy);
            totalR += pixel.r.toInt();
            totalG += pixel.g.toInt();
            totalB += pixel.b.toInt();
            count++;
          }
        }

        final int avgR = totalR ~/ count;
        final int avgG = totalG ~/ count;
        final int avgB = totalB ~/ count;

        // Calculate V and U values
        final int vValue = ((0.713 * (avgR - (avgG / 0.587))) + 128)
            .round()
            .clamp(0, 255);
        final int uValue = ((0.564 * (avgB - (avgG / 0.587))) + 128)
            .round()
            .clamp(0, 255);

        // Store V then U (NV21 format)
        nv21[uvIndex++] = vValue;
        nv21[uvIndex++] = uValue;
      }
    }

    return nv21;
  }

  void _playVideo() {
    if (_videoController == null || !_processingComplete) return;

    _videoController!.play();
    setState(() {});
  }

  void _pauseVideo() {
    if (_videoController == null) return;

    _videoController!.pause();
    setState(() {});
  }

  void _resetVideo() {
    if (_videoController == null) return;

    _videoController!.seekTo(Duration.zero);
    setState(() {});
  }

  @override
  void dispose() {
    _positionUpdateTimer?.cancel();
    _videoController?.removeListener(_onVideoPositionChanged);
    _videoController?.dispose();
    _poseDetector?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Video Pose Detection'),
        actions: [
          if (_videoController != null && _videoController!.value.isInitialized)
            IconButton(
              icon: Icon(
                _videoController!.value.isPlaying
                    ? Icons.pause
                    : Icons.play_arrow,
              ),
              onPressed: () {
                _videoController!.value.isPlaying
                    ? _pauseVideo()
                    : _playVideo();
              },
            ),
          IconButton(icon: Icon(Icons.refresh), onPressed: _resetVideo),

          // Add recording button when processing is complete
          if (_processingComplete)
            IconButton(
              icon: Icon(
                _isRecordingPoses ? Icons.stop : Icons.fiber_manual_record,
              ),
              color: _isRecordingPoses ? Colors.red : Colors.white,
              onPressed: _toggleRecording,
              tooltip: _isRecordingPoses ? 'Stop Recording' : 'Record Poses',
            ),

          // Add direct export button in app bar as well
          if (_recordedPoseFrames.isNotEmpty && !_isRecordingPoses)
            IconButton(
              icon: Icon(Icons.upload_file),
              onPressed: _exportRecordedPoses,
              tooltip: 'Export Recorded Poses',
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Container(
              color: Colors.black,
              child:
                  _startUI
                      ? _buildStartUI()
                      : Stack(
                        fit: StackFit.expand,
                        children: [
                          // Video Player with RepaintBoundary for capturing frames
                          RepaintBoundary(
                            key: _videoPlayerKey,
                            child: AspectRatio(
                              aspectRatio: _videoController!.value.aspectRatio,
                              child: VideoPlayer(_videoController!),
                            ),
                          ),
                          // Processing overlay
                          if (_isProcessing)
                            Container(
                              color: Colors.black54,
                              child: Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    CircularProgressIndicator(
                                      value:
                                          _extractingFrames
                                              ? _processingProgress
                                              : null,
                                    ),
                                    SizedBox(height: 16),
                                    Text(
                                      _extractingFrames
                                          ? 'Processing Video: ${(_processingProgress * 100).toStringAsFixed(1)}%'
                                          : 'Initializing...',
                                      style: TextStyle(color: Colors.white),
                                    ),
                                    SizedBox(height: 8),
                                    Text(
                                      _debugInfo ?? '',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 12,
                                      ),
                                    ),
                                    SizedBox(height: 16),
                                    ElevatedButton(
                                      onPressed: () {
                                        setState(() {
                                          _isProcessing = false;
                                        });
                                      },
                                      child: Text('Cancel'),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          // Pose overlay
                          if (_currentPoses != null &&
                              _currentPoses!.isNotEmpty)
                            CustomPaint(
                              painter: VideoPosePainter(
                                poses: _currentPoses!,
                                absoluteImageSize: Size(
                                  _videoController!.value.size.width,
                                  _videoController!.value.size.height,
                                ),
                                rotation: InputImageRotation.rotation0deg,
                              ),
                            ),
                          // Detected pose category
                          Positioned(
                            top: 16,
                            left: 16,
                            child: Container(
                              padding: EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: Colors.black54,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                'Pose: ${_poseCategory ?? "Unknown"}',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),

                          // Recording status indicator
                          if (_isRecordingPoses)
                            Positioned(
                              top: 16,
                              right: 16,
                              child: Container(
                                padding: EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: Colors.red.withOpacity(0.7),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.circle,
                                      color: Colors.red,
                                      size: 12,
                                    ),
                                    SizedBox(width: 4),
                                    Text(
                                      'REC',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
            ),
          ),
          // Video controls
          if (!_startUI &&
              _videoController != null &&
              _videoController!.value.isInitialized)
            Container(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: Colors.black,
              child: Row(
                children: [
                  Text(
                    _formatDuration(_videoController!.value.position),
                    style: TextStyle(color: Colors.white),
                  ),
                  Expanded(
                    child: Slider(
                      value:
                          _videoController!.value.position.inMilliseconds
                              .toDouble(),
                      min: 0,
                      max:
                          _videoController!.value.duration.inMilliseconds
                              .toDouble(),
                      onChanged: (value) {
                        _videoController!.seekTo(
                          Duration(milliseconds: value.toInt()),
                        );
                      },
                    ),
                  ),
                  Text(
                    _formatDuration(_videoController!.value.duration),
                    style: TextStyle(color: Colors.white),
                  ),
                ],
              ),
            ),

          // Export controls and status
          if (_processingComplete)
            Container(
              color: Colors.black,
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Export status
                  Text(
                    _exportStatus,
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight:
                          _recordedPoseFrames.isNotEmpty
                              ? FontWeight.bold
                              : FontWeight.normal,
                    ),
                  ),

                  // Export button when we have frames to export
                  if (_recordedPoseFrames.isNotEmpty && !_isRecordingPoses)
                    Padding(
                      padding: const EdgeInsets.only(top: 8.0),
                      child: ElevatedButton.icon(
                        icon: Icon(Icons.upload_file),
                        label: Text('Export for Unity'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blue.shade700,
                          foregroundColor: Colors.white,
                        ),
                        onPressed: _exportRecordedPoses,
                      ),
                    ),
                ],
              ),
            ),

          // Alternative recording controls - always visible when video is ready
          if (_videoController != null &&
              !_startUI &&
              !_isProcessing &&
              _videoController!.value.isInitialized)
            Container(
              color: Colors.black,
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  // Recording button
                  ElevatedButton.icon(
                    icon: Icon(
                      _isRecordingPoses
                          ? Icons.stop
                          : Icons.fiber_manual_record,
                      color: _isRecordingPoses ? Colors.white : Colors.red,
                    ),
                    label: Text(
                      _isRecordingPoses ? 'Stop Recording' : 'Record Poses',
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor:
                          _isRecordingPoses ? Colors.red : Colors.grey.shade800,
                      foregroundColor: Colors.white,
                      padding: EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                    ),
                    onPressed: () {
                      print(
                        "Recording button pressed. Current state: $_isRecordingPoses",
                      );
                      _toggleRecording();
                    },
                  ),

                  // Export button
                  if (_recordedPoseFrames.isNotEmpty && !_isRecordingPoses)
                    ElevatedButton.icon(
                      icon: Icon(Icons.upload_file),
                      label: Text(
                        'Export (${_recordedPoseFrames.length} frames)',
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue.shade700,
                        foregroundColor: Colors.white,
                        padding: EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                      ),
                      onPressed: _exportRecordedPoses,
                    ),

                  // Status text when recording
                  if (_isRecordingPoses)
                    Text(
                      "${_recordedPoseFrames.length} frames",
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                ],
              ),
            ),

          // Debug info
          if (_debugInfo != null)
            Container(
              padding: EdgeInsets.all(8),
              width: double.infinity,
              color: Colors.black87,
              child: Text(
                _debugInfo!,
                style: TextStyle(color: Colors.white, fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }

  String _formatDuration(Duration duration) {
    return '${duration.inMinutes}:${(duration.inSeconds % 60).toString().padLeft(2, '0')}';
  }

  Widget _buildStartUI() {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.blue.shade800, Colors.blue.shade500],
        ),
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              'Video Pose Detection',
              style: TextStyle(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(height: 30),
            _isProcessing
                ? CircularProgressIndicator(color: Colors.white)
                : ElevatedButton.icon(
                  icon: Icon(Icons.video_library),
                  label: Text('Select Video'),
                  style: ElevatedButton.styleFrom(
                    padding: EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                    textStyle: TextStyle(fontSize: 18),
                  ),
                  onPressed: _pickVideo,
                ),
          ],
        ),
      ),
    );
  }

  String _classifyPose(Pose pose) {
    if (pose.landmarks.length < 11) {
      return "Insufficient Points";
    }

    // Get key landmarks
    final leftShoulder = pose.landmarks[PoseLandmarkType.leftShoulder];
    final rightShoulder = pose.landmarks[PoseLandmarkType.rightShoulder];
    final leftHip = pose.landmarks[PoseLandmarkType.leftHip];
    final rightHip = pose.landmarks[PoseLandmarkType.rightHip];
    final leftKnee = pose.landmarks[PoseLandmarkType.leftKnee];
    final rightKnee = pose.landmarks[PoseLandmarkType.rightKnee];
    final leftWrist = pose.landmarks[PoseLandmarkType.leftWrist];
    final rightWrist = pose.landmarks[PoseLandmarkType.rightWrist];
    final leftElbow = pose.landmarks[PoseLandmarkType.leftElbow];
    final rightElbow = pose.landmarks[PoseLandmarkType.rightElbow];
    final leftAnkle = pose.landmarks[PoseLandmarkType.leftAnkle];
    final rightAnkle = pose.landmarks[PoseLandmarkType.rightAnkle];
    final nose = pose.landmarks[PoseLandmarkType.nose];

    // Calculate confidence - we need core landmarks
    if (leftShoulder == null ||
        rightShoulder == null ||
        leftHip == null ||
        rightHip == null) {
      return "Missing Core Points";
    }

    // Calculate joint angles for better detection
    double leftElbowAngle = 0;
    double rightElbowAngle = 0;
    double leftKneeAngle = 0;
    double rightKneeAngle = 0;
    double leftHipAngle = 0;
    double rightHipAngle = 0;

    // Calculate elbow angles
    if (leftShoulder != null && leftElbow != null && leftWrist != null) {
      leftElbowAngle = _calculateAngle(
        leftShoulder.x,
        leftShoulder.y,
        leftElbow.x,
        leftElbow.y,
        leftWrist.x,
        leftWrist.y,
      );
    }

    if (rightShoulder != null && rightElbow != null && rightWrist != null) {
      rightElbowAngle = _calculateAngle(
        rightShoulder.x,
        rightShoulder.y,
        rightElbow.x,
        rightElbow.y,
        rightWrist.x,
        rightWrist.y,
      );
    }

    // Check T-Pose: arms stretched out horizontally
    if (leftElbow != null &&
        rightElbow != null &&
        leftWrist != null &&
        rightWrist != null) {
      double leftArmHorizontal = (leftElbow.y - leftShoulder.y).abs();
      double rightArmHorizontal = (rightElbow.y - rightShoulder.y).abs();
      double leftForearmHorizontal = (leftWrist.y - leftElbow.y).abs();
      double rightForearmHorizontal = (rightWrist.y - rightElbow.y).abs();

      bool armsOut =
          (leftElbow.x < leftShoulder.x) && (rightElbow.x > rightShoulder.x);
      bool armsHorizontal =
          leftArmHorizontal < 30 &&
          rightArmHorizontal < 30 &&
          leftForearmHorizontal < 30 &&
          rightForearmHorizontal < 30;

      if (armsOut && armsHorizontal) {
        return "T-Pose";
      }
    }

    // Check arms raised: wrists above shoulders
    if (leftWrist != null && rightWrist != null) {
      bool armsRaised =
          leftWrist.y < leftShoulder.y - 50 &&
          rightWrist.y < rightShoulder.y - 50;
      if (armsRaised) {
        return "Arms Raised";
      }
    }

    // Check sitting: calculate knee angles and hip position
    if (leftHip != null &&
        rightHip != null &&
        leftKnee != null &&
        rightKnee != null &&
        leftAnkle != null &&
        rightAnkle != null) {
      leftKneeAngle = _calculateAngle(
        leftHip.x,
        leftHip.y,
        leftKnee.x,
        leftKnee.y,
        leftAnkle.x,
        leftAnkle.y,
      );

      rightKneeAngle = _calculateAngle(
        rightHip.x,
        rightHip.y,
        rightKnee.x,
        rightKnee.y,
        rightAnkle.x,
        rightAnkle.y,
      );

      // Calculate the vertical distance between shoulders and hips
      double torsoLength =
          ((leftShoulder.y + rightShoulder.y) / 2) -
          ((leftHip.y + rightHip.y) / 2);
      // Calculate the vertical distance between hips and knees
      double upperLegLength =
          ((leftHip.y + rightHip.y) / 2) - ((leftKnee.y + rightKnee.y) / 2);

      // If knees are bent significantly and the torso to upper leg ratio is higher than standing
      bool kneesBent = (leftKneeAngle < 140 || rightKneeAngle < 140);
      bool sittingPosture = torsoLength < upperLegLength * 1.5;

      if (kneesBent && sittingPosture) {
        return "Sitting";
      }
    }

    // Check walking by looking at leg positions and asymmetry
    if (leftKnee != null &&
        rightKnee != null &&
        leftAnkle != null &&
        rightAnkle != null) {
      double legAsymmetry = (leftKnee.y - rightKnee.y).abs();
      double ankleAsymmetry = (leftAnkle.y - rightAnkle.y).abs();

      bool legsOffset = legAsymmetry > 20 || ankleAsymmetry > 20;
      bool upright =
          leftShoulder != null &&
          rightShoulder != null &&
          leftHip != null &&
          rightHip != null &&
          (leftShoulder.y < leftHip.y) &&
          (rightShoulder.y < rightHip.y);

      if (legsOffset && upright) {
        return "Walking";
      }
    }

    // Default case: standing
    return "Standing";
  }

  double _calculateAngle(
    double x1,
    double y1,
    double x2,
    double y2,
    double x3,
    double y3,
  ) {
    double radians =
        math.atan2(y3 - y2, x3 - x2) - math.atan2(y1 - y2, x1 - x2);
    double angle = radians * 180 / math.pi; // Convert to degrees

    angle = angle.abs(); // Get the absolute value of the angle
    if (angle > 180) angle = 360 - angle; // Always get the smaller angle

    return angle;
  }

  // Create a key for video player screenshots
  GlobalKey _videoPlayerKey = GlobalKey();

  // Add method to convert pose data to Unity-compatible format
  Map<String, dynamic> _convertPoseToUnityFormat(Pose pose, int timestamp) {
    Map<String, dynamic> unityPose = {"timestamp": timestamp, "joints": {}};

    // Define mapping from ML Kit landmarks to common joint names used in Unity
    final Map<PoseLandmarkType, String> landmarkToUnityJoint = {
      PoseLandmarkType.nose: "Head",
      PoseLandmarkType.leftEye: "LeftEye",
      PoseLandmarkType.rightEye: "RightEye",
      PoseLandmarkType.leftEar: "LeftEar",
      PoseLandmarkType.rightEar: "RightEar",
      PoseLandmarkType.leftShoulder: "LeftShoulder",
      PoseLandmarkType.rightShoulder: "RightShoulder",
      PoseLandmarkType.leftElbow: "LeftElbow",
      PoseLandmarkType.rightElbow: "RightElbow",
      PoseLandmarkType.leftWrist: "LeftWrist",
      PoseLandmarkType.rightWrist: "RightWrist",
      PoseLandmarkType.leftHip: "LeftHip",
      PoseLandmarkType.rightHip: "RightHip",
      PoseLandmarkType.leftKnee: "LeftKnee",
      PoseLandmarkType.rightKnee: "RightKnee",
      PoseLandmarkType.leftAnkle: "LeftAnkle",
      PoseLandmarkType.rightAnkle: "RightAnkle",
      PoseLandmarkType.leftPinky: "LeftPinky",
      PoseLandmarkType.rightPinky: "RightPinky",
      PoseLandmarkType.leftIndex: "LeftIndex",
      PoseLandmarkType.rightIndex: "RightIndex",
      PoseLandmarkType.leftThumb: "LeftThumb",
      PoseLandmarkType.rightThumb: "RightThumb",
      PoseLandmarkType.leftHeel: "LeftHeel",
      PoseLandmarkType.rightHeel: "RightHeel",
      PoseLandmarkType.leftFootIndex: "LeftToe",
      PoseLandmarkType.rightFootIndex: "RightToe",
    };

    // Add each landmark as a joint with position data
    pose.landmarks.forEach((type, landmark) {
      if (landmarkToUnityJoint.containsKey(type)) {
        final jointName = landmarkToUnityJoint[type]!;

        // Normalize coordinates to 0.0-1.0 range for easier unity import
        // Note: In Unity you'll multiply these by your character scale
        final normalizedX = landmark.x / _videoController!.value.size.width;
        final normalizedY = landmark.y / _videoController!.value.size.height;

        unityPose["joints"][jointName] = {
          "position": {
            "x": normalizedX,
            "y": normalizedY,
            "z": 0.0, // Z is not available in 2D pose estimation
          },
          "confidence": landmark.likelihood,
        };
      }
    });

    return unityPose;
  }

  // Method to export recorded poses as JSON file
  Future<void> _exportRecordedPoses() async {
    try {
      setState(() {
        _exportStatus = "Preparing export...";
      });

      if (_recordedPoseFrames.isEmpty) {
        setState(() {
          _exportStatus = "No poses to export";
        });
        return;
      }

      // Create export directory
      final directory =
          await getExternalStorageDirectory() ??
          await getApplicationDocumentsDirectory();
      final exportDir = Directory('${directory.path}/pose_exports');
      if (!await exportDir.exists()) {
        await exportDir.create(recursive: true);
      }

      // Create animation data with metadata
      final animationData = {
        "metadata": {
          "frameCount": _recordedPoseFrames.length,
          "videoWidth": _videoController!.value.size.width,
          "videoHeight": _videoController!.value.size.height,
          "exportDate": DateTime.now().toIso8601String(),
          "version": "1.0",
        },
        "frames": _recordedPoseFrames,
      };

      // Save to file
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final filePath = '${exportDir.path}/pose_animation_$timestamp.json';
      final file = File(filePath);
      await file.writeAsString(jsonEncode(animationData));

      setState(() {
        _exportStatus = "Export successful!";
      });

      // Share the file
      await Share.shareXFiles(
        [XFile(filePath)],
        text: 'Pose animation data for Unity',
        subject: 'Unity Animation Data',
      );

      print("Exported animation data to: $filePath");
    } catch (e) {
      setState(() {
        _exportStatus = "Export failed: $e";
      });
      print("Error exporting poses: $e");
    }
  }

  // Add toggle recording method
  void _toggleRecording() {
    if (_isRecordingPoses) {
      // Stopping the recording
      setState(() {
        _isRecordingPoses = false;
        _exportStatus = "Recorded ${_recordedPoseFrames.length} frames";
        _showExportButton = _recordedPoseFrames.isNotEmpty;
      });
    } else {
      // Starting a new recording
      setState(() {
        _isRecordingPoses = true;
        _recordedPoseFrames = [];
        _recordedFrameCount = 0;
        _exportStatus = "Recording poses...";
        _showExportButton = false;
      });

      // If video is not playing, start it
      if (_videoController != null && !_videoController!.value.isPlaying) {
        _videoController!.play();
      }
    }
  }
}

class VideoPosePainter extends CustomPainter {
  final List<Pose> poses;
  final Size absoluteImageSize;
  final InputImageRotation rotation;

  VideoPosePainter({
    required this.poses,
    required this.absoluteImageSize,
    required this.rotation,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Different colors for different body parts
    final Paint jointPaint =
        Paint()
          ..color = Colors.red
          ..strokeWidth = 8.0;

    for (final pose in poses) {
      // Draw connections between landmarks
      _drawBodyConnections(canvas, pose);

      // Draw landmarks with different sizes based on likelihood
      pose.landmarks.forEach((type, landmark) {
        // Increase point visibility based on likelihood (reduced sizes)
        double radius =
            landmark.likelihood > 0.7
                ? 5.0 // Reduced from 7.0
                : landmark.likelihood > 0.5
                ? 3.5 // Reduced from 5.0
                : 2.0; // Reduced from 3.0

        // Scale the coordinates to match the display size
        final scaledPoint = _scalePoint(landmark.x, landmark.y);

        // Draw joint with outline for better visibility
        canvas.drawCircle(
          scaledPoint,
          radius + 1.5, // Reduced from 2.0
          Paint()..color = Colors.black.withOpacity(0.7),
        );

        // Use different colors for different body parts
        Paint pointPaint = Paint()..color = Colors.red;

        // Adjust color based on the point type
        if (type == PoseLandmarkType.nose ||
            type == PoseLandmarkType.leftEye ||
            type == PoseLandmarkType.rightEye ||
            type == PoseLandmarkType.leftEar ||
            type == PoseLandmarkType.rightEar) {
          pointPaint.color = Colors.yellow;
        } else if (type == PoseLandmarkType.leftShoulder ||
            type == PoseLandmarkType.rightShoulder ||
            type == PoseLandmarkType.leftHip ||
            type == PoseLandmarkType.rightHip) {
          pointPaint.color = Colors.orange;
        } else if (type.name.contains("Wrist") || type.name.contains("Hand")) {
          pointPaint.color = Colors.green;
        } else if (type.name.contains("Ankle") || type.name.contains("Foot")) {
          pointPaint.color = Colors.blue;
        }

        canvas.drawCircle(scaledPoint, radius, pointPaint);
      });
    }
  }

  Offset _scalePoint(double x, double y) {
    // Adapting the scaling approach from pose_detection.dart for better alignment
    // Get screen size from the absoluteImageSize (video dimensions)
    final Size screenSize = Size(
      absoluteImageSize.width,
      absoluteImageSize.height,
    );

    // Calculate aspect ratios
    final videoAspectRatio = absoluteImageSize.width / absoluteImageSize.height;
    final screenAspectRatio = screenSize.width / screenSize.height;

    // Calculate area used by the preview on screen
    double previewWidth = screenSize.width;
    double previewHeight = screenSize.height;

    // Adjust for aspect ratio differences
    if (screenAspectRatio > videoAspectRatio) {
      // Screen is wider than video - width is constraining factor
      previewWidth = previewHeight * videoAspectRatio;
    } else {
      // Screen is taller than video - height is constraining factor
      previewHeight = previewWidth / videoAspectRatio;
    }

    // Calculate offsets to center the preview
    final double offsetX = (screenSize.width - previewWidth) / 2;
    final double offsetY = (screenSize.height - previewHeight) / 2;

    // Fine-tuning parameters (adjusted for video context)
    final double alignmentCorrection =
        0.60; // Reduced from 1.0 to make skeleton 15% narrower
    final double horizontalShift =
        -0.23 * previewWidth; // Shift left by 15% of preview width
    final double verticalShift =
        -0.25 * previewHeight; // Move up by 18% of preview height

    // Calculate the final scaled coordinates
    final double scaledX =
        (previewWidth * 0.5) +
        ((x / absoluteImageSize.width - 0.5) *
            previewWidth *
            alignmentCorrection) +
        offsetX +
        horizontalShift;

    final double scaledY =
        (previewHeight * 0.5) +
        ((y / absoluteImageSize.height - 0.5) *
            previewHeight *
            alignmentCorrection) +
        offsetY +
        verticalShift;

    return Offset(scaledX, scaledY);
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

      // Make lines more visible with increased width and outline (reduced thickness)
      final Paint linePaint =
          Paint()
            ..color = color
            ..strokeWidth =
                4.0 // Reduced from 6.0
            ..strokeCap = StrokeCap.round;

      // Add outline to make lines more visible against any background
      final Paint outlinePaint =
          Paint()
            ..color = Colors.black.withOpacity(0.5)
            ..strokeWidth =
                6.0 // Reduced from 8.0
            ..strokeCap = StrokeCap.round
            ..style = PaintingStyle.stroke;

      // Draw outline first
      canvas.drawLine(startPoint, endPoint, outlinePaint);
      // Then draw the colored line
      canvas.drawLine(startPoint, endPoint, linePaint);
    }
  }

  @override
  bool shouldRepaint(VideoPosePainter oldDelegate) => true;
}
