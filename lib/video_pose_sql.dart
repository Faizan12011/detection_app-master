// ignore_for_file: use_build_context_synchronously

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:detection_app/pose_frame_db.dart';
import 'package:detection_app/pose_overlay_painter.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:google_ml_kit/google_ml_kit.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';
import 'package:flutter/rendering.dart';

/// Screen that demonstrates video-pose detection with **SQLite-backed** frame
/// caching. Every processed frame is stored in SQLite so the app never keeps
/// hundreds of megabytes in RAM.
class VideoPoseSqlScreen extends StatefulWidget {
  const VideoPoseSqlScreen({Key? key}) : super(key: key);

  @override
  State<VideoPoseSqlScreen> createState() => _VideoPoseSqlScreenState();
}

class _VideoPoseSqlScreenState extends State<VideoPoseSqlScreen> {
  // ML Kit
  late final PoseDetector _detector;
  bool _detectorReady = false;

  // Video
  VideoPlayerController? _controller;
  XFile? _sourceVideo;
  final GlobalKey _repaintKey = GlobalKey();

  // DB helper
  final PoseFrameDb _db = PoseFrameDb();

  // Playback helpers
  Timer? _streamTimer; // 30 FPS streaming timer
  List<Pose>? _overlayPoses;
  int _lastSentTs = -1;

  // Progress UI
  bool _processing = false;
  double _progress = 0.0;

  // Firebase
  late DatabaseReference _sessionRef;
  String _sessionId = 'live';

  // Captured video size used for normalization
  Size? _imageSize;

  // Constant order of landmarks when flattening / reconstructing
  static const List<PoseLandmarkType> _orderedTypes = [
    PoseLandmarkType.nose,
    PoseLandmarkType.leftEyeInner,
    PoseLandmarkType.leftEye,
    PoseLandmarkType.leftEyeOuter,
    PoseLandmarkType.rightEyeInner,
    PoseLandmarkType.rightEye,
    PoseLandmarkType.rightEyeOuter,
    PoseLandmarkType.leftEar,
    PoseLandmarkType.rightEar,
    PoseLandmarkType.leftMouth,
    PoseLandmarkType.rightMouth,
    PoseLandmarkType.leftShoulder,
    PoseLandmarkType.rightShoulder,
    PoseLandmarkType.leftElbow,
    PoseLandmarkType.rightElbow,
    PoseLandmarkType.leftWrist,
    PoseLandmarkType.rightWrist,
    PoseLandmarkType.leftPinky,
    PoseLandmarkType.rightPinky,
    PoseLandmarkType.leftIndex,
    PoseLandmarkType.rightIndex,
    PoseLandmarkType.leftThumb,
    PoseLandmarkType.rightThumb,
    PoseLandmarkType.leftHip,
    PoseLandmarkType.rightHip,
    PoseLandmarkType.leftKnee,
    PoseLandmarkType.rightKnee,
    PoseLandmarkType.leftAnkle,
    PoseLandmarkType.rightAnkle,
    PoseLandmarkType.leftHeel,
    PoseLandmarkType.rightHeel,
    PoseLandmarkType.leftFootIndex,
    PoseLandmarkType.rightFootIndex,
  ];

  @override
  void initState() {
    super.initState();
    _detector = PoseDetector(
      options: PoseDetectorOptions(
        mode: PoseDetectionMode.single,
        model: PoseDetectionModel.base, // faster but slightly less accurate
      ),
    );
    _detectorReady = true;
    _db.open();

    // Initialize Firebase session
    _initFirebaseSession();
  }

  @override
  void dispose() {
    _streamTimer?.cancel();
    _controller?.dispose();
    _detector.close();
    _db.clearAndClose();
    super.dispose();
  }

  // UI -----------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Video Pose (SQLite)')),
      floatingActionButton: _buildFAB(),
      body: _buildBody(),
    );
  }

  Widget _buildFAB() {
    if (_sourceVideo == null) {
      return FloatingActionButton(
        child: const Icon(Icons.video_library),
        onPressed: _pickVideo,
      );
    }

    if (_processing) {
      return const FloatingActionButton(
        onPressed: null,
        child: CircularProgressIndicator(color: Colors.white),
      );
    }

    final bool playing = _controller!.value.isPlaying;
    return FloatingActionButton(
      child: Icon(playing ? Icons.pause : Icons.play_arrow),
      onPressed: () {
        setState(() {
          if (playing) {
            _controller!.pause();
          } else {
            _controller!.play();
          }
        });
      },
    );
  }

  Widget _buildBody() {
    if (_sourceVideo == null) {
      return const Center(child: Text('Tap the button to pick a video.'));
    }

    return Stack(
      children: [
        Center(
          child: RepaintBoundary(
            key: _repaintKey,
            child: AspectRatio(
              aspectRatio: _controller!.value.aspectRatio,
              child: VideoPlayer(_controller!),
            ),
          ),
        ),
        if (_overlayPoses != null)
          CustomPaint(
            painter: VideoPosePainter(
              poses: _overlayPoses!,
              videoSize: _controller!.value.size,
              screenSize: MediaQuery.of(context).size,
              cameraRotation: 0,
            ),
          ),
        if (!_processing &&
            _controller != null &&
            !_controller!.value.isPlaying)
          Center(child: Icon(Icons.play_arrow, color: Colors.white, size: 64)),
        if (_processing)
          Container(
            color: Colors.black54,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(value: _progress),
                  const SizedBox(height: 12),
                  const Text(
                    'Pre-processing…',
                    style: TextStyle(color: Colors.white),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  // Picking / preprocessing ---------------------------------------------------
  Future<void> _pickVideo() async {
    final XFile? picked = await ImagePicker().pickVideo(
      source: ImageSource.gallery,
    );
    if (picked == null) return;

    await _db.clear();

    setState(() {
      _processing = true;
      _progress = 0;
      _sourceVideo = picked;
    });

    _controller = VideoPlayerController.file(File(picked.path));
    await _controller!.initialize();
    _imageSize = _controller!.value.size;

    await _processVideo();

    // Start playback & streaming
    await _controller!.seekTo(Duration.zero);
    _controller!.play();
    _controller!.addListener(_onVideoControllerUpdate);
    _startStreaming();

    setState(() => _processing = false);
  }

  Future<void> _processVideo() async {
    final int durationMs = _controller!.value.duration.inMilliseconds;
    const int step = 33; // process every frame (~30 FPS)
    final int totalFrames = (durationMs / step).ceil();

    for (int i = 0; i < totalFrames; i++) {
      final int ts = i * step;
      await _controller!.seekTo(Duration(milliseconds: ts));
      await Future.delayed(const Duration(milliseconds: 10));

      // Grab current video frame as PNG using RepaintBoundary.
      final File? imgFile = await _captureCurrentFrame();
      if (imgFile == null) continue;

      final poses = await _detector.processImage(InputImage.fromFile(imgFile));
      if (poses.isEmpty) continue;

      final List<double> kp = _poseToList(poses.first, _controller!.value.size);
      await _db.insertFrame(ts, kp, '');

      setState(() => _progress = i / totalFrames);
    }
  }

  Future<File?> _captureCurrentFrame() async {
    try {
      final RenderRepaintBoundary? boundary =
          _repaintKey.currentContext?.findRenderObject()
              as RenderRepaintBoundary?;
      if (boundary == null) return null;
      final ui.Image image = await boundary.toImage(pixelRatio: 1.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) return null;
      final tmp = await getTemporaryDirectory();
      final file = File(
        '${tmp.path}/frame_${DateTime.now().microsecondsSinceEpoch}.png',
      );
      await file.writeAsBytes(byteData.buffer.asUint8List());
      return file;
    } catch (_) {
      return null;
    }
  }

  // Playback tick ------------------------------------------------------------
  void _streamTick(Timer t) async {
    if (!_controller!.value.isPlaying) return;
    final int ts = _controller!.value.position.inMilliseconds;
    final row = await _db.getClosest(ts);
    if (row == null) return;

    final int frameTs = row['ts'] as int;
    if (frameTs == _lastSentTs) return; // already handled

    final List<double> kp =
        (jsonDecode(row['kp'] as String) as List)
            .map((e) => (e as num).toDouble())
            .toList();

    // Convert to Pose & Firebase push
    final pose = _listToPose(kp, _controller!.value.size);
    _sendPosesToFirebase([pose]);
    _lastSentTs = frameTs;

    // Overlay
    setState(() => _overlayPoses = [pose]);
  }

  // -------------------------------------------------------------------------
  // Streaming helpers
  // -------------------------------------------------------------------------
  void _onVideoControllerUpdate() {
    final playing = _controller!.value.isPlaying;
    if (playing && _streamTimer == null) {
      _startStreaming();
    } else if (!playing && _streamTimer != null) {
      _stopStreaming();
    }
  }

  void _startStreaming() {
    _streamTimer ??= Timer.periodic(
      const Duration(milliseconds: 33),
      _streamTick,
    );
  }

  void _stopStreaming() {
    _streamTimer?.cancel();
    _streamTimer = null;
  }

  // Utils --------------------------------------------------------------------
  List<double> _poseToList(Pose pose, Size size) {
    final List<double> list = [];
    for (final t in _orderedTypes) {
      final landmark = pose.landmarks[t]!;
      list.add(landmark.x / size.width);
      list.add(landmark.y / size.height);
      list.add(landmark.z / size.width); // z normalized on width
    }
    return list;
  }

  Pose _listToPose(List<double> kp, Size size) {
    final Map<PoseLandmarkType, PoseLandmark> map = {};
    for (int i = 0; i < _orderedTypes.length; i++) {
      final double x = kp[i * 3] * size.width;
      final double y = kp[i * 3 + 1] * size.height;
      final double z = kp[i * 3 + 2] * size.width;
      map[_orderedTypes[i]] = PoseLandmark(
        type: _orderedTypes[i],
        x: x,
        y: y,
        z: z,
        likelihood: 0.0,
      );
    }
    return Pose(landmarks: map);
  }

  // -------------------------------------------------------------------------
  // Firebase helpers
  // -------------------------------------------------------------------------
  Future<void> _initFirebaseSession() async {
    _sessionRef = FirebaseDatabase.instance.ref('sessions/$_sessionId');
    await _sessionRef.child('metadata').set({
      'fps': 30,
      'status': 'live',
      'createdAt': ServerValue.timestamp,
    });
  }

  void _sendPosesToFirebase(List<Pose> poses) {
    if (poses.isEmpty) return;

    final pose = poses.first;

    final List<double> kp = [];
    final double imgWidth = _imageSize?.width ?? 1.0;
    final double imgHeight = _imageSize?.height ?? 1.0;

    for (final type in _orderedTypes) {
      final lm = pose.landmarks[type];
      if (lm != null) {
        final xNorm = lm.x / imgWidth;
        final yNorm = lm.y / imgHeight;
        final zNorm = lm.z / imgWidth;
        kp.addAll([xNorm, yNorm, zNorm]);
      } else {
        kp.addAll([0.0, 0.0, 0.0]);
      }
    }

    _sessionRef.child('frames').push().set({
      'ts': ServerValue.timestamp,
      'kp': kp,
    });
  }
}
