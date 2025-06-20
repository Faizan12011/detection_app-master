import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

/// A lightweight wrapper around `sqflite` used by the video-pose screen
/// to persist every processed pose frame on disk instead of keeping them
/// all in memory.
///
/// Table schema (v1):
///   frames(
///     ts  INTEGER PRIMARY KEY,   -- video timestamp (milliseconds)
///     kp  TEXT NOT NULL,         -- JSON-encoded List<double> (length 99)
///     cat TEXT                   -- optional high-level pose label
///   )
class PoseFrameDb {
  static const _dbFileName = 'video_pose_tmp.db';
  static const _table = 'frames';

  Database? _db;

  Future<void> open() async {
    if (_db != null) return;
    final Directory dir = await getTemporaryDirectory();
    final String path = p.join(dir.path, _dbFileName);

    _db = await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute(
          'CREATE TABLE $_table ('
          'ts INTEGER PRIMARY KEY, '
          'kp TEXT NOT NULL, '
          'cat TEXT'
          ')',
        );
      },
    );
  }

  Future<void> clear() async {
    if (_db == null) throw StateError('DB not open');
    await _db!.delete(_table);
  }

  Future<void> insertFrame(
    int timestampMs,
    List<double> kp,
    String category,
  ) async {
    if (_db == null) throw StateError('DB not open');
    await _db!.insert(
      _table,
      {
        'ts': timestampMs,
        'kp': jsonEncode(kp),
        'cat': category,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Returns the frame row whose `ts` is <= target and closest to it.
  Future<Map<String, Object?>?> getClosest(int targetTs) async {
    if (_db == null) throw StateError('DB not open');
    final rows = await _db!.rawQuery(
      'SELECT * FROM $_table WHERE ts <= ? ORDER BY ts DESC LIMIT 1',
      [targetTs],
    );
    if (rows.isNotEmpty) return rows.first;

    // fallback: earliest after target (first frames)
    final after = await _db!.rawQuery(
      'SELECT * FROM $_table WHERE ts > ? ORDER BY ts ASC LIMIT 1',
      [targetTs],
    );
    return after.isNotEmpty ? after.first : null;
  }

  Future<void> clearAndClose() async {
    if (_db == null) return;
    final path = _db!.path;
    await _db!.close();
    _db = null;
    if (await File(path).exists()) {
      await deleteDatabase(path);
    }
  }
}
