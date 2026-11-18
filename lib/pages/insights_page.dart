import 'package:flutter/material.dart';
import 'dart:math' as math;

import '../services/trip_service.dart';
import '../theme/beacon_theme.dart';
import '../widgets/beacon_widgets.dart';

class InsightsPage extends StatefulWidget {
  const InsightsPage({
    required this.tripService,
    this.safePlaceVisits = const [],
    this.activeSafePlaceVisit,
    this.trackingSessionActive = false,
    this.trackingStartedAt,
    this.liveDistanceMeters = 0,
    this.liveTrackingDuration = Duration.zero,
    super.key,
  });

  final TripService tripService;
  final List<SafePlaceVisit> safePlaceVisits;
  final SafePlaceVisit? activeSafePlaceVisit;
  final bool trackingSessionActive;
  final DateTime? trackingStartedAt;
  final double liveDistanceMeters;
  final Duration liveTrackingDuration;

  @override
  State<InsightsPage> createState() => _InsightsPageState();
}

class _InsightsPageState extends State<InsightsPage> {
  String _period = 'Week';

  DateTime _periodStart(DateTime now) {
    return switch (_period) {
      'Month' => DateTime(now.year, now.month),
      'Year' => DateTime(now.year),
      _ => _dateOnly(now).subtract(const Duration(days: 6)),
    };
  }

  DateTime _previousPeriodStart(DateTime now) {
    return switch (_period) {
      'Month' => DateTime(now.year, now.month - 1),
      'Year' => DateTime(now.year - 1),
      _ => _periodStart(now).subtract(const Duration(days: 7)),
    };
  }

  DateTime _periodEnd(DateTime now) {
    return switch (_period) {
      'Month' => DateTime(now.year, now.month + 1),
      'Year' => DateTime(now.year + 1),
      _ => _dateOnly(now).add(const Duration(days: 1)),
    };
  }

  List<TripEntry> _tripsBetween(DateTime start, DateTime end) =>
      widget.tripService.trips
          .where((trip) =>
              !trip.startedAt.isBefore(start) && trip.startedAt.isBefore(end))
          .toList();

  double _distanceOf(List<TripEntry> trips) => trips.fold<double>(
        0,
        (sum, trip) => sum + trip.distanceMeters,
      );

  int _safePlaceSecondsBetween(DateTime start, DateTime end) {
    return [
      ...widget.safePlaceVisits,
      if (widget.activeSafePlaceVisit case final active?) active,
    ].fold<int>(
      0,
      (total, visit) => total + visit.secondsOverlapping(start, end),
    );
  }

  Map<String, ({String name, int seconds})> _safePlaceSecondsByPlace(
    DateTime start,
    DateTime end,
  ) {
    final totals = <String, ({String name, int seconds})>{};
    for (final visit in [
      ...widget.safePlaceVisits,
      if (widget.activeSafePlaceVisit case final active?) active,
    ]) {
      final seconds = visit.secondsOverlapping(start, end);
      if (seconds == 0 && visit != widget.activeSafePlaceVisit) {
        continue;
      }
      final current = totals[visit.placeId];
      totals[visit.placeId] = (
        name: visit.placeName,
        seconds: (current?.seconds ?? 0) + seconds,
      );
    }
    return totals;
  }

  List<double> _chartValues(
    DateTime now, {
    required DateTime? liveStartedAt,
    required double liveDistanceMeters,
  }) {
    final start = _periodStart(now);
    final end = _periodEnd(now);
    final bucketCount = switch (_period) {
      'Month' => 5,
      'Year' => 12,
      _ => 7,
    };
    final periodDays = end.difference(start).inDays;
    return List.generate(bucketCount, (index) {
      final bucketStart = _period == 'Year'
          ? DateTime(start.year, index + 1)
          : start
              .add(Duration(days: (periodDays * index / bucketCount).floor()));
      final bucketEnd = _period == 'Year'
          ? DateTime(start.year, index + 2)
          : start.add(
              Duration(days: (periodDays * (index + 1) / bucketCount).floor()));
      final liveDistance = liveStartedAt != null &&
              !liveStartedAt.isBefore(bucketStart) &&
              liveStartedAt.isBefore(bucketEnd)
          ? liveDistanceMeters
          : 0.0;
      return _distanceOf(_tripsBetween(bucketStart, bucketEnd)) + liveDistance;
    });
  }

  List<String> _chartLabels(DateTime now) {
    return switch (_period) {
      'Month' => const ['1', '2', '3', '4', '5'],
      'Year' => const [
          'J',
          'F',
          'M',
          'A',
          'M',
          'J',
          'J',
          'A',
          'S',
          'O',
          'N',
          'D'
        ],
      _ => List.generate(7, (index) {
          final day = _dateOnly(now).subtract(Duration(days: 6 - index));
          return _weekdayShortName(day.weekday);
        }),
    };
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final currentStart = _periodStart(now);
    final currentEnd = _periodEnd(now);
    final currentTrips = _tripsBetween(currentStart, currentEnd);
    final previousTrips = _tripsBetween(
      _previousPeriodStart(now),
      currentStart,
    );
    final liveTripInPeriod = widget.trackingSessionActive &&
        widget.trackingStartedAt != null &&
        !widget.trackingStartedAt!.isBefore(currentStart) &&
        widget.trackingStartedAt!.isBefore(currentEnd);
    final livePeriodDistance =
        liveTripInPeriod ? widget.liveDistanceMeters : 0.0;
    final distanceMeters = _distanceOf(currentTrips) + livePeriodDistance;
    final tripCount = currentTrips.length + (liveTripInPeriod ? 1 : 0);
    final totalDistance = distanceMeters / 1000;
    final previousDistance = _distanceOf(previousTrips);
    final changePercent = previousDistance == 0
        ? null
        : ((distanceMeters - previousDistance) / previousDistance * 100)
            .round();
    final chartValues = _chartValues(
      now,
      liveStartedAt: liveTripInPeriod ? widget.trackingStartedAt : null,
      liveDistanceMeters: widget.liveDistanceMeters,
    );
    final chartLabels = _chartLabels(now);
    final tripMinutes = currentTrips.fold<double>(
          0,
          (sum, trip) => sum + trip.totalMinutes,
        ) +
        (liveTripInPeriod ? widget.liveTrackingDuration.inSeconds / 60 : 0);
    final averageSpeed =
        tripMinutes == 0 ? 0.0 : distanceMeters / 1000 / (tripMinutes / 60);
    final averageTripDistance =
        tripCount == 0 ? 0.0 : distanceMeters / tripCount / 1000;
    final busiestDay = _busiestDay(currentTrips);
    final todayStart = _dateOnly(now);
    final todayEnd = todayStart.add(const Duration(days: 1));
    final todaySafePlaceTotals = _safePlaceSecondsByPlace(todayStart, todayEnd)
        .values
        .toList()
      ..sort((first, second) => second.seconds.compareTo(first.seconds));
    final periodSafePlaceSeconds =
        _safePlaceSecondsBetween(currentStart, currentEnd);
    final periodSafePlaceTotals =
        _safePlaceSecondsByPlace(currentStart, currentEnd).values.toList()
          ..sort((first, second) => second.seconds.compareTo(first.seconds));
    final periodCategoryTotals = <SafePlaceCategory, int>{};
    for (final visit in [
      ...widget.safePlaceVisits,
      if (widget.activeSafePlaceVisit case final active?) active,
    ]) {
      final seconds = visit.secondsOverlapping(currentStart, currentEnd);
      if (seconds > 0) {
        periodCategoryTotals.update(
          visit.category,
          (total) => total + seconds,
          ifAbsent: () => seconds,
        );
      }
    }
    final maxCarSpeed = currentTrips.fold<double>(
      0,
      (maximum, trip) =>
          trip.maxCarSpeedKmh > maximum ? trip.maxCarSpeedKmh : maximum,
    );
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
      children: [
        Row(
          children: [
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'MOVEMENT ANALYTICS',
                    style: TextStyle(
                      color: BeaconColors.forest,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  SizedBox(height: 5),
                  Text(
                    'Your insights',
                    style: TextStyle(
                      color: BeaconColors.ink,
                      fontSize: 30,
                      height: 1.05,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: const Color(0xFFE6ECE4),
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Icon(
                Icons.insights_rounded,
                color: BeaconColors.forest,
                size: 22,
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        _PeriodSelector(
          selectedPeriod: _period,
          onPeriodChanged: (period) => setState(() => _period = period),
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.fromLTRB(18, 17, 18, 15),
          decoration: BoxDecoration(
            color: BeaconColors.ink,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${_period.toUpperCase()}LY DISTANCE',
                      style: const TextStyle(
                        color: Color(0xFFB8C7BD),
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  if (changePercent != null)
                    _ChangeBadge(changePercent: changePercent),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    totalDistance.toStringAsFixed(1),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 42,
                      height: 1,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Padding(
                    padding: EdgeInsets.only(bottom: 4),
                    child: Text(
                      'km',
                      style: TextStyle(
                        color: BeaconColors.lime,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '$tripCount ${tripCount == 1 ? 'trip' : 'trips'}',
                    style: const TextStyle(
                      color: Color(0xFFCFD9D2),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 13),
              _DistanceChart(values: chartValues, labels: chartLabels),
              const SizedBox(height: 10),
              Row(
                children: [
                  Icon(
                    changePercent == null
                        ? Icons.remove_circle_outline_rounded
                        : changePercent >= 0
                            ? Icons.trending_up_rounded
                            : Icons.trending_down_rounded,
                    size: 16,
                    color: changePercent == null
                        ? const Color(0xFFB8C7BD)
                        : changePercent >= 0
                            ? BeaconColors.lime
                            : BeaconColors.coral,
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      changePercent == null
                          ? 'No previous period data to compare yet'
                          : '${changePercent >= 0 ? '+' : ''}$changePercent% vs previous ${_period.toLowerCase()}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 23),
        const Row(
          children: [
            Expanded(
              child: Text(
                'Place time today',
                style: TextStyle(
                  color: BeaconColors.ink,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            Icon(Icons.place_rounded, color: BeaconColors.forest, size: 19),
          ],
        ),
        const SizedBox(height: 10),
        SurfacePanel(
          padding: 14,
          child: todaySafePlaceTotals.isEmpty
              ? const _InsightRow(
                  icon: Icons.home_outlined,
                  color: BeaconColors.forest,
                  title: 'No place-time yet',
                  detail:
                      'Time inside your saved areas will appear here while tracking is active.',
                )
              : Column(
                  children: [
                    for (var index = 0;
                        index < todaySafePlaceTotals.length;
                        index++) ...[
                      if (index > 0) const Divider(height: 18),
                      _InsightRow(
                        icon: Icons.place_rounded,
                        color: index == 0
                            ? BeaconColors.forest
                            : BeaconColors.blue,
                        title: todaySafePlaceTotals[index].name,
                        detail:
                            '${_formatStayDuration(todaySafePlaceTotals[index].seconds)} today',
                      ),
                    ],
                    const Divider(height: 18),
                    _InsightRow(
                      icon: Icons.schedule_rounded,
                      color: BeaconColors.coral,
                      title: 'Total time at places',
                      detail:
                          '${_formatStayDuration(todaySafePlaceTotals.fold<int>(0, (total, place) => total + place.seconds))} today',
                    ),
                  ],
                ),
        ),
        const SizedBox(height: 23),
        Row(
          children: [
            const Expanded(
              child: Text(
                'Period summary',
                style: TextStyle(
                  color: BeaconColors.ink,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            Text(
              '$tripCount ${tripCount == 1 ? 'trip' : 'trips'}',
              style: const TextStyle(
                color: BeaconColors.muted,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        SurfacePanel(
          padding: 14,
          child: Column(
            children: [
              _InsightRow(
                icon: Icons.route_rounded,
                color: BeaconColors.blue,
                title: totalDistance == 0
                    ? 'No movement recorded'
                    : 'Movement total',
                detail: totalDistance == 0
                    ? 'Start a tracked trip to build your first summary.'
                    : 'You covered ${totalDistance.toStringAsFixed(1)} km across $tripCount trip${tripCount == 1 ? '' : 's'} this ${_period.toLowerCase()}.',
              ),
              const Divider(height: 18, color: BeaconColors.line),
              _InsightRow(
                icon: Icons.local_fire_department_rounded,
                color: BeaconColors.coral,
                title: busiestDay == null
                    ? 'No active day yet'
                    : 'Most active day',
                detail: busiestDay == null
                    ? 'A day-by-day pattern will appear after trips are recorded.'
                    : '${_weekdayName(busiestDay.key.weekday)} · ${(busiestDay.value / 1000).toStringAsFixed(1)} km.',
              ),
              const Divider(height: 18, color: BeaconColors.line),
              _InsightRow(
                icon: Icons.speed_rounded,
                color: BeaconColors.forest,
                title: 'Average speed · highest car speed',
                detail: tripMinutes == 0
                    ? 'No timed trip data in this period yet.'
                    : '${averageSpeed.toStringAsFixed(1)} km/h average · ${maxCarSpeed.toStringAsFixed(1)} km/h max car speed.',
              ),
              const Divider(height: 18, color: BeaconColors.line),
              _InsightRow(
                icon: Icons.straighten_rounded,
                color: BeaconColors.blue,
                title: 'Average trip distance',
                detail: tripCount == 0
                    ? 'A per-trip average will appear after your first trip.'
                    : '${averageTripDistance.toStringAsFixed(2)} km per trip this ${_period.toLowerCase()}.',
              ),
              const Divider(height: 18, color: BeaconColors.line),
              _InsightRow(
                icon: Icons.home_work_outlined,
                color: BeaconColors.coral,
                title: 'Time at places',
                detail: periodSafePlaceSeconds == 0
                    ? 'No place visits recorded this ${_period.toLowerCase()} yet.'
                    : '${_formatStayDuration(periodSafePlaceSeconds)} at places this ${_period.toLowerCase()}${periodSafePlaceTotals.isEmpty ? '' : ' · longest: ${periodSafePlaceTotals.first.name}'}.',
              ),
            ],
          ),
        ),
        const SizedBox(height: 23),
        const Row(
          children: [
            Expanded(
              child: Text(
                'Where your time goes',
                style: TextStyle(
                  color: BeaconColors.ink,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            Icon(Icons.pie_chart_outline_rounded,
                color: BeaconColors.forest, size: 19),
          ],
        ),
        const SizedBox(height: 10),
        SurfacePanel(
          padding: 14,
          child: periodCategoryTotals.isEmpty
              ? const _InsightRow(
                  icon: Icons.place_outlined,
                  color: BeaconColors.forest,
                  title: 'No place-time data yet',
                  detail:
                      'Save a place and track visits to see your daily patterns.',
                )
              : _PlaceTimeBreakdown(values: periodCategoryTotals),
        ),
      ],
    );
  }
}

class _PlaceTimeBreakdown extends StatelessWidget {
  const _PlaceTimeBreakdown({required this.values});

  final Map<SafePlaceCategory, int> values;

  @override
  Widget build(BuildContext context) {
    final entries = values.entries.toList()
      ..sort((first, second) => second.value.compareTo(first.value));
    final total = entries.fold<int>(0, (sum, entry) => sum + entry.value);
    return Row(
      children: [
        SizedBox(
          width: 116,
          height: 116,
          child: Stack(
            alignment: Alignment.center,
            children: [
              CustomPaint(
                size: const Size.square(116),
                painter: _PlaceTimeDonutPainter(values: values),
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _formatStayDuration(total),
                    style: const TextStyle(
                      color: BeaconColors.ink,
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const Text(
                    'TOTAL',
                    style: TextStyle(
                      color: BeaconColors.muted,
                      fontSize: 8,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final entry in entries) ...[
                if (entry != entries.first) const SizedBox(height: 8),
                Row(
                  children: [
                    Container(
                      width: 9,
                      height: 9,
                      decoration: BoxDecoration(
                        color: _placeCategoryColor(entry.key),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        _placeCategoryName(entry.key),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: BeaconColors.ink,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Text(
                      _formatStayDuration(entry.value),
                      style: const TextStyle(
                        color: BeaconColors.muted,
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _PlaceTimeDonutPainter extends CustomPainter {
  const _PlaceTimeDonutPainter({required this.values});

  final Map<SafePlaceCategory, int> values;

  @override
  void paint(Canvas canvas, Size size) {
    final total = values.values.fold<int>(0, (sum, value) => sum + value);
    if (total <= 0) return;
    final rect = Offset.zero & size;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 15
      ..strokeCap = StrokeCap.butt;
    var startAngle = -math.pi / 2;
    for (final entry in values.entries) {
      final sweep = entry.value / total * math.pi * 2;
      paint.color = _placeCategoryColor(entry.key);
      canvas.drawArc(rect.deflate(8), startAngle, sweep, false, paint);
      startAngle += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant _PlaceTimeDonutPainter oldDelegate) =>
      oldDelegate.values != values;
}

Color _placeCategoryColor(SafePlaceCategory category) => switch (category) {
      SafePlaceCategory.home => BeaconColors.forest,
      SafePlaceCategory.school => BeaconColors.blue,
      SafePlaceCategory.work => BeaconColors.coral,
      SafePlaceCategory.other => const Color(0xFF8A6BC1),
      SafePlaceCategory.unknown => BeaconColors.muted,
    };

String _placeCategoryName(SafePlaceCategory category) => switch (category) {
      SafePlaceCategory.home => 'Home',
      SafePlaceCategory.school => 'School',
      SafePlaceCategory.work => 'Work',
      SafePlaceCategory.other => 'Other',
      SafePlaceCategory.unknown => 'Unknown stops',
    };

class _PeriodSelector extends StatelessWidget {
  const _PeriodSelector({
    required this.selectedPeriod,
    required this.onPeriodChanged,
  });

  final String selectedPeriod;
  final ValueChanged<String> onPeriodChanged;

  @override
  Widget build(BuildContext context) {
    const periods = <(String, IconData)>[
      ('Week', Icons.view_week_rounded),
      ('Month', Icons.calendar_month_rounded),
      ('Year', Icons.timeline_rounded),
    ];
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: BeaconColors.line),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          for (final (label, icon) in periods)
            Expanded(
              child: _PeriodButton(
                label: label,
                icon: icon,
                selected: selectedPeriod == label,
                onTap: () => onPeriodChanged(label),
              ),
            ),
        ],
      ),
    );
  }
}

class _PeriodButton extends StatelessWidget {
  const _PeriodButton({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final foreground = selected ? BeaconColors.ink : BeaconColors.muted;
    return Semantics(
      button: true,
      selected: selected,
      label: '$label view',
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(vertical: 9),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFFE6ECE4) : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 16, color: foreground),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: foreground,
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChangeBadge extends StatelessWidget {
  const _ChangeBadge({required this.changePercent});

  final int changePercent;

  @override
  Widget build(BuildContext context) {
    final positive = changePercent >= 0;
    final color = positive ? BeaconColors.lime : const Color(0xFFFFB0A3);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            positive ? Icons.north_east_rounded : Icons.south_east_rounded,
            size: 14,
            color: color,
          ),
          const SizedBox(width: 4),
          Text(
            '${positive ? '+' : ''}$changePercent%',
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _InsightRow extends StatelessWidget {
  const _InsightRow({
    required this.icon,
    required this.color,
    required this.title,
    required this.detail,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.13),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: color, size: 19),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text(
                detail,
                style: const TextStyle(
                  color: BeaconColors.muted,
                  fontSize: 12,
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DistanceChart extends StatelessWidget {
  const _DistanceChart({required this.values, required this.labels});

  final List<double> values;
  final List<String> labels;

  @override
  Widget build(BuildContext context) {
    final maximum = values.fold<double>(
      0,
      (maxValue, value) => value > maxValue ? value : maxValue,
    );
    return SizedBox(
      height: 116,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var index = 0; index < values.length; index++) ...[
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Expanded(
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 240),
                        height:
                            maximum == 0 ? 3 : 8 + values[index] / maximum * 64,
                        width: 18,
                        decoration: BoxDecoration(
                          color: _chartBarColor(index, values[index], maximum),
                          borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(5),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(labels[index],
                      style: const TextStyle(
                          color: Color(0xFFB8C7BD), fontSize: 9)),
                ],
              ),
            ),
            if (index < values.length - 1) const SizedBox(width: 4),
          ],
        ],
      ),
    );
  }
}

Color _chartBarColor(int index, double value, double maximum) {
  if (maximum == 0) return const Color(0xFF536B60);
  if (value == maximum) return BeaconColors.lime;
  return switch (index % 3) {
    0 => const Color(0xFF75B6C5),
    1 => const Color(0xFFE98F79),
    _ => const Color(0xFFA8B875),
  };
}

DateTime _dateOnly(DateTime value) =>
    DateTime(value.year, value.month, value.day);

MapEntry<DateTime, double>? _busiestDay(List<TripEntry> trips) {
  if (trips.isEmpty) return null;
  final totals = <DateTime, double>{};
  for (final trip in trips) {
    final day = _dateOnly(trip.startedAt);
    totals.update(
      day,
      (distance) => distance + trip.distanceMeters,
      ifAbsent: () => trip.distanceMeters,
    );
  }
  return totals.entries.reduce(
    (first, second) => first.value >= second.value ? first : second,
  );
}

String _weekdayName(int weekday) => const [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ][weekday - 1];

String _formatStayDuration(int seconds) {
  final duration = Duration(seconds: seconds);
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  if (hours > 0) return '${hours}h ${minutes}m';
  return '${duration.inMinutes}m';
}

String _weekdayShortName(int weekday) => const [
      'M',
      'T',
      'W',
      'T',
      'F',
      'S',
      'S',
    ][weekday - 1];
