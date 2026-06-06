import 'dart:math';
import 'package:flutter/material.dart';

class AudioWaveformWidget extends StatefulWidget {
  final Stream<double> volumeStream;
  final bool isActive;
  final Color? color;
  final int barCount;

  const AudioWaveformWidget({
    super.key,
    required this.volumeStream,
    required this.isActive,
    this.color,
    this.barCount = 20,
  });

  @override
  State<AudioWaveformWidget> createState() => _AudioWaveformWidgetState();
}

class _AudioWaveformWidgetState extends State<AudioWaveformWidget>
    with TickerProviderStateMixin {
  final List<double> _levels = [];
  late AnimationController _idleController;

  @override
  void initState() {
    super.initState();
    _levels.addAll(List.filled(widget.barCount, 0.0));
    _idleController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _idleController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? Theme.of(context).colorScheme.primary;
    return StreamBuilder<double>(
      stream: widget.volumeStream,
      builder: (context, snapshot) {
        final level = snapshot.data ?? 0.0;
        if (widget.isActive && level > 0) {
          _shiftAndAdd(level);
        }
        return AnimatedBuilder(
          animation: _idleController,
          builder: (context, _) {
            return SizedBox(
              height: 48,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: List.generate(widget.barCount, (i) {
                  double barHeight;
                  if (widget.isActive && level > 0.01) {
                    barHeight = (_levels[i] * 44).clamp(4.0, 44.0);
                  } else {
                    // Idle animation
                    final phase = (i / widget.barCount) * 2 * pi;
                    final idle = sin(_idleController.value * pi * 2 + phase);
                    barHeight = (idle.abs() * 12 + 4).clamp(4.0, 16.0);
                  }
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 80),
                    width: 3,
                    height: barHeight,
                    decoration: BoxDecoration(
                      color: widget.isActive
                          ? color.withValues(alpha: 0.7 + 0.3 * (_levels[i]))
                          : color.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  );
                }),
              ),
            );
          },
        );
      },
    );
  }

  void _shiftAndAdd(double level) {
    if (!mounted) return;
    _levels.add(level);
    if (_levels.length > widget.barCount) {
      _levels.removeAt(0);
    }
  }
}
