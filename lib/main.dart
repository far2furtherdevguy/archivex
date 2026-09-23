import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' show PlatformDispatcher;

import 'package:archive/archive_io.dart';
import 'package:cryptography/cryptography.dart' as crypto;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

// ─────────────────────────────── DEBUG LOG ───────────────────────────────

class AppLog {
  static final ValueNotifier<List<String>> lines = ValueNotifier<List<String>>([]);
  static File? file;

  static Future<void> init() async {
    try {
      final d = await getApplicationDocumentsDirectory();
      file = File(p.join(d.path, 'debug.log'));
      if (file!.existsSync() && file!.lengthSync() > 512 * 1024) {
        file!.writeAsStringSync('');
      }
    } catch (_) {}
    i('app', 'ArchiveX started, log file: ${file?.path}');
  }

  static void _add(String level, String tag, String msg) {
    final line = '${DateTime.now().toIso8601String()} [$level] $tag: $msg';
    debugPrint(line);
    var l = [...lines.value, line];
    if (l.length > 1500) l = l.sublist(500);
    lines.value = l;
    try {
      file?.writeAsStringSync('$line\n', mode: FileMode.append);
    } catch (_) {}
  }

  static void i(String tag, String msg) => _add('INFO', tag, msg);
  static void e(String tag, String msg, [StackTrace? st]) =>
      _add('ERROR', tag, st == null ? msg : '$msg\n$st');
}

// ─────────────────────────────── ARCHIVE ENGINE ───────────────────────────────
// Everything below runs inside Isolate.run so the UI never freezes.

enum Kind { zip, tar, tgz, tbz2, gz, bz2, aes, other }

Kind kindOf(String path) {
  final n = path.toLowerCase();
  if (n.endsWith('.aes')) return Kind.aes;
  if (n.endsWith('.tar.gz') || n.endsWith('.tgz')) return Kind.tgz;
  if (n.endsWith('.tar.bz2') || n.endsWith('.tbz2') || n.endsWith('.tbz')) return Kind.tbz2;
  if (n.endsWith('.tar')) return Kind.tar;
  if (n.endsWith('.zip') || n.endsWith('.jar') || n.endsWith('.apk')) return Kind.zip;
  if (n.endsWith('.gz')) return Kind.gz;
  if (n.endsWith('.bz2')) return Kind.bz2;
  return Kind.other;
}

bool isArchive(String path) {
  final k = kindOf(path);
  return k != Kind.aes && k != Kind.other;
}

String stemOf(String path) {
  final b = p.basename(path);
  final l = b.toLowerCase();
  for (final s in ['.tar.gz', '.tar.bz2', '.tgz', '.tbz2', '.tbz', '.tar', '.zip', '.jar', '.apk', '.gz', '.bz2', '.aes']) {
    if (l.endsWith(s) && b.length > s.length) return b.substring(0, b.length - s.length);
  }
  return p.basenameWithoutExtension(b);
}

String uniquePath(String path) {
  if (FileSystemEntity.typeSync(path) == FileSystemEntityType.notFound) return path;
  final dir = p.dirname(path);
  final b = p.basename(path);
  final i = b.indexOf('.', 1);
  final stem = i < 0 ? b : b.substring(0, i);
  final ext = i < 0 ? '' : b.substring(i);
  var n = 1;
  while (true) {
    final c = p.join(dir, '$stem ($n)$ext');
    if (FileSystemEntity.typeSync(c) == FileSystemEntityType.notFound) return c;
    n++;
  }
}

class Entry {
  final String name;
  final int size;
  final bool isDir;
  Entry(this.name, this.size, this.isDir);
}

Archive _open(String path, Kind k) {
  switch (k) {
    case Kind.zip:
      return ZipDecoder().decodeBuffer(InputFileStream(path));
    case Kind.tar:
      return TarDecoder().decodeBytes(File(path).readAsBytesSync());
    case Kind.tgz:
      return TarDecoder().decodeBytes(GZipDecoder().decodeBytes(File(path).readAsBytesSync()));
    case Kind.tbz2:
      return TarDecoder().decodeBytes(BZip2Decoder().decodeBytes(File(path).readAsBytesSync()));
    default:
      throw UnsupportedError('Unsupported archive type');
  }
}

List<Entry> listArchive(String path) {
  final k = kindOf(path);
  if (k == Kind.gz || k == Kind.bz2) {
    return [Entry(stemOf(path), File(path).lengthSync(), false)];
  }
  final a = _open(path, k);
  return a.files.map((f) => Entry(f.name, f.size, !f.isFile)).toList();
}

/// Returns [extractedCount, skippedUnsafeCount]. Blocks "zip-slip" path traversal.
List<int> extractArchive(String path, String outDir) {
  final k = kindOf(path);
  final root = p.normalize(outDir);
  Directory(root).createSync(recursive: true);
  if (k == Kind.gz || k == Kind.bz2) {
    final data = File(path).readAsBytesSync();
    final raw = k == Kind.gz ? GZipDecoder().decodeBytes(data) : BZip2Decoder().decodeBytes(data);
    File(p.join(root, stemOf(path))).writeAsBytesSync(raw);
    return [1, 0];
  }
  final a = _open(path, k);
  var ok = 0, skipped = 0;
  for (final f in a.files) {
    final target = p.normalize(p.join(root, f.name));
    if (target != root && !p.isWithin(root, target)) {
      skipped++;
      continue;
    }
    if (f.isFile) {
      Directory(p.dirname(target)).createSync(recursive: true);
      File(target).writeAsBytesSync(f.content as List<int>);
      ok++;
    } else {
      Directory(target).createSync(recursive: true);
    }
  }
  return [ok, skipped];
}

Archive _build(List<String> paths) {
  final a = Archive();
  void add(FileSystemEntity e, String rel) {
    if (e is File) {
      final b = e.readAsBytesSync();
      a.addFile(ArchiveFile(rel, b.length, b));
    } else if (e is Directory) {
      for (final c in e.listSync()) {
        add(c, p.join(rel, p.basename(c.path)));
      }
    }
  }

  for (final s in paths) {
    if (FileSystemEntity.isDirectorySync(s)) {
      add(Directory(s), p.basename(s));
    } else {
      add(File(s), p.basename(s));
    }
  }
  return a;
}

Future<String> compressJob(List<String> paths, String dir, String name, String fmt, String? pw) async {
  final out = uniquePath(p.join(dir, '$name.$fmt'));
  if (fmt == 'zip') {
    final enc = ZipFileEncoder();
    enc.create(out);
    for (final s in paths) {
      if (FileSystemEntity.isDirectorySync(s)) {
        await enc.addDirectory(Directory(s));
      } else {
        await enc.addFile(File(s));
      }
    }
    await enc.close();
  } else {
    final tar = TarEncoder().encode(_build(paths));
    final List<int>? data = fmt == 'tar'
        ? tar
        : fmt == 'tar.gz'
            ? GZipEncoder().encode(tar)
            : BZip2Encoder().encode(tar);
    File(out).writeAsBytesSync(data!);
  }
  if (pw != null && pw.isNotEmpty) {
    final enc = await encryptFile(out, pw);
    File(out).deleteSync();
    return 'Created ${p.basename(enc)} (AES-256-GCM)';
  }
  return 'Created ${p.basename(out)}';
}

// ─────────────── ENCRYPTION: AES-256-GCM + PBKDF2-HMAC-SHA256 ───────────────
// File layout: "AXE1"(4) | iterations u32 BE(4) | salt(16) | nonce(12) | ciphertext | GCM tag(16)
// The 36-byte header is authenticated as AAD. Fresh random salt + nonce per file.

const int _kdfIterations = 310000;
const List<int> _magic = [0x41, 0x58, 0x45, 0x31];

Future<crypto.SecretKey> _kdf(String pw, List<int> salt, int iterations) =>
    crypto.Pbkdf2(macAlgorithm: crypto.Hmac.sha256(), iterations: iterations, bits: 256)
        .deriveKeyFromPassword(password: pw, nonce: salt);

Uint8List _rand(int n) {
  final r = Random.secure();
  return Uint8List.fromList(List<int>.generate(n, (_) => r.nextInt(256)));
}

Future<String> encryptFile(String inPath, String password) async {
  final salt = _rand(16), nonce = _rand(12);
  final iter = Uint8List(4)..buffer.asByteData().setUint32(0, _kdfIterations);
  final header = (BytesBuilder()..add(_magic)..add(iter)..add(salt)..add(nonce)).toBytes();
  final key = await _kdf(password, salt, _kdfIterations);
  final box = await crypto.AesGcm.with256bits().encrypt(
    File(inPath).readAsBytesSync(),
    secretKey: key,
    nonce: nonce,
    aad: header,
  );
  final out = uniquePath('$inPath.aes');
  File(out).writeAsBytesSync((BytesBuilder()..add(header)..add(box.cipherText)..add(box.mac.bytes)).toBytes());
  return out;
}

Future<String> decryptFile(String inPath, String outDir, String password) async {
  final d = File(inPath).readAsBytesSync();
  if (d.length < 52 || d[0] != _magic[0] || d[1] != _magic[1] || d[2] != _magic[2] || d[3] != _magic[3]) {
    throw const FormatException('Not an ArchiveX AES-256-GCM file');
  }
  final iter = ByteData.sublistView(d, 4, 8).getUint32(0);
  if (iter < 100000 || iter > 5000000) throw const FormatException('Invalid key-derivation parameters');
  final header = Uint8List.sublistView(d, 0, 36);
  final salt = Uint8List.sublistView(d, 8, 24);
  final nonce = Uint8List.sublistView(d, 24, 36);
  final cipher = Uint8List.sublistView(d, 36, d.length - 16);
  final mac = Uint8List.sublistView(d, d.length - 16);
  final key = await _kdf(password, salt, iter);
  try {
    final clear = await crypto.AesGcm.with256bits().decrypt(
      crypto.SecretBox(cipher, nonce: nonce, mac: crypto.Mac(mac)),
      secretKey: key,
      aad: header,
    );
    final b = p.basename(inPath);
    final name = b.toLowerCase().endsWith('.aes') && b.length > 4 ? b.substring(0, b.length - 4) : '$b.dec';
    final out = uniquePath(p.join(outDir, name));
    File(out).writeAsBytesSync(clear);
    return out;
  } on crypto.SecretBoxAuthenticationError {
    throw Exception('Wrong password or file is corrupted');
  }
}

String pasteJob(List<String> src, String dest, bool move) {
  void copyDir(Directory from, Directory to) {
    to.createSync(recursive: true);
    for (final e in from.listSync()) {
      final t = p.join(to.path, p.basename(e.path));
      if (e is Directory) {
        copyDir(e, Directory(t));
      } else if (e is File) {
        e.copySync(t);
      }
    }
  }

  for (final s in src) {
    final target = uniquePath(p.join(dest, p.basename(s)));
    if (FileSystemEntity.isDirectorySync(s)) {
      if (p.equals(s, dest) || p.isWithin(s, dest)) {
        throw Exception('Cannot copy a folder into itself');
      }
      copyDir(Directory(s), Directory(target));
      if (move) Directory(s).deleteSync(recursive: true);
    } else {
      File(s).copySync(target);
      if (move) File(s).deleteSync();
    }
  }
  return '${move ? 'Moved' : 'Copied'} ${src.length} item(s)';
}

// ─────────────────────────────── STORAGE PERMISSION ───────────────────────────────

class Storage {
  static Future<bool> has() async {
    if (!Platform.isAndroid) return true;
    if (await Permission.manageExternalStorage.isGranted) return true;
    return Permission.storage.isGranted;
  }

  static Future<bool> request() async {
    if (!Platform.isAndroid) return true;
    // Android 11+: "All files access" (opens system settings page).
    final m = await Permission.manageExternalStorage.request();
    AppLog.i('perm', 'manageExternalStorage -> $m');
    if (m.isGranted) return true;
    // Android 10 and below: classic storage permission.
    final s = await Permission.storage.request();
    AppLog.i('perm', 'storage -> $s');
    return s.isGranted;
  }
}

// ─────────────────────────────── APP ───────────────────────────────

void main() {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    await AppLog.init();
    FlutterError.onError = (d) => AppLog.e('flutter', d.exceptionAsString(), d.stack);
    PlatformDispatcher.instance.onError = (err, st) {
      AppLog.e('platform', '$err', st);
      return true;
    };
    runApp(const ArchiveXApp());
  }, (err, st) => AppLog.e('zone', '$err', st));
}

class ArchiveXApp extends StatelessWidget {
  const ArchiveXApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'ArchiveX',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
        darkTheme: ThemeData(colorSchemeSeed: Colors.teal, brightness: Brightness.dark, useMaterial3: true),
        home: const PermissionGate(),
      );
}

class PermissionGate extends StatefulWidget {
  const PermissionGate({super.key});
  @override
  State<PermissionGate> createState() => _PermissionGateState();
}

class _PermissionGateState extends State<PermissionGate> with WidgetsBindingObserver {
  bool? _ok;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) _check();
  }

  Future<void> _check() async {
    final ok = await Storage.has();
    AppLog.i('perm', 'storage granted = $ok');
    if (mounted) setState(() => _ok = ok);
  }

  Future<void> _ask() async {
    final ok = await Storage.request();
    if (mounted) setState(() => _ok = ok);
  }

  @override
  Widget build(BuildContext context) {
    if (_ok == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (_ok!) return const BrowserPage();
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.folder_special, size: 84),
              const SizedBox(height: 20),
              const Text('Storage access needed', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              const Text(
                'ArchiveX needs access to your files to create and extract archives. '
                'On Android 11+ enable “Allow access to manage all files” for ArchiveX.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 28),
              FilledButton.icon(onPressed: _ask, icon: const Icon(Icons.lock_open), label: const Text('Grant permission')),
              TextButton(onPressed: openAppSettings, child: const Text('Open app settings')),
              TextButton(
                onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const LogPage())),
                child: const Text('View debug log'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────── BROWSER ───────────────────────────────

class BrowserPage extends StatefulWidget {
  const BrowserPage({super.key});
  @override
  State<BrowserPage> createState() => _BrowserPageState();
}

class _BrowserPageState extends State<BrowserPage> {
  String root = '/storage/emulated/0';
  late Directory cwd = Directory(root);
  List<FileSystemEntity> items = [];
  Map<String, FileStat> stats = {};
  final Set<String> sel = {};
  List<String> clip = [];
  bool clipMove = false;
  bool searching = false;
  String query = '';

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    if (!Directory(root).existsSync()) {
      root = (await getApplicationDocumentsDirectory()).path;
      cwd = Directory(root);
    }
    _load();
  }

  void _toast(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(m)));
  }

  void _load() {
    try {
      final l = cwd.listSync();
      l.sort((a, b) {
        final ad = a is Directory, bd = b is Directory;
        if (ad != bd) return ad ? -1 : 1;
        return p.basename(a.path).toLowerCase().compareTo(p.basename(b.path).toLowerCase());
      });
      final s = <String, FileStat>{};
      for (final e in l) {
        try {
          s[e.path] = e.statSync();
        } catch (_) {}
      }
      items = l;
      stats = s;
      AppLog.i('browse', '${cwd.path}: ${l.length} items');
    } catch (e, st) {
      AppLog.e('browse', 'Cannot list ${cwd.path}: $e', st);
      items = [];
      _toast('Cannot read folder: $e');
    }
    if (mounted) setState(() {});
  }

  void _go(String path) {
    cwd = Directory(path);
    sel.clear();
    query = '';
    searching = false;
    _load();
  }

  Future<void> _job(String label, Future<String> Function() fn) async {
    AppLog.i('job', 'start: $label');
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: Row(children: [
            const CircularProgressIndicator(),
            const SizedBox(width: 20),
            Expanded(child: Text(label)),
          ]),
        ),
      ),
    );
    String msg;
    try {
      msg = await fn();
      AppLog.i('job', 'done: $label -> $msg');
    } catch (e, st) {
      msg = 'Failed: $e';
      AppLog.e('job', '$label: $e', st);
    }
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop();
    _toast(msg);
    sel.clear();
    _load();
  }

  Future<String?> _ask(String title, {String initial = '', bool secret = false, String hint = ''}) {
    final c = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: TextField(controller: c, autofocus: true, obscureText: secret, decoration: InputDecoration(hintText: hint)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, c.text), child: const Text('OK')),
        ],
      ),
    );
  }

  Future<bool> _confirm(String msg) async =>
      await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          content: Text(msg),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Yes')),
          ],
        ),
      ) ??
      false;

  Future<void> _compress() async {
    final paths = sel.toList();
    final o = await showDialog<_CompressOpts>(
      context: context,
      builder: (_) => _CompressDialog(defaultName: paths.length == 1 ? stemOf(paths.first) : 'archive'),
    );
    if (o == null) return;
    final dir = cwd.path;
    await _job('Compressing…', () => Isolate.run(() => compressJob(paths, dir, o.name, o.format, o.password)));
  }

  Future<void> _extract(String path) async {
    final out = uniquePath(p.join(cwd.path, stemOf(path)));
    await _job('Extracting…', () => Isolate.run(() {
          final r = extractArchive(path, out);
          return 'Extracted ${r[0]} files${r[1] > 0 ? ' (${r[1]} unsafe entries skipped)' : ''}';
        }));
  }

  Future<void> _decrypt(String path) async {
    final pw = await _ask('Password', secret: true);
    if (pw == null || pw.isEmpty) return;
    final dir = cwd.path;
    await _job('Decrypting…', () => Isolate.run(() async => 'Created ${p.basename(await decryptFile(path, dir, pw))}'));
  }

  Future<void> _encrypt(String path) async {
    final pw = await _ask('Set password (min 8 chars)', secret: true);
    if (pw == null) return;
    if (pw.length < 8) {
      _toast('Password must be at least 8 characters');
      return;
    }
    await _job('Encrypting (AES-256-GCM)…', () => Isolate.run(() async => 'Created ${p.basename(await encryptFile(path, pw))}'));
  }

  Future<void> _delete() async {
    final paths = sel.toList();
    if (!await _confirm('Delete ${paths.length} item(s)? This cannot be undone.')) return;
    await _job('Deleting…', () => Isolate.run(() {
          for (final s in paths) {
            if (FileSystemEntity.isDirectorySync(s)) {
              Directory(s).deleteSync(recursive: true);
            } else {
              File(s).deleteSync();
            }
          }
          return 'Deleted ${paths.length} item(s)';
        }));
  }

  Future<void> _rename() async {
    final path = sel.first;
    final n = await _ask('Rename', initial: p.basename(path));
    if (n == null || n.trim().isEmpty || n.contains('/')) return;
    final target = p.join(p.dirname(path), n.trim());
    if (FileSystemEntity.typeSync(target) != FileSystemEntityType.notFound) {
      _toast('A file with that name already exists');
      return;
    }
    try {
      FileSystemEntity.isDirectorySync(path) ? Directory(path).renameSync(target) : File(path).renameSync(target);
      AppLog.i('rename', '$path -> $target');
    } catch (e, st) {
      AppLog.e('rename', '$e', st);
      _toast('Rename failed: $e');
    }
    sel.clear();
    _load();
  }

  Future<void> _newFolder() async {
    final n = await _ask('New folder');
    if (n == null || n.trim().isEmpty || n.contains('/')) return;
    try {
      Directory(p.join(cwd.path, n.trim())).createSync();
      AppLog.i('mkdir', n);
    } catch (e, st) {
      AppLog.e('mkdir', '$e', st);
      _toast('Failed: $e');
    }
    _load();
  }

  Future<void> _paste() async {
    final src = List<String>.from(clip);
    final move = clipMove;
    final dest = cwd.path;
    clip = [];
    await _job(move ? 'Moving…' : 'Copying…', () => Isolate.run(() => pasteJob(src, dest, move)));
  }

  Future<void> _openEntity(FileSystemEntity e) async {
    if (sel.isNotEmpty) {
      setState(() => sel.contains(e.path) ? sel.remove(e.path) : sel.add(e.path));
      return;
    }
    if (e is Directory) return _go(e.path);
    if (kindOf(e.path) == Kind.aes) return _decrypt(e.path);
    if (isArchive(e.path)) {
      final extract = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => ArchiveViewPage(path: e.path)));
      if (extract == true) await _extract(e.path);
    } else {
      _toast('${p.basename(e.path)} — not an archive');
    }
  }

  IconData _icon(FileSystemEntity e) {
    if (e is Directory) return Icons.folder;
    final k = kindOf(e.path);
    if (k == Kind.aes) return Icons.lock;
    if (k != Kind.other) return Icons.inventory_2;
    return Icons.insert_drive_file_outlined;
  }

  @override
  Widget build(BuildContext context) {
    final shown = query.isEmpty
        ? items
        : items.where((e) => p.basename(e.path).toLowerCase().contains(query.toLowerCase())).toList();
    final selecting = sel.isNotEmpty;
    return PopScope(
      canPop: !selecting && cwd.path == root && !searching,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (selecting) {
          setState(sel.clear);
        } else if (searching) {
          setState(() {
            searching = false;
            query = '';
          });
        } else {
          _go(cwd.parent.path);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          leading: selecting
              ? IconButton(icon: const Icon(Icons.close), onPressed: () => setState(sel.clear))
              : (cwd.path != root ? IconButton(icon: const Icon(Icons.arrow_upward), onPressed: () => _go(cwd.parent.path)) : null),
          title: selecting
              ? Text('${sel.length} selected')
              : searching
                  ? TextField(
                      autofocus: true,
                      decoration: const InputDecoration(hintText: 'Search this folder', border: InputBorder.none),
                      onChanged: (v) => setState(() => query = v),
                    )
                  : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Text('ArchiveX', style: TextStyle(fontSize: 18)),
                      Text(cwd.path, style: const TextStyle(fontSize: 11), overflow: TextOverflow.ellipsis),
                    ]),
          actions: selecting
              ? [
                  IconButton(icon: const Icon(Icons.archive), tooltip: 'Compress', onPressed: _compress),
                  IconButton(
                      icon: const Icon(Icons.copy),
                      tooltip: 'Copy',
                      onPressed: () => setState(() {
                            clip = sel.toList();
                            clipMove = false;
                            sel.clear();
                          })),
                  IconButton(
                      icon: const Icon(Icons.content_cut),
                      tooltip: 'Cut',
                      onPressed: () => setState(() {
                            clip = sel.toList();
                            clipMove = true;
                            sel.clear();
                          })),
                  IconButton(icon: const Icon(Icons.delete), tooltip: 'Delete', onPressed: _delete),
                  PopupMenuButton<String>(
                    onSelected: (v) {
                      if (v == 'rename') _rename();
                      if (v == 'encrypt') _encrypt(sel.first);
                      if (v == 'all') setState(() => sel.addAll(shown.map((e) => e.path)));
                    },
                    itemBuilder: (_) => [
                      if (sel.length == 1) const PopupMenuItem(value: 'rename', child: Text('Rename')),
                      if (sel.length == 1 && FileSystemEntity.isFileSync(sel.first))
                        const PopupMenuItem(value: 'encrypt', child: Text('Encrypt (AES-256-GCM)')),
                      const PopupMenuItem(value: 'all', child: Text('Select all')),
                    ],
                  ),
                ]
              : [
                  IconButton(icon: const Icon(Icons.search), onPressed: () => setState(() => searching = !searching)),
                  if (clip.isNotEmpty) IconButton(icon: const Icon(Icons.content_paste), tooltip: 'Paste here', onPressed: _paste),
                  PopupMenuButton<String>(
                    onSelected: (v) {
                      if (v == 'new') _newFolder();
                      if (v == 'refresh') _load();
                      if (v == 'log') Navigator.push(context, MaterialPageRoute(builder: (_) => const LogPage()));
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'new', child: Text('New folder')),
                      PopupMenuItem(value: 'refresh', child: Text('Refresh')),
                      PopupMenuItem(value: 'log', child: Text('Debug log')),
                    ],
                  ),
                ],
        ),
        body: shown.isEmpty
            ? const Center(child: Text('Empty'))
            : ListView.builder(
                itemCount: shown.length,
                itemBuilder: (_, i) {
                  final e = shown[i];
                  final st = stats[e.path];
                  final isSel = sel.contains(e.path);
                  return ListTile(
                    selected: isSel,
                    leading: Icon(isSel ? Icons.check_circle : _icon(e)),
                    title: Text(p.basename(e.path), overflow: TextOverflow.ellipsis),
                    subtitle: st == null
                        ? null
                        : Text('${e is Directory ? '' : '${fmtSize(st.size)} · '}${st.modified.toString().substring(0, 16)}'),
                    onTap: () => _openEntity(e),
                    onLongPress: () => setState(() => isSel ? sel.remove(e.path) : sel.add(e.path)),
                  );
                },
              ),
      ),
    );
  }
}

String fmtSize(int b) {
  if (b < 1024) return '$b B';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
  if (b < 1024 * 1024 * 1024) return '${(b / 1048576).toStringAsFixed(1)} MB';
  return '${(b / 1073741824).toStringAsFixed(2)} GB';
}

// ─────────────────────────────── DIALOGS / PAGES ───────────────────────────────

class _CompressOpts {
  final String name, format;
  final String? password;
  _CompressOpts(this.name, this.format, this.password);
}

class _CompressDialog extends StatefulWidget {
  final String defaultName;
  const _CompressDialog({required this.defaultName});
  @override
  State<_CompressDialog> createState() => _CompressDialogState();
}

class _CompressDialogState extends State<_CompressDialog> {
  late final name = TextEditingController(text: widget.defaultName);
  final pw1 = TextEditingController();
  final pw2 = TextEditingController();
  String fmt = 'zip';
  String? err;

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Create archive'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: name, decoration: const InputDecoration(labelText: 'Name')),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              value: fmt,
              decoration: const InputDecoration(labelText: 'Format'),
              items: const ['zip', 'tar.gz', 'tar.bz2', 'tar'].map((f) => DropdownMenuItem(value: f, child: Text('.$f'))).toList(),
              onChanged: (v) => setState(() => fmt = v!),
            ),
            const SizedBox(height: 8),
            TextField(controller: pw1, obscureText: true, decoration: const InputDecoration(labelText: 'Password (optional, AES-256-GCM)')),
            TextField(controller: pw2, obscureText: true, decoration: const InputDecoration(labelText: 'Repeat password')),
            if (err != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(err!, style: const TextStyle(color: Colors.red))),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              final n = name.text.trim();
              if (n.isEmpty || n.contains('/')) return setState(() => err = 'Invalid name');
              if (pw1.text.isNotEmpty && pw1.text.length < 8) return setState(() => err = 'Password must be at least 8 characters');
              if (pw1.text != pw2.text) return setState(() => err = 'Passwords do not match');
              Navigator.pop(context, _CompressOpts(n, fmt, pw1.text.isEmpty ? null : pw1.text));
            },
            child: const Text('Create'),
          ),
        ],
      );
}

class ArchiveViewPage extends StatelessWidget {
  final String path;
  const ArchiveViewPage({super.key, required this.path});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: Text(p.basename(path), overflow: TextOverflow.ellipsis),
          actions: [
            TextButton.icon(
              onPressed: () => Navigator.pop(context, true),
              icon: const Icon(Icons.unarchive),
              label: const Text('Extract'),
            ),
          ],
        ),
        body: FutureBuilder<List<Entry>>(
          future: Isolate.run(() => listArchive(path)),
          builder: (_, snap) {
            if (snap.hasError) {
              AppLog.e('view', 'Cannot read $path: ${snap.error}');
              return Center(child: Padding(padding: const EdgeInsets.all(24), child: Text('Cannot read archive:\n${snap.error}')));
            }
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            final l = snap.data!;
            return ListView.builder(
              itemCount: l.length,
              itemBuilder: (_, i) => ListTile(
                dense: true,
                leading: Icon(l[i].isDir ? Icons.folder : Icons.insert_drive_file_outlined),
                title: Text(l[i].name),
                subtitle: l[i].isDir ? null : Text(fmtSize(l[i].size)),
              ),
            );
          },
        ),
      );
}

class LogPage extends StatelessWidget {
  const LogPage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('Debug log'),
          actions: [
            IconButton(
              icon: const Icon(Icons.copy),
              tooltip: 'Copy all',
              onPressed: () {
                Clipboard.setData(ClipboardData(text: AppLog.lines.value.join('\n')));
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Log copied')));
              },
            ),
            IconButton(icon: const Icon(Icons.delete_sweep), tooltip: 'Clear', onPressed: () => AppLog.lines.value = []),
          ],
        ),
        body: ValueListenableBuilder<List<String>>(
          valueListenable: AppLog.lines,
          builder: (_, l, __) => Column(children: [
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text('File: ${AppLog.file?.path ?? 'n/a'}', style: const TextStyle(fontSize: 11)),
            ),
            Expanded(
              child: ListView.builder(
                reverse: true,
                itemCount: l.length,
                itemBuilder: (_, i) {
                  final line = l[l.length - 1 - i];
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    child: SelectableText(
                      line,
                      style: TextStyle(fontFamily: 'monospace', fontSize: 11, color: line.contains('[ERROR]') ? Colors.red : null),
                    ),
                  );
                },
              ),
            ),
          ]),
        ),
      );
}
