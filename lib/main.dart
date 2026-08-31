import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const _port = 49321;
const _channel = MethodChannel('io.penbridge/input');

void main() => runApp(const PenBridgeApp());

class PenBridgeApp extends StatelessWidget {
  const PenBridgeApp({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = ColorScheme.fromSeed(
      seedColor: const Color(0xff7c5cff),
      brightness: Brightness.dark,
      surface: const Color(0xff111218),
    );
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'PenBridge',
      theme: ThemeData(
        colorScheme: colors,
        scaffoldBackgroundColor: const Color(0xff090a0e),
        useMaterial3: true,
      ),
      home: Platform.isMacOS
          ? const MacReceiverPage()
          : const TabletSenderPage(),
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
  String _status = 'Alıcı başlatılıyor…';
  String _usbStatus = 'Type-C tüneli hazır değil';
  int _packets = 0;
  double _pressure = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_startServer());
  }

  Future<void> _startServer() async {
    try {
      _server = await HttpServer.bind(InternetAddress.loopbackIPv4, _port);
      if (mounted) setState(() => _status = 'Tablet bekleniyor');
      await for (final request in _server!) {
        if (!WebSocketTransformer.isUpgradeRequest(request)) {
          request.response
            ..statusCode = HttpStatus.upgradeRequired
            ..write('WebSocket gerekli')
            ..close();
          continue;
        }
        _socket = await WebSocketTransformer.upgrade(request);
        if (mounted) setState(() => _status = 'S Pen bağlı');
        _socket!.listen(
          _receive,
          onDone: () {
            if (mounted) {
              setState(() => _status = 'Tablet bağlantısı kesildi');
            }
          },
          onError: (_) {
            if (mounted) setState(() => _status = 'Bağlantı hatası');
          },
        );
      }
    } catch (error) {
      if (mounted) setState(() => _status = 'Port açılamadı: $error');
    }
  }

  void _receive(dynamic raw) {
    if (raw is! String) return;
    try {
      final packet = jsonDecode(raw) as Map<String, dynamic>;
      _packets++;
      _pressure = (packet['pressure'] as num?)?.toDouble() ?? 0;
      unawaited(_channel.invokeMethod<void>('injectStylus', packet));
      if (_packets % 4 == 0 && mounted) setState(() {});
    } catch (_) {
      // Ignore malformed packets without interrupting the live pen stream.
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
          if (mounted) {
            setState(() => _usbStatus = 'Type-C hazır • port $_port');
          }
          return;
        }
      } catch (_) {
        // Try the next common adb location.
      }
    }
    if (mounted) {
      setState(() => _usbStatus = 'Tablet bulunamadı • USB hata ayıklamayı aç');
    }
  }

  Future<void> _requestInputPermission() async {
    await _channel.invokeMethod<void>('requestAccessibility');
  }

  @override
  void dispose() {
    unawaited(_socket?.close());
    unawaited(_server?.close(force: true));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _Shell(
      eyebrow: 'MAC RECEIVER',
      title: 'S Pen’i Mac’e bağla.',
      subtitle:
          'Basınç, hover, eğim ve tuş verisini Type-C üzerinden uygulamalara aktar.',
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: _Metric(label: 'BAĞLANTI', value: _status),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _Metric(label: 'PAKET', value: '$_packets'),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _Metric(
                  label: 'BASINÇ',
                  value: '${(_pressure * 100).round()}%',
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  _usbStatus,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Tableti kabloyla bağla, USB hata ayıklamayı onayla ve iki adımı çalıştır.',
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _prepareUsb,
                        icon: const Icon(Icons.usb_rounded),
                        label: const Text('Type-C bağlantısını hazırla'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _requestInputPermission,
                        icon: const Icon(Icons.mouse_rounded),
                        label: const Text('Mac giriş iznini aç'),
                      ),
                    ),
                  ],
                ),
              ],
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
  String _status = 'Bağlanmaya hazır';
  _PenPoint? _pen;
  int _lastPaintMicros = 0;

  Future<void> _connect() async {
    await _socket?.close();
    setState(() => _status = 'Mac aranıyor…');
    try {
      final socket = await WebSocket.connect('ws://127.0.0.1:$_port');
      socket.done.whenComplete(() {
        if (mounted) {
          setState(() => _status = 'Bağlantı kesildi');
        }
      });
      setState(() {
        _socket = socket;
        _status = 'Type-C üzerinden bağlı';
      });
    } catch (_) {
      if (mounted) {
        setState(() => _status = 'Mac bulunamadı • önce tüneli hazırla');
      }
    }
  }

  void _send(PointerEvent event, String action, Size size) {
    if (event.kind != PointerDeviceKind.stylus &&
        event.kind != PointerDeviceKind.invertedStylus) {
      return;
    }
    final width = math.max(size.width, 1);
    final height = math.max(size.height, 1);
    final range = event.pressureMax - event.pressureMin;
    final pressure = range <= 0
        ? 0.0
        : ((event.pressure - event.pressureMin) / range).clamp(0.0, 1.0);
    final point = _PenPoint(
      x: (event.localPosition.dx / width).clamp(0.0, 1.0),
      y: (event.localPosition.dy / height).clamp(0.0, 1.0),
      pressure: pressure,
      hovering: action == 'hover',
    );
    _pen = point;
    final micros = event.timeStamp.inMicroseconds;
    if (mounted && micros - _lastPaintMicros >= 16000) {
      _lastPaintMicros = micros;
      setState(() {});
    }
    _socket?.add(
      jsonEncode({
        'action': action,
        'x': point.x,
        'y': point.y,
        'pressure': pressure,
        'tilt': event.tilt,
        'orientation': event.orientation,
        'buttons': event.buttons,
        'inverted': event.kind == PointerDeviceKind.invertedStylus,
        'time': micros,
      }),
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
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Row(
                children: [
                  const _Logo(),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'PenBridge',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        Text(_status),
                      ],
                    ),
                  ),
                  FilledButton.icon(
                    onPressed: _connect,
                    icon: const Icon(Icons.cable_rounded),
                    label: const Text('Bağlan'),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final size = constraints.biggest;
                    return Listener(
                      behavior: HitTestBehavior.opaque,
                      onPointerHover: (e) => _send(e, 'hover', size),
                      onPointerDown: (e) => _send(e, 'down', size),
                      onPointerMove: (e) => _send(e, 'drag', size),
                      onPointerUp: (e) => _send(e, 'up', size),
                      onPointerCancel: (e) => _send(e, 'up', size),
                      child: CustomPaint(
                        painter: _PadPainter(_pen),
                        child: const Center(
                          child: Text(
                            'S Pen alanı\nYaklaştır: hover • Dokun: çiz • Bastır: basınç',
                            textAlign: TextAlign.center,
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
      ),
    );
  }
}

class _Shell extends StatelessWidget {
  const _Shell({
    required this.eyebrow,
    required this.title,
    required this.subtitle,
    required this.child,
  });
  final String eyebrow;
  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 920),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _Logo(),
                const SizedBox(height: 40),
                Text(
                  eyebrow,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                    letterSpacing: 2,
                  ),
                ),
                const SizedBox(height: 10),
                Text(title, style: Theme.of(context).textTheme.displaySmall),
                const SizedBox(height: 10),
                Text(subtitle, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 32),
                child,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Logo extends StatelessWidget {
  const _Logo();
  @override
  Widget build(BuildContext context) => Container(
    width: 44,
    height: 44,
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.primary,
      borderRadius: BorderRadius.circular(13),
    ),
    child: const Icon(Icons.draw_rounded, color: Colors.white),
  );
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(24),
    decoration: BoxDecoration(
      color: const Color(0xff111218),
      border: Border.all(color: Colors.white10),
      borderRadius: BorderRadius.circular(20),
    ),
    child: child,
  );
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => _Panel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 11,
            letterSpacing: 1.4,
            color: Colors.white54,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.titleMedium,
        ),
      ],
    ),
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
  _PadPainter(this.point);
  final _PenPoint? point;

  @override
  void paint(Canvas canvas, Size size) {
    final background = Paint()..color = const Color(0xff111218);
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(24)),
      background,
    );
    final grid = Paint()..color = Colors.white.withValues(alpha: .045);
    for (double x = 0; x < size.width; x += 40) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }
    for (double y = 0; y < size.height; y += 40) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    final current = point;
    if (current != null) {
      final center = Offset(current.x * size.width, current.y * size.height);
      final radius = current.hovering ? 9.0 : 8 + current.pressure * 24;
      canvas.drawCircle(
        center,
        radius,
        Paint()..color = const Color(0xff7c5cff).withValues(alpha: .28),
      );
      canvas.drawCircle(center, 4, Paint()..color = const Color(0xffa996ff));
    }
  }

  @override
  bool shouldRepaint(covariant _PadPainter oldDelegate) =>
      oldDelegate.point != point;
}
