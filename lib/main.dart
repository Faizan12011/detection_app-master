import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'camera_detection.dart';
import 'gallery_detection.dart';
import 'pose_detection.dart';
import 'video_pose.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  runApp(DetectionApp());
}

class DetectionApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Detection App',
      theme: ThemeData(primarySwatch: Colors.blue, fontFamily: 'Montserrat'),
      home: MainScreen(),
    );
  }
}

class MainScreen extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Detection App',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        centerTitle: true,
        elevation: 5,
        backgroundColor: Colors.blue.shade700,
      ),
      body: Stack(
        children: [
          /// Background Gradient
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [Colors.blue.shade800, Colors.purple.shade600],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
            ),
          ),

          /// Main Content
          Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _buildCustomButton(
                  context,
                  title: 'Camera Object Detection',
                  icon: Icons.camera_alt_rounded,
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => CameraDetectionScreen(),
                      ),
                    );
                  },
                ),
                SizedBox(height: 20),

                _buildCustomButton(
                  context,
                  title: 'Gallery Image Object Detection',
                  icon: Icons.image,
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => GalleryDetectionScreen(),
                      ),
                    );
                  },
                ),
                SizedBox(height: 20),

                _buildCustomButton(
                  context,
                  title: 'Human Pose Detection',
                  icon: Icons.accessibility_new,
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => PoseDetectionScreen(),
                      ),
                    );
                  },
                ),
                SizedBox(height: 20),
                _buildCustomButton(
                  context,
                  title: 'Video Pose Tracking',
                  icon: Icons.accessibility_new,
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (context) => VideoPose()),
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Custom Elevated Button with Style
  Widget _buildCustomButton(
    BuildContext context, {
    required String title,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return ElevatedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 28),
      label: Text(
        title,
        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
      ),
      style: ElevatedButton.styleFrom(
        padding: EdgeInsets.symmetric(horizontal: 20, vertical: 15),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        backgroundColor: Colors.white,
        foregroundColor: Colors.blue.shade800,
        shadowColor: Colors.black26,
        elevation: 5,
      ),
    );
  }
}
