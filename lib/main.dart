import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:macos_ui/macos_ui.dart' as mac;

const _port = 49321;
const _channel = MethodChannel('io.penbridge/input');
const _accent = Color(0xff7c5cff);

enum BridgeMode {
  pen('pen', 'Kalem', Icons.draw_rounded, 'Basınç ve eğim'),
  mouse('mouse', 'Mouse', Icons.mouse_rounded, 'Mutlak imleç'),
  trackpad('trackpad', 'Trackpad', Icons.touch_app_rounded, 'Göreceli hareket'),
  blender(
    'blender',
    'Blender',
    Icons.view_in_ar_rounded,
    'Hazır 3D kontroller',
  );

  const BridgeMode(this.id, this.label, this.icon, this.subtitle);
  final String id;
  final String label;
  final IconData icon;
  final String subtitle;

  static BridgeMode from(String? value) => values.firstWhere(
    (mode) => mode.id == value,
    orElse: () => BridgeMode.pen,
  );
}

enum BlenderTool {
  draw('draw', 'Çiz', Icons.brush_rounded),
  orbit('orbit', 'Döndür', Icons.threesixty_rounded),
  pan('pan', 'Kaydır', Icons.open_with_rounded),
  zoom('zoom', 'Zoom', Icons.zoom_in_rounded);

  const BlenderTool(this.id, this.label, this.icon);
  final String id;
  final String label;
  final IconData icon;
}

void main() => runApp(const PenBridgeApp());

class PenBridgeApp extends StatelessWidget {
  const PenBridgeApp({super.key});

  @override
  Widget build(BuildContext context) {
    if (Platform.isMacOS) {
      return mac.MacosApp(
        debugShowCheckedModeBanner: false,
        title: 'PenBridge',
        theme: mac.MacosThemeData.dark(),
        home: const MacReceiverPage(),
      );
    }
    final scheme = ColorScheme.fromSeed(
      seedColor: _accent,
      brightness: Brightness.dark,
      surface: const Color(0xff14151a),
    );
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'PenBridge',
      theme: ThemeData(
        colorScheme: scheme,
        scaffoldBackgroundColor: const Color(0xff0b0c10),
        fontFamily: Platform.isMacOS ? '.AppleSystemUIFont' : null,
        useMaterial3: true,
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
      ),
      home: const TabletSenderPage(),
    );
  }
}

class MacReceiverPage extends StatefulWidget {
  const MacReceiverPage({super.key});
  @override
  State<MacReceiverPage> createState() => _MacReceiverPageState();
}

class _MacReceiverPageState extends State<MacReceiverPage> {
  HttpServer? _server;
  WebSocket? _socket;
  Timer? _permissionTimer;
  Timer? _batchTimer;
  final BytesBuilder _inputBatch = BytesBuilder(copy: false);
  String _status = 'Başlatılıyor';
  String _usbStatus = 'Type-C tüneli kapalı';
  BridgeMode _mode = BridgeMode.pen;
  double _displayAspectRatio = 16 / 10;
  int _packets = 0;
  double _pressure = 0;
  bool _accessibility = false;

  bool get _connected => _socket != null && _status == 'S Pen bağlı';

  @override
  void initState() {
    super.initState();
    unawaited(_startServer());
    unawaited(_checkPermission());
    unawaited(_loadDisplayAspectRatio());
    _permissionTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => unawaited(_checkPermission()),
    );
  }

  Future<void> _startServer() async {
    try {
      _server = await HttpServer.bind(InternetAddress.loopbackIPv4, _port);
      if (mounted) setState(() => _status = 'Tablet bekleniyor');
      await for (final request in _server!) {
        if (!WebSocketTransformer.isUpgradeRequest(request)) {
          await request.response.close();
          continue;
        }
        final socket = await WebSocketTransformer.upgrade(request);
        _socket = socket;
        if (mounted) setState(() => _status = 'S Pen bağlı');
        socket.listen(
          _receive,
          onDone: () {
            _socket = null;
            if (mounted) setState(() => _status = 'Tablet bekleniyor');
          },
          onError: (_) {
            _socket = null;
            if (mounted) setState(() => _status = 'Bağlantı hatası');
          },
        );
        _sendMode();
      }
    } catch (error) {
      if (mounted) setState(() => _status = 'Port hatası');
    }
  }

  void _receive(dynamic raw) {
    if (raw is List<int>) {
      final packet = raw is Uint8List ? raw : Uint8List.fromList(raw);
      if (packet.lengthInBytes != 40) return;
      final view = ByteData.sublistView(packet);
      _packets++;
      _mode =
          BridgeMode.values[packet[1].clamp(0, BridgeMode.values.length - 1)];
      _pressure = view.getFloat32(20, Endian.little);
      _inputBatch.add(packet);
      _batchTimer ??= Timer(const Duration(milliseconds: 4), _flushInputBatch);
      if (_packets % 8 == 0 && mounted) setState(() {});
      return;
    }
    if (raw is! String) return;
    try {
      final packet = jsonDecode(raw) as Map<String, dynamic>;
      if (packet['type'] == 'mode') {
        final incoming = BridgeMode.from(packet['mode'] as String?);
        if (incoming != _mode && mounted) setState(() => _mode = incoming);
        return;
      }
      _packets++;
      _pressure = (packet['pressure'] as num?)?.toDouble() ?? 0;
      final incoming = BridgeMode.from(packet['mode'] as String?);
      if (incoming != _mode) _mode = incoming;
      unawaited(_channel.invokeMethod<void>('injectInput', packet));
      if (_packets % 4 == 0 && mounted) setState(() {});
    } catch (_) {}
  }

  void _flushInputBatch() {
    _batchTimer = null;
    if (_inputBatch.length == 0) return;
    final bytes = _inputBatch.takeBytes();
    unawaited(_channel.invokeMethod<void>('injectBatch', bytes));
  }

  void _selectMode(BridgeMode mode) {
    setState(() => _mode = mode);
    _sendMode();
  }

  void _sendMode() => _socket?.add(
    jsonEncode({
      'type': 'mode',
      'mode': _mode.id,
      'aspectRatio': _displayAspectRatio,
    }),
  );

  Future<void> _loadDisplayAspectRatio() async {
    try {
      final ratio = await _channel.invokeMethod<double>('displayAspectRatio');
      if (ratio != null && ratio > 0) {
        _displayAspectRatio = ratio;
        _sendMode();
      }
    } on PlatformException {
      // Keep the safe 16:10 fallback if the native display is not ready yet.
    }
  }

  Future<void> _prepareUsb() async {
    setState(() => _usbStatus = 'Tablet aranıyor…');
    final home = Platform.environment['HOME'];
    final candidates = <String>[
      if (home != null) '$home/Library/Android/sdk/platform-tools/adb',
      '/opt/homebrew/bin/adb',
      'adb',
    ];
    for (final adb in candidates) {
      try {
        final devices = await Process.run(adb, const ['devices']);
        if (devices.exitCode != 0 ||
            !devices.stdout.toString().contains('\tdevice')) {
          continue;
        }
        final result = await Process.run(adb, const [
          'reverse',
          'tcp:49321',
          'tcp:49321',
        ]);
        if (result.exitCode == 0) {
          if (mounted) setState(() => _usbStatus = 'USB hazır • $_port');
          return;
        }
      } catch (_) {}
    }
    if (mounted) setState(() => _usbStatus = 'Tablet bulunamadı');
  }

  Future<void> _checkPermission() async {
    try {
      final trusted =
          await _channel.invokeMethod<bool>('checkAccessibility') ?? false;
      if (mounted && trusted != _accessibility) {
        setState(() => _accessibility = trusted);
      }
    } on PlatformException {
      // The native window may still be attaching during application startup.
    }
  }

  Future<void> _requestPermission() async {
    await _channel.invokeMethod<bool>('requestAccessibility');
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await _checkPermission();
  }

  @override
  void dispose() {
    _permissionTimer?.cancel();
    _batchTimer?.cancel();
    _flushInputBatch();
    unawaited(_socket?.close());
    unawaited(_server?.close(force: true));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return mac.MacosWindow(
      titleBar: const mac.TitleBar(title: Text('PenBridge')),
      sidebar: mac.Sidebar(
        minWidth: 210,
        startWidth: 230,
        maxWidth: 300,
        builder: (context, scrollController) => mac.SidebarItems(
          currentIndex: _mode.index,
          scrollController: scrollController,
          itemSize: mac.SidebarItemSize.large,
          onChanged: (index) => _selectMode(BridgeMode.values[index]),
          items: [
            for (final item in BridgeMode.values)
              mac.SidebarItem(
                leading: Icon(item.icon, size: 16),
                label: Text(item.label),
              ),
          ],
        ),
        bottom: Padding(
          padding: const EdgeInsets.all(12),
          child: _StatusPill(active: _connected, label: _status),
        ),
      ),
      child: mac.MacosScaffold(
        backgroundColor: const Color(0xff17181d),
        toolBar: mac.ToolBar(
          title: Text('${_mode.label} modu'),
          titleWidth: 180,
          actions: [
            mac.ToolBarIconButton(
              label: 'USB bağlantısını hazırla',
              icon: const mac.MacosIcon(CupertinoIcons.link),
              showLabel: false,
              onPressed: _prepareUsb,
            ),
          ],
        ),
        children: [
          mac.ContentArea(
            builder: (context, scrollController) => Theme(
              data: ThemeData.dark(useMaterial3: true),
              child: Scaffold(
                body: Row(
                  children: [
                    const SizedBox.shrink(),
                    Expanded(
                      child: Container(
                        color: const Color(0xff17181d),
                        child: Column(
                          children: [
                            const SizedBox.shrink(),
                            Expanded(
                              child: SingleChildScrollView(
                                padding: const EdgeInsets.fromLTRB(
                                  32,
                                  22,
                                  32,
                                  32,
                                ),
                                child: ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    maxWidth: 1000,
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  '${_mode.label} modu',
                                                  style: Theme.of(
                                                    context,
                                                  ).textTheme.headlineMedium,
                                                ),
                                                const SizedBox(height: 6),
                                                Text(
                                                  _modeDescription(_mode),
                                                  style: const TextStyle(
                                                    color: Colors.white54,
                                                    fontSize: 15,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          _StatusPill(
                                            active: _connected,
                                            label: _status,
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 26),
                                      Row(
                                        children: [
                                          Expanded(
                                            child: _MacMetric(
                                              icon: Icons.speed_rounded,
                                              label: 'Paketler',
                                              value: '$_packets',
                                            ),
                                          ),
                                          const SizedBox(width: 12),
                                          Expanded(
                                            child: _PressureMetric(
                                              value: _pressure,
                                            ),
                                          ),
                                          const SizedBox(width: 12),
                                          Expanded(
                                            child: _MacMetric(
                                              icon: Icons.usb_rounded,
                                              label: 'Bağlantı',
                                              value: _usbStatus,
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 18),
                                      _MacCard(
                                        title: 'Hızlı kurulum',
                                        subtitle:
                                            'Tablet ve Mac arasındaki kablolu bağlantıyı hazırla.',
                                        child: Row(
                                          children: [
                                            Expanded(
                                              child: _SetupRow(
                                                number: '1',
                                                title: 'Type-C tüneli',
                                                detail: _usbStatus,
                                                button: mac.PushButton(
                                                  controlSize:
                                                      mac.ControlSize.large,
                                                  onPressed: _prepareUsb,
                                                  child: const Text('Hazırla'),
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 12),
                                            Expanded(
                                              child: _SetupRow(
                                                number: '2',
                                                title: 'Mac giriş izni',
                                                detail: _accessibility
                                                    ? 'İzin verildi'
                                                    : 'İzin gerekli',
                                                button: _accessibility
                                                    ? const Icon(
                                                        Icons
                                                            .check_circle_rounded,
                                                        color:
                                                            Colors.greenAccent,
                                                        size: 26,
                                                      )
                                                    : mac.PushButton(
                                                        controlSize: mac
                                                            .ControlSize
                                                            .large,
                                                        onPressed:
                                                            _requestPermission,
                                                        child: const Text(
                                                          'İzin ver',
                                                        ),
                                                      ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(height: 18),
                                      _ModeHelp(mode: _mode),
                                    ],
                                  ),
                                ),
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
          ),
        ],
      ),
    );
  }
}

class TabletSenderPage extends StatefulWidget {
  const TabletSenderPage({super.key});
  @override
  State<TabletSenderPage> createState() => _TabletSenderPageState();
}

class _TabletSenderPageState extends State<TabletSenderPage> {
  WebSocket? _socket;
  BridgeMode _mode = BridgeMode.pen;
  BlenderTool _tool = BlenderTool.draw;
  double _targetAspectRatio = 16 / 10;
  double _padScale = 0.88;
  String _status = 'Mac bekleniyor';
  _PenPoint? _pen;
  Offset? _previous;
  int _lastPaintMicros = 0;

  bool get _connected => _socket != null;

  Future<void> _connect() async {
    await _socket?.close();
    setState(() => _status = 'Mac aranıyor…');
    try {
      final socket = await WebSocket.connect('ws://127.0.0.1:$_port');
      _socket = socket;
      socket.listen(
        (raw) {
          if (raw is String) {
            final data = jsonDecode(raw) as Map<String, dynamic>;
            if (data['type'] == 'mode' && mounted) {
              setState(() {
                _mode = BridgeMode.from(data['mode'] as String?);
                final ratio = (data['aspectRatio'] as num?)?.toDouble();
                if (ratio != null && ratio > 0) _targetAspectRatio = ratio;
              });
            }
          }
        },
        onDone: () {
          _socket = null;
          if (mounted) setState(() => _status = 'Bağlantı kesildi');
        },
      );
      setState(() => _status = 'USB ile bağlı');
      _announceMode();
    } catch (_) {
      _socket = null;
      if (mounted) setState(() => _status = 'Mac bulunamadı');
    }
  }

  void _selectMode(BridgeMode mode) {
    setState(() {
      _mode = mode;
      _tool = BlenderTool.draw;
    });
    _announceMode();
  }

  void _announceMode() => _socket?.add(
    jsonEncode({
      'type': 'mode',
      'mode': _mode.id,
      'aspectRatio': _targetAspectRatio,
    }),
  );

  void _send(PointerEvent event, String action, Size size) {
    if (event.kind != PointerDeviceKind.stylus &&
        event.kind != PointerDeviceKind.invertedStylus) {
      return;
    }
    final position = event.localPosition;
    final prior = _previous ?? position;
    final width = math.max(size.width, 1);
    final height = math.max(size.height, 1);
    final range = event.pressureMax - event.pressureMin;
    final pressure = range <= 0
        ? 0.0
        : ((event.pressure - event.pressureMin) / range).clamp(0.0, 1.0);
    final point = _PenPoint(
      x: (position.dx / width).clamp(0.0, 1.0),
      y: (position.dy / height).clamp(0.0, 1.0),
      pressure: pressure,
      hovering: action == 'hover',
    );
    _pen = point;
    _previous = action == 'up' ? null : position;
    final micros = event.timeStamp.inMicroseconds;
    if (mounted && micros - _lastPaintMicros >= 16000) {
      _lastPaintMicros = micros;
      setState(() {});
    }
    _socket?.add(
      _encodePointer(
        mode: _mode,
        tool: _tool,
        action: action,
        x: point.x,
        y: point.y,
        dx: position.dx - prior.dx,
        dy: position.dy - prior.dy,
        pressure: pressure,
        tilt: event.tilt,
        orientation: event.orientation,
        buttons: event.buttons,
        inverted: event.kind == PointerDeviceKind.invertedStylus,
      ),
    );
  }

  @override
  void dispose() {
    unawaited(_socket?.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            children: [
              SizedBox(
                width: 230,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const _BrandMark(),
                        const SizedBox(width: 12),
                        Text(
                          'PenBridge',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ],
                    ),
                    const SizedBox(height: 28),
                    const Text('KONTROL MODU', style: _eyebrow),
                    const SizedBox(height: 10),
                    for (final mode in BridgeMode.values)
                      _TabletModeButton(
                        mode: mode,
                        selected: mode == _mode,
                        onTap: () => _selectMode(mode),
                      ),
                    const Spacer(),
                    _StatusPill(active: _connected, label: _status),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _connect,
                        icon: Icon(
                          _connected ? Icons.sync_rounded : Icons.cable_rounded,
                        ),
                        label: Text(
                          _connected ? 'Yeniden bağlan' : 'Mac’e bağlan',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  children: [
                    _PadControlBar(
                      scale: _padScale,
                      aspectRatio: _targetAspectRatio,
                      onChanged: (value) => setState(() => _padScale = value),
                    ),
                    const SizedBox(height: 12),
                    if (_mode == BridgeMode.blender) ...[
                      _BlenderToolbar(
                        tool: _tool,
                        onTool: (tool) => setState(() => _tool = tool),
                      ),
                      const SizedBox(height: 12),
                    ],
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final available = constraints.biggest;
                          var width = available.width * _padScale;
                          var height = width / _targetAspectRatio;
                          final maxHeight = available.height * _padScale;
                          if (height > maxHeight) {
                            height = maxHeight;
                            width = height * _targetAspectRatio;
                          }
                          final size = Size(width, height);
                          return Center(
                            child: SizedBox(
                              width: width,
                              height: height,
                              child: Listener(
                                behavior: HitTestBehavior.opaque,
                                onPointerHover: (e) => _send(e, 'hover', size),
                                onPointerDown: (e) => _send(e, 'down', size),
                                onPointerMove: (e) => _send(e, 'drag', size),
                                onPointerUp: (e) => _send(e, 'up', size),
                                onPointerCancel: (e) => _send(e, 'up', size),
                                child: CustomPaint(
                                  painter: _PadPainter(_pen, _mode),
                                  child: Center(
                                    child: IgnorePointer(
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            _mode.icon,
                                            size: 34,
                                            color: Colors.white24,
                                          ),
                                          const SizedBox(height: 10),
                                          Text(
                                            _padTitle(),
                                            style: Theme.of(
                                              context,
                                            ).textTheme.titleMedium,
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            _padHint(),
                                            style: const TextStyle(
                                              color: Colors.white38,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _padTitle() => _mode == BridgeMode.blender
      ? '${_tool.label} aracı'
      : '${_mode.label} yüzeyi';
  String _padHint() => switch (_mode) {
    BridgeMode.pen => 'Hover • basınç • eğim',
    BridgeMode.mouse => 'Dokunarak tıkla ve sürükle',
    BridgeMode.trackpad => 'Kalemi göreceli imleç olarak kullan',
    BridgeMode.blender => 'Üst araç çubuğundan 3D kontrolünü seç',
  };
}

class _MacCard extends StatelessWidget {
  const _MacCard({
    required this.title,
    required this.subtitle,
    required this.child,
  });
  final String title;
  final String subtitle;
  final Widget child;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: const Color(0xff202126),
      border: Border.all(color: Colors.white10),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(subtitle, style: const TextStyle(color: Colors.white54)),
        const SizedBox(height: 18),
        child,
      ],
    ),
  );
}

class _MacMetric extends StatelessWidget {
  const _MacMetric({
    required this.icon,
    required this.label,
    required this.value,
  });
  final IconData icon;
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => Container(
    height: 94,
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: const Color(0xff202126),
      border: Border.all(color: Colors.white10),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Row(
      children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: _accent.withValues(alpha: .14),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: const Color(0xffb6a8ff), size: 20),
        ),
        const SizedBox(width: 13),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(color: Colors.white38, fontSize: 11),
              ),
              const SizedBox(height: 4),
              Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _PressureMetric extends StatelessWidget {
  const _PressureMetric({required this.value});
  final double value;
  @override
  Widget build(BuildContext context) => _MacMetric(
    icon: Icons.water_drop_rounded,
    label: 'Basınç',
    value: '${(value * 100).round()}%',
  );
}

class _SetupRow extends StatelessWidget {
  const _SetupRow({
    required this.number,
    required this.title,
    required this.detail,
    required this.button,
  });
  final String number;
  final String title;
  final String detail;
  final Widget button;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: .12),
      borderRadius: BorderRadius.circular(11),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: Colors.white10,
              child: Text(number, style: const TextStyle(fontSize: 12)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  Text(
                    detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        button,
      ],
    ),
  );
}

class _ModeHelp extends StatelessWidget {
  const _ModeHelp({required this.mode});
  final BridgeMode mode;
  @override
  Widget build(BuildContext context) {
    final items = switch (mode) {
      BridgeMode.pen => [
        ('Kalem ucu', 'Sol tık + basınç'),
        ('Hover', 'İmleci hareket ettir'),
        ('Eğim', 'Fırça yönü'),
      ],
      BridgeMode.mouse => [
        ('Kalem ucu', 'Sol tık'),
        ('Sürükle', 'Sol tuş sürükleme'),
        ('Konum', 'Ekrana mutlak eşleme'),
      ],
      BridgeMode.trackpad => [
        ('Hareket', 'Göreceli imleç'),
        ('Dokun', 'Sol tık'),
        ('Sürükle', 'Seçimi taşı'),
      ],
      BridgeMode.blender => [
        ('Çiz', 'Tablet basıncı'),
        ('Döndür', 'Orta tuş'),
        ('Kaydır', 'Shift + orta tuş'),
        ('Zoom', 'Kaydırma tekeri'),
      ],
    };
    return _MacCard(
      title: '${mode.label} eşlemeleri',
      subtitle: mode.subtitle,
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          for (final item in items)
            Container(
              width: 190,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: .035),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.$1,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    item.$2,
                    style: const TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _PadControlBar extends StatelessWidget {
  const _PadControlBar({
    required this.scale,
    required this.aspectRatio,
    required this.onChanged,
  });
  final double scale;
  final double aspectRatio;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) => Container(
    height: 58,
    padding: const EdgeInsets.symmetric(horizontal: 15),
    decoration: BoxDecoration(
      color: const Color(0xff15161b),
      borderRadius: BorderRadius.circular(15),
      border: Border.all(color: Colors.white10),
    ),
    child: Row(
      children: [
        const Icon(Icons.aspect_ratio_rounded, size: 19, color: Colors.white54),
        const SizedBox(width: 9),
        Text(
          'Mac oranı  ${aspectRatio.toStringAsFixed(2)}:1',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        const Spacer(),
        const Icon(Icons.remove_rounded, size: 18, color: Colors.white38),
        SizedBox(
          width: 190,
          child: Slider(value: scale, min: .45, max: 1, onChanged: onChanged),
        ),
        const Icon(Icons.add_rounded, size: 18, color: Colors.white38),
        const SizedBox(width: 10),
        SizedBox(
          width: 38,
          child: Text(
            '${(scale * 100).round()}%',
            textAlign: TextAlign.end,
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ),
      ],
    ),
  );
}

class _TabletModeButton extends StatelessWidget {
  const _TabletModeButton({
    required this.mode,
    required this.selected,
    required this.onTap,
  });
  final BridgeMode mode;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 7),
    child: Material(
      color: selected
          ? _accent.withValues(alpha: .18)
          : const Color(0xff15161b),
      borderRadius: BorderRadius.circular(13),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(13),
        child: Padding(
          padding: const EdgeInsets.all(13),
          child: Row(
            children: [
              Icon(
                mode.icon,
                color: selected ? const Color(0xffb8aaff) : Colors.white54,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      mode.label,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    Text(
                      mode.subtitle,
                      style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _BlenderToolbar extends StatelessWidget {
  const _BlenderToolbar({required this.tool, required this.onTool});
  final BlenderTool tool;
  final ValueChanged<BlenderTool> onTool;
  @override
  Widget build(BuildContext context) => Container(
    height: 62,
    padding: const EdgeInsets.all(8),
    decoration: BoxDecoration(
      color: const Color(0xff15161b),
      borderRadius: BorderRadius.circular(15),
      border: Border.all(color: Colors.white10),
    ),
    child: Row(
      children: [
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 12),
          child: Text('BLENDER', style: _eyebrow),
        ),
        for (final item in BlenderTool.values)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: Material(
                color: item == tool ? _accent : Colors.transparent,
                borderRadius: BorderRadius.circular(10),
                child: InkWell(
                  onTap: () => onTool(item),
                  borderRadius: BorderRadius.circular(10),
                  child: Center(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(item.icon, size: 18),
                        const SizedBox(width: 7),
                        Text(item.label),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.active, required this.label});
  final bool active;
  final String label;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
    decoration: BoxDecoration(
      color: (active ? Colors.greenAccent : Colors.white).withValues(
        alpha: .08,
      ),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(
        color: (active ? Colors.greenAccent : Colors.white).withValues(
          alpha: .12,
        ),
      ),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: active ? Colors.greenAccent : Colors.white38,
          ),
        ),
        const SizedBox(width: 7),
        Text(label, style: const TextStyle(fontSize: 12)),
      ],
    ),
  );
}

class _BrandMark extends StatelessWidget {
  const _BrandMark();
  @override
  Widget build(BuildContext context) => Container(
    width: 38,
    height: 38,
    decoration: BoxDecoration(
      gradient: const LinearGradient(colors: [_accent, Color(0xffa38dff)]),
      borderRadius: BorderRadius.circular(11),
    ),
    child: const Icon(Icons.draw_rounded, color: Colors.white, size: 20),
  );
}

class _PenPoint {
  const _PenPoint({
    required this.x,
    required this.y,
    required this.pressure,
    required this.hovering,
  });
  final double x;
  final double y;
  final double pressure;
  final bool hovering;
}

class _PadPainter extends CustomPainter {
  _PadPainter(this.point, this.mode);
  final _PenPoint? point;
  final BridgeMode mode;
  @override
  void paint(Canvas canvas, Size size) {
    final rect = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(22),
    );
    canvas.drawRRect(rect, Paint()..color = const Color(0xff14151a));
    canvas.drawRRect(
      rect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = Colors.white.withValues(alpha: .09),
    );
    final grid = Paint()..color = Colors.white.withValues(alpha: .035);
    for (double x = 32; x < size.width; x += 42) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }
    for (double y = 32; y < size.height; y += 42) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    final current = point;
    if (current != null) {
      final center = Offset(current.x * size.width, current.y * size.height);
      final radius = current.hovering ? 8.0 : 9 + current.pressure * 25;
      canvas.drawCircle(
        center,
        radius,
        Paint()..color = _accent.withValues(alpha: .22),
      );
      canvas.drawCircle(center, 4, Paint()..color = const Color(0xffc3b8ff));
    }
  }

  @override
  bool shouldRepaint(covariant _PadPainter oldDelegate) =>
      oldDelegate.point != point || oldDelegate.mode != mode;
}

String _modeDescription(BridgeMode mode) => switch (mode) {
  BridgeMode.pen =>
    'S Pen’i basınç ve eğim destekli grafik tablet olarak kullan.',
  BridgeMode.mouse =>
    'Tablet yüzeyini Mac ekranına birebir eşlenmiş mouse olarak kullan.',
  BridgeMode.trackpad =>
    'Kalem hareketini konumdan bağımsız, hassas trackpad hareketine çevir.',
  BridgeMode.blender =>
    'Sculpt, Grease Pencil, orbit, pan ve zoom için hazır Blender profili.',
};

Uint8List _encodePointer({
  required BridgeMode mode,
  required BlenderTool tool,
  required String action,
  required double x,
  required double y,
  required double dx,
  required double dy,
  required double pressure,
  required double tilt,
  required double orientation,
  required int buttons,
  required bool inverted,
}) {
  final bytes = Uint8List(40);
  final data = ByteData.sublistView(bytes);
  bytes[0] = 1;
  bytes[1] = mode.index;
  bytes[2] = tool.index;
  bytes[3] = switch (action) {
    'down' => 1,
    'drag' => 2,
    'up' => 3,
    _ => 0,
  };
  data
    ..setFloat32(4, x, Endian.little)
    ..setFloat32(8, y, Endian.little)
    ..setFloat32(12, dx, Endian.little)
    ..setFloat32(16, dy, Endian.little)
    ..setFloat32(20, pressure, Endian.little)
    ..setFloat32(24, tilt, Endian.little)
    ..setFloat32(28, orientation, Endian.little)
    ..setInt32(32, buttons, Endian.little);
  bytes[36] = inverted ? 1 : 0;
  return bytes;
}

const _eyebrow = TextStyle(
  color: Colors.white38,
  fontSize: 10,
  fontWeight: FontWeight.w700,
  letterSpacing: 1.4,
);
