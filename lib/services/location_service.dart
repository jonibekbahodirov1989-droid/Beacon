import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

import 'trip_service.dart';

enum MovementMode { unknown, stationary, walking, moving, driving }

class MovementStatus {
  const MovementStatus({
    this.mode = MovementMode.unknown,
    this.speedKmh = 0,
    this.updatedAt,
  });

  final MovementMode mode;
  final double speedKmh;
  final DateTime? updatedAt;

  bool get isKnown => mode != MovementMode.unknown;

  bool get isFresh =>
      updatedAt != null &&
      DateTime.now().difference(updatedAt!) <= const Duration(seconds: 30);

  String get label => switch (mode) {
        MovementMode.unknown => 'Detecting movement',
        MovementMode.stationary => 'Stopped',
        MovementMode.walking => 'Walking',
        MovementMode.moving => 'Moving',
        MovementMode.driving => 'Driving',
      };

  String get emoji => switch (mode) {
        MovementMode.unknown => '📍',
        MovementMode.stationary => '⏸️',
        MovementMode.walking => '🚶',
        MovementMode.moving => '🚴',
        MovementMode.driving => '🚗',
      };
}

class MovementDetector {
  final List<double> _recentSpeeds = [];
  MovementMode _mode = MovementMode.unknown;
  MovementMode _candidate = MovementMode.unknown;
  int _candidateSamples = 0;
  MovementStatus _status = const MovementStatus();

  MovementStatus get status => _status;

  MovementStatus addSpeed(double metersPerSecond, {DateTime? timestamp}) {
    if (!metersPerSecond.isFinite ||
        metersPerSecond < 0 ||
        metersPerSecond > TripService.maximumPlausibleSpeedMetersPerSecond) {
      return _status;
    }

    _recentSpeeds.add(metersPerSecond);
    if (_recentSpeeds.length > 3) _recentSpeeds.removeAt(0);
    final sortedSpeeds = [..._recentSpeeds]..sort();
    final smoothedMetersPerSecond = sortedSpeeds[sortedSpeeds.length ~/ 2];
    final speedKmh = smoothedMetersPerSecond * 3.6;
    final candidate = switch (speedKmh) {
      >= 18 => MovementMode.driving,
      >= 9 => MovementMode.moving,
      >= 1.5 => MovementMode.walking,
      _ => MovementMode.stationary,
    };

    if (candidate == _mode) {
      _candidate = candidate;
      _candidateSamples = 0;
    } else {
      if (_candidate == candidate) {
        _candidateSamples++;
      } else {
        _candidate = candidate;
        _candidateSamples = 1;
      }
      if (_candidateSamples >= 2) {
        _mode = candidate;
        _candidateSamples = 0;
      }
    }

    _status = MovementStatus(
      mode: _mode,
      speedKmh: speedKmh,
      updatedAt: timestamp ?? DateTime.now(),
    );
    return _status;
  }

  void reset() {
    _recentSpeeds.clear();
    _mode = MovementMode.unknown;
    _candidate = MovementMode.unknown;
    _candidateSamples = 0;
    _status = const MovementStatus();
  }
}

class LocationService {
  static const maximumAcceptedAccuracyMeters = 50.0;

  LocationService({GeolocatorPlatform? geolocator})
      : _geolocator = geolocator ?? GeolocatorPlatform.instance;

  final GeolocatorPlatform _geolocator;
  final MovementDetector _movementDetector = MovementDetector();
  final ValueNotifier<MovementStatus> movementStatus =
      ValueNotifier(const MovementStatus());
  final StreamController<Position> _positionController =
      StreamController<Position>.broadcast();
  StreamSubscription<Position>? _subscription;

  bool _trackingEnabled = false;
  Position? _lastKnownPosition;
  Position? _previousTrackedPosition;
  DateTime? _lastReceivedPositionAt;
  DateTime? _trackingStartedAt;
  DateTime? _trackingResumedAt;
  Duration _trackedDuration = Duration.zero;
  double _trackedDistanceMeters = 0;
  bool _nextPositionStartsSegment = true;
  final Set<int> _trackingSegmentStartIndices = <int>{};

  bool get trackingEnabled => _trackingEnabled;
  bool get hasActiveTrip => _trackingStartedAt != null;
  Position? get lastKnownPosition => _lastKnownPosition;
  DateTime? get trackingStartedAt => _trackingStartedAt;
  Duration get trackingDuration {
    final currentSegment = _trackingEnabled && _trackingResumedAt != null
        ? DateTime.now().difference(_trackingResumedAt!)
        : Duration.zero;
    return _trackedDuration + currentSegment;
  }

  double get trackedDistanceMeters => _trackedDistanceMeters;
  List<Position> get trackedPositions => List.unmodifiable(_trackedPositions);
  List<int> get trackingSegmentStartIndices =>
      List.unmodifiable(_trackingSegmentStartIndices);
  Stream<Position> get positionStream => _positionController.stream;
  final List<Position> _trackedPositions = <Position>[];

  Future<bool> startTracking() async {
    if (_trackingEnabled) return true;
    if (hasActiveTrip) return resumeTracking();
    if (!await _hasLocationPermission()) return false;

    _trackedPositions.clear();
    _trackingSegmentStartIndices.clear();
    _previousTrackedPosition = null;
    _lastReceivedPositionAt = null;
    _nextPositionStartsSegment = true;
    _trackedDistanceMeters = 0;
    _trackingStartedAt = DateTime.now();
    _trackedDuration = Duration.zero;
    _startPositionUpdates();
    return true;
  }

  Future<bool> resumeTracking() async {
    if (_trackingEnabled) return true;
    if (!hasActiveTrip) return startTracking();
    if (!await _hasLocationPermission()) return false;

    _startPositionUpdates();
    return true;
  }

  void _startPositionUpdates() {
    _trackingEnabled = true;
    _trackingResumedAt = DateTime.now();
    _subscription = _geolocator
        .getPositionStream(locationSettings: _trackingLocationSettings)
        .listen(_recordPosition);
    unawaited(_requestInitialPosition());
  }

  Future<void> _requestInitialPosition() async {
    try {
      final current = await _geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.bestForNavigation,
          timeLimit: Duration(seconds: 8),
        ),
      );
      _recordPosition(current, allowStale: false);
    } catch (_) {
      // The position stream can still provide a fix if this one-shot times out.
    }
  }

  LocationSettings get _trackingLocationSettings {
    if (defaultTargetPlatform == TargetPlatform.android) {
      return AndroidSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 3,
        intervalDuration: const Duration(seconds: 2),
      );
    }
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return AppleSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        activityType: ActivityType.fitness,
        distanceFilter: 3,
        allowBackgroundLocationUpdates: true,
        showBackgroundLocationIndicator: true,
      );
    }
    return const LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 3,
    );
  }

  Future<Position?> getCurrentPosition() async {
    if (!await _hasLocationPermission()) return null;
    try {
      final position = await _geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.bestForNavigation,
          timeLimit: Duration(seconds: 8),
        ),
      );
      return _isUsablePosition(position, allowStale: false) ? position : null;
    } catch (_) {
      return null;
    }
  }

  Future<bool> requestTrackingPermission({bool background = false}) =>
      _hasLocationPermission(background: background);

  Future<bool> _hasLocationPermission({bool background = false}) async {
    if (!await _geolocator.isLocationServiceEnabled()) return false;

    var permission = await _geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await _geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever ||
        permission == LocationPermission.unableToDetermine) {
      return false;
    }

    var handlerPermission = await Permission.locationWhenInUse.status;
    if (!handlerPermission.isGranted) {
      handlerPermission = await Permission.locationWhenInUse.request();
    }
    if (!handlerPermission.isGranted) return false;
    if (background && defaultTargetPlatform == TargetPlatform.iOS) {
      var alwaysPermission = await Permission.locationAlways.status;
      if (!alwaysPermission.isGranted) {
        alwaysPermission = await Permission.locationAlways.request();
      }
      return alwaysPermission.isGranted;
    }
    return true;
  }

  void _recordPosition(Position position, {bool allowStale = true}) {
    if (!_trackingEnabled ||
        !_isUsablePosition(position, allowStale: allowStale)) {
      return;
    }

    final previous = _previousTrackedPosition;
    final lastReceivedPositionAt = _lastReceivedPositionAt;
    if (lastReceivedPositionAt != null &&
        !position.timestamp.isAfter(lastReceivedPositionAt)) {
      return;
    }

    if (previous != null) {
      final gap = position.timestamp.difference(previous.timestamp);
      if (gap <= TripService.maximumContinuousSampleGap &&
          !TripService.isPlausibleMovement(previous, position)) {
        _lastReceivedPositionAt = position.timestamp;
        return;
      }
      if (gap <= TripService.maximumContinuousSampleGap &&
          !_nextPositionStartsSegment &&
          !TripService.isReliableDisplacement(previous, position)) {
        _lastReceivedPositionAt = position.timestamp;
        _lastKnownPosition = position;
        _positionController.add(position);
        return;
      }
    }

    final startsSegment = _nextPositionStartsSegment ||
        previous == null ||
        !TripService.samplesAreContinuous(previous, position);
    if (startsSegment) {
      _trackingSegmentStartIndices.add(_trackedPositions.length);
    } else {
      _trackedDistanceMeters += Geolocator.distanceBetween(
        previous.latitude,
        previous.longitude,
        position.latitude,
        position.longitude,
      );
    }
    _trackedPositions.add(position);
    _previousTrackedPosition = position;
    _lastReceivedPositionAt = position.timestamp;
    _nextPositionStartsSegment = false;
    _lastKnownPosition = position;
    movementStatus.value = _movementDetector.addSpeed(
      _measuredSpeed(previous, position, startsSegment),
      timestamp: position.timestamp,
    );
    _positionController.add(position);
  }

  double _measuredSpeed(
    Position? previous,
    Position current,
    bool startsSegment,
  ) {
    if (previous != null && !startsSegment) {
      final elapsedSeconds =
          current.timestamp.difference(previous.timestamp).inMilliseconds /
              Duration.millisecondsPerSecond;
      if (elapsedSeconds > 0) {
        return Geolocator.distanceBetween(
              previous.latitude,
              previous.longitude,
              current.latitude,
              current.longitude,
            ) /
            elapsedSeconds;
      }
    }
    return current.speed;
  }

  bool _isUsablePosition(Position position, {required bool allowStale}) {
    final age = DateTime.now().difference(position.timestamp);
    return position.latitude.isFinite &&
        position.latitude >= -90 &&
        position.latitude <= 90 &&
        position.longitude.isFinite &&
        position.longitude >= -180 &&
        position.longitude <= 180 &&
        position.accuracy.isFinite &&
        position.accuracy >= 0 &&
        position.accuracy <= maximumAcceptedAccuracyMeters &&
        (_trackingStartedAt == null ||
            !position.timestamp.isBefore(_trackingStartedAt!)) &&
        (allowStale || age <= const Duration(seconds: 20)) &&
        age >= const Duration(seconds: -5);
  }

  Future<void> pauseTracking() async {
    if (_trackingEnabled && _trackingResumedAt != null) {
      _trackedDuration += DateTime.now().difference(_trackingResumedAt!);
    }
    _trackingResumedAt = null;
    _trackingEnabled = false;
    _previousTrackedPosition = null;
    _nextPositionStartsSegment = true;
    _movementDetector.reset();
    movementStatus.value = _movementDetector.status;
    final subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();
  }

  Future<void> stopTracking() async {
    await pauseTracking();
    _trackedPositions.clear();
    _trackingSegmentStartIndices.clear();
    _previousTrackedPosition = null;
    _lastReceivedPositionAt = null;
    _nextPositionStartsSegment = true;
    _trackingStartedAt = null;
    _trackedDuration = Duration.zero;
    _trackedDistanceMeters = 0;
  }

  String get lastLocationLabel {
    if (_lastKnownPosition == null) {
      return 'Location unavailable';
    }

    return '${_lastKnownPosition!.latitude.toStringAsFixed(4)}, '
        '${_lastKnownPosition!.longitude.toStringAsFixed(4)}';
  }
}
