import 'package:flutter/material.dart';

class LatencyGraphWidget extends StatefulWidget {
  final Stream<int> latencyStream;
  final int maxSamples;

  const LatencyGraphWidget({
    super.key,
    required this.latencyStream,
    this.maxSamples = 30,
  });

  @override
  State<LatencyGraphWidget> createState() => _LatencyGraphWidgetState();
}

class _LatencyGraphWidgetState extends State<LatencyGraphWidget> {
  final List<int> _samples = [];

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<int>(
      stream: widget.latencyStream,
      builder: (context, snapshot) {
        if (snapshot.hasData) {
          _samples.add(snapshot.data!);
          if (_samples.length > widget.maxSamples) {
            _samples.removeAt(0);
          }
        }
        if (_samples.isEmpty) {
          return const SizedBox(
            height: 60,
            child: Center(
                child: Text('Waiting for data...',
                    style: TextStyle(color: Colors.grey, fontSize: 12))),
          );
        }
        final maxVal = _samples
            .reduce((a, b) => a > b ? a : b)
            .toDouble()
            .clamp(10.0, 500.0);
        final avgVal = _samples.reduce((a, b) => a + b) / _samples.length;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: 60,
              child: CustomPaint(
                painter: _LatencyPainter(
                  samples: List.from(_samples),
                  maxVal: maxVal,
                  lineColor: _colorForLatency(context, avgVal.round()),
                ),
                size: const Size(double.infinity, 60),
              ),
            ),
            const SizedBox(height: 2),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('avg: ${avgVal.round()}ms',
                    style: const TextStyle(fontSize: 10, color: Colors.grey)),
                Text('max: ${maxVal.round()}ms',
                    style: const TextStyle(fontSize: 10, color: Colors.grey)),
              ],
            ),
          ],
        );
      },
    );
  }

  Color _colorForLatency(BuildContext context, int ms) {
    if (ms < 50) return Colors.green;
    if (ms < 100) return Colors.orange;
    return Colors.red;
  }
}

class _LatencyPainter extends CustomPainter {
  final List<int> samples;
  final double maxVal;
  final Color lineColor;

  _LatencyPainter(
      {required this.samples, required this.maxVal, required this.lineColor});

  @override
  void paint(Canvas canvas, Size size) {
    if (samples.length < 2) return;
    final paint = Paint()
      ..color = lineColor
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final fillPaint = Paint()
      ..color = lineColor.withValues(alpha: 0.1)
      ..style = PaintingStyle.fill;

    final path = Path();
    final fillPath = Path();
    final stepX = size.width / (samples.length - 1);

    Offset firstPoint =
        Offset(0, size.height - (samples[0] / maxVal) * size.height);
    path.moveTo(firstPoint.dx, firstPoint.dy);
    fillPath.moveTo(0, size.height);
    fillPath.lineTo(firstPoint.dx, firstPoint.dy);

    for (int i = 1; i < samples.length; i++) {
      final x = i * stepX;
      final y = size.height - (samples[i] / maxVal) * size.height;
      path.lineTo(x, y);
      fillPath.lineTo(x, y);
    }

    fillPath.lineTo(size.width, size.height);
    fillPath.close();

    canvas.drawPath(fillPath, fillPaint);
    canvas.drawPath(path, paint);

    // Draw threshold line at 50ms
    if (maxVal > 50) {
      final threshY = size.height - (50 / maxVal) * size.height;
      canvas.drawLine(
        Offset(0, threshY),
        Offset(size.width, threshY),
        Paint()
          ..color = Colors.green.withValues(alpha: 0.3)
          ..strokeWidth = 1
          ..style = PaintingStyle.stroke,
      );
    }
  }

  @override
  bool shouldRepaint(_LatencyPainter old) => old.samples != samples;
}
