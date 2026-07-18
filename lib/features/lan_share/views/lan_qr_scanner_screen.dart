import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

class LanQrScannerScreen extends StatefulWidget {
  const LanQrScannerScreen({super.key});

  @override
  State<LanQrScannerScreen> createState() => _LanQrScannerScreenState();
}

class _LanQrScannerScreenState extends State<LanQrScannerScreen>
    with SingleTickerProviderStateMixin {
  final MobileScannerController _controller = MobileScannerController();
  late AnimationController _animationController;
  bool _hasResult = false;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _animationController.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          '扫码连接',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        centerTitle: true,
      ),
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: (capture) {
              if (_hasResult || !mounted) return;
              final List<Barcode> barcodes = capture.barcodes;
              for (final barcode in barcodes) {
                final raw = barcode.rawValue;
                if (raw != null && raw.isNotEmpty) {
                  _hasResult = true;
                  Navigator.pop(context, raw);
                  break;
                }
              }
            },
          ),
          // Animated scanner overlay mask
          AnimatedBuilder(
            animation: _animationController,
            builder: (context, child) {
              return CustomPaint(
                size: Size.infinite,
                painter: QrScannerOverlayPainter(
                  borderColor: Theme.of(context).colorScheme.primary,
                  scanProgress: _animationController.value,
                ),
              );
            },
          ),
          // Guidance Text and Flashlight
          Positioned(
            bottom: 80,
            left: 0,
            right: 0,
            child: Column(
              children: [
                Text(
                  '将网页快传二维码对准框内即可自动扫码',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.8),
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    shadows: const [
                      Shadow(
                        color: Colors.black45,
                        blurRadius: 4,
                        offset: Offset(0, 1),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                ValueListenableBuilder<MobileScannerState>(
                  valueListenable: _controller,
                  builder: (context, state, child) {
                    final isTorchOn = state.torchState == TorchState.on;
                    return IconButton(
                      style: IconButton.styleFrom(
                        backgroundColor: Colors.black.withValues(alpha: 0.5),
                        foregroundColor: isTorchOn
                            ? Colors.yellow
                            : Colors.white,
                        padding: const EdgeInsets.all(16),
                        side: BorderSide(
                          color: Colors.white.withValues(alpha: 0.2),
                          width: 1,
                        ),
                      ),
                      icon: Icon(
                        isTorchOn
                            ? Icons.flash_on_rounded
                            : Icons.flash_off_rounded,
                      ),
                      onPressed: () => _controller.toggleTorch(),
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
}

class QrScannerOverlayPainter extends CustomPainter {
  final Color borderColor;
  final double scanProgress; // 0.0 to 1.0 for the laser line progress

  QrScannerOverlayPainter({
    required this.borderColor,
    required this.scanProgress,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final width = size.width;
    final height = size.height;

    // Define the scanning box size (e.g. 250x250)
    const boxSize = 250.0;
    final left = (width - boxSize) / 2;
    final top = (height - boxSize) / 2;
    final right = left + boxSize;
    final bottom = top + boxSize;
    final rect = Rect.fromLTRB(left, top, right, bottom);

    // Draw the darkened semi-transparent background around the box
    final paintBg = Paint()..color = Colors.black.withValues(alpha: 0.6);

    // Path for whole screen minus the box
    final path = Path()
      ..addRect(Rect.fromLTWH(0, 0, width, height))
      ..addRRect(RRect.fromRectAndRadius(rect, const Radius.circular(16)))
      ..fillType = PathFillType.evenOdd;

    canvas.drawPath(path, paintBg);

    // Draw L-shaped corner marks
    final paintCorner = Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.0
      ..strokeCap = StrokeCap.round;

    const cornerLength = 20.0;
    const radius = 16.0;

    // Top-Left corner
    canvas.drawPath(
      Path()
        ..moveTo(left, top + cornerLength)
        ..lineTo(left, top + radius)
        ..arcToPoint(
          Offset(left + radius, top),
          radius: const Radius.circular(radius),
        )
        ..lineTo(left + cornerLength, top),
      paintCorner,
    );

    // Top-Right corner
    canvas.drawPath(
      Path()
        ..moveTo(right - cornerLength, top)
        ..lineTo(right - radius, top)
        ..arcToPoint(
          Offset(right, top + radius),
          radius: const Radius.circular(radius),
        )
        ..lineTo(right, top + cornerLength),
      paintCorner,
    );

    // Bottom-Left corner
    canvas.drawPath(
      Path()
        ..moveTo(left, bottom - cornerLength)
        ..lineTo(left, bottom - radius)
        ..arcToPoint(
          Offset(left + radius, bottom),
          radius: const Radius.circular(radius),
          clockwise: false,
        )
        ..lineTo(left + cornerLength, bottom),
      paintCorner,
    );

    // Bottom-Right corner
    canvas.drawPath(
      Path()
        ..moveTo(right - cornerLength, bottom)
        ..lineTo(right - radius, bottom)
        ..arcToPoint(
          Offset(right, bottom - radius),
          radius: const Radius.circular(radius),
          clockwise: false,
        )
        ..lineTo(right, bottom - cornerLength),
      paintCorner,
    );

    // Draw the scanning laser line
    final paintLaser = Paint()
      ..shader = LinearGradient(
        colors: [
          borderColor.withValues(alpha: 0.0),
          borderColor,
          borderColor.withValues(alpha: 0.0),
        ],
      ).createShader(Rect.fromLTRB(left, 0, right, 0))
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0;

    final laserY = top + (boxSize * scanProgress);
    canvas.drawLine(
      Offset(left + 8, laserY),
      Offset(right - 8, laserY),
      paintLaser,
    );
  }

  @override
  bool shouldRepaint(covariant QrScannerOverlayPainter oldDelegate) {
    return oldDelegate.scanProgress != scanProgress ||
        oldDelegate.borderColor != borderColor;
  }
}
