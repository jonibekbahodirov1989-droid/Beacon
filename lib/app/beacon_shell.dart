import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../auth/auth_service.dart';
import '../pages/activity_page.dart';
import '../pages/chats_page.dart';
import '../pages/emergency_page.dart';
import '../pages/family_page.dart';
import '../pages/home_page.dart';
import '../pages/insights_page.dart';
import '../pages/map_page.dart';
import '../pages/notifications_page.dart';
import '../pages/profile_page.dart';
import '../pages/settings_page.dart';
import '../services/firestore_service.dart';
import '../services/location_service.dart';
import '../services/tracking_foreground_service.dart';
import '../services/trip_service.dart';
import '../theme/beacon_theme.dart';

class BeaconShell extends StatefulWidget {
  const BeaconShell({
    required this.user,
    required this.authService,
    required this.locationService,
    required this.tripService,
    required this.firestoreService,
    required this.themePreset,
    required this.onThemeChanged,
    super.key,
  });

  final AuthUser user;
  final AuthService authService;
  final LocationService locationService;
  final TripService tripService;
  final FirestoreService firestoreService;
  final BeaconThemePreset themePreset;
  final ValueChanged<BeaconThemePreset> onThemeChanged;

  @override
  State<BeaconShell> createState() => _BeaconShellState();
}

class _BeaconShellState extends State<BeaconShell> {
  int _selectedIndex = 0;
  bool _trackingEnabled = false;
  bool _trackingSessionActive = false;
  TripEntry? _pendingTripSave;
  UserSettings _userSettings = const UserSettings();
  StreamSubscription<List<TripEntry>>? _tripSubscription;
  StreamSubscription<List<SafePlaceVisit>>? _safePlaceVisitSubscription;
  StreamSubscription<List<FamilyInvitation>>? _invitationSubscription;
  StreamSubscription<List<SafePlace>>? _safePlaceSubscription;
  StreamSubscription<Position>? _locationSubscription;
  StreamSubscription<String>? _messagingTokenSubscription;
  StreamSubscription<RemoteMessage>? _foregroundMessageSubscription;
  StreamSubscription<RemoteMessage>? _openedMessageSubscription;
  Timer? _trackingTimer;
  Timer? _automaticResumeTimer;
  DateTime? _lastFamilyLocationWrite;
  int _trackingSaveGeneration = 0;
  int _pendingInvitationCount = 0;
  List<FamilyInvitation> _pendingInvitations = const [];
  List<SafePlace> _safePlaces = const [];
  List<SafePlaceVisit> _safePlaceVisits = const [];
  String? _activeSafePlaceId;
  String? _activeSafePlaceName;
  DateTime? _activeSafePlaceStartedAt;
  double _activeSafePlaceSeconds = 0;
  SafePlaceCategory _activeSafePlaceCategory = SafePlaceCategory.other;
  double? _activeSafePlaceLatitude;
  double? _activeSafePlaceLongitude;
  double? _activeSafePlaceRadiusMeters;
  DateTime? _unknownCandidateStartedAt;
  double? _unknownCandidateLatitude;
  double? _unknownCandidateLongitude;
  double _unknownCandidateSeconds = 0;
  final Map<String, int> _tripSafePlaceSeconds = {};
  Position? _previousSafePlacePosition;
  String? _messagingToken;
  bool _configuringMessaging = false;
  DateTime? _lastTrackingNotificationUpdate;
  DateTime? _automaticTripDate;
  bool _automaticRolloverInProgress = false;
  bool _automaticResumeInProgress = false;

  @override
  void initState() {
    super.initState();
    _trackingEnabled = widget.locationService.trackingEnabled;
    _trackingSessionActive = widget.locationService.hasActiveTrip;
    FlutterForegroundTask.addTaskDataCallback(_onForegroundTaskData);
    _loadUserData();
    _watchTrips();
    _watchSafePlaceVisits();
    _watchIncomingInvitations();
    _watchSafePlaces();
    _locationSubscription =
        widget.locationService.positionStream.listen((position) {
      _updateSafePlaceVisit(position);
      if (_userSettings.familySharing) {
        _shareFamilyLocation(position);
      }
      if (mounted) setState(() {});
    });
    if (_trackingEnabled) _startTrackingClock();
  }

  void _onForegroundTaskData(Object data) {
    if (data is! Map || data['type'] != 'tracking_notification_action') return;

    switch (data['action']) {
      case trackingNotificationPauseAction:
        unawaited(_setTracking(false));
        break;
      case trackingNotificationEndAction:
        unawaited(_endTrip());
        break;
    }
  }

  Future<void> _loadUserData() async {
    final cachedThemeFuture = _loadCachedThemePreset();
    final settingsFuture =
        widget.firestoreService.fetchUserSettings(widget.user.uid);
    final cachedTheme = await cachedThemeFuture;
    if (!mounted) return;
    if (cachedTheme != null && cachedTheme != widget.themePreset) {
      widget.onThemeChanged(cachedTheme);
    }

    final settings = await settingsFuture;
    if (!mounted) return;
    setState(() {
      _userSettings = settings;
      _trackingEnabled = widget.locationService.trackingEnabled;
    });
    if (settings.themePreset != (cachedTheme ?? widget.themePreset)) {
      widget.onThemeChanged(settings.themePreset);
    }
    unawaited(_cacheThemePreset(settings.themePreset));
    unawaited(_configureMessaging(settings.notifications));
    if (settings.automaticTracking) {
      if (_trackingSessionActive) _automaticTripDate ??= DateTime.now();
      _automaticResumeTimer ??= Timer.periodic(
        const Duration(seconds: 20),
        (_) => unawaited(_checkAutomaticResume()),
      );
      unawaited(_checkAutomaticResume(allowImmediateStart: true));
    }
  }

  String get _themePreferenceKey => 'beacon.themePreset.${widget.user.uid}';

  Future<BeaconThemePreset?> _loadCachedThemePreset() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final savedName = preferences.getString(_themePreferenceKey);
      for (final preset in BeaconThemePreset.values) {
        if (preset.name == savedName) return preset;
      }
    } catch (error) {
      debugPrint('Could not load cached theme preference: $error');
    }
    return null;
  }

  Future<void> _cacheThemePreset(BeaconThemePreset preset) async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(_themePreferenceKey, preset.name);
    } catch (error) {
      debugPrint('Could not cache theme preference: $error');
    }
  }

  void _watchTrips() {
    var syncedInitialStats = false;
    _tripSubscription =
        widget.firestoreService.watchTrips(widget.user.uid).listen(
      (trips) {
        widget.tripService.replaceTrips(trips);
        if (!syncedInitialStats && trips.isNotEmpty) {
          syncedInitialStats = true;
          unawaited(widget.firestoreService
              .syncPublicActivityStats(widget.user.uid, trips));
        }
        if (mounted) setState(() {});
      },
      onError: (Object error) {
        widget.firestoreService.status.value = 'Trip updates unavailable';
      },
    );
  }

  void _watchIncomingInvitations() {
    _invitationSubscription = widget.firestoreService
        .watchIncomingFamilyInvitations(widget.user.uid)
        .listen((invitations) {
      if (!mounted) return;
      setState(() {
        _pendingInvitations = List.unmodifiable(invitations);
        _pendingInvitationCount = invitations.length;
      });
    });
  }

  void _watchSafePlaces() {
    _safePlaceSubscription =
        widget.firestoreService.watchSafePlaces(widget.user.uid).listen(
      (places) {
        if (_activeSafePlaceId != null &&
            !places.any((place) => place.id == _activeSafePlaceId)) {
          _finishSafePlaceVisit(
            _previousSafePlacePosition?.timestamp ?? DateTime.now(),
          );
        }
        _safePlaces = places;
        if (mounted) setState(() {});
      },
      onError: (Object error) =>
          debugPrint('Could not load safe places: $error'),
    );
  }

  void _watchSafePlaceVisits() {
    _safePlaceVisitSubscription =
        widget.firestoreService.watchSafePlaceVisits(widget.user.uid).listen(
      (visits) {
        _safePlaceVisits = visits;
        if (mounted) setState(() {});
      },
      onError: (Object error) {
        debugPrint('Could not load safe-place visit history: $error');
      },
    );
  }

  SafePlace? _safePlaceContaining(Position? position) {
    if (position == null) return null;
    for (final place in _safePlaces) {
      if (place.contains(position)) return place;
    }
    return null;
  }

  void _updateSafePlaceVisit(Position position) {
    if (!_trackingEnabled) return;
    final previous = _previousSafePlacePosition;
    final place = _safePlaceContaining(position);
    final continuous = previous != null &&
        TripService.samplesAreContinuous(previous, position);

    if (place != null) {
      _resetUnknownCandidate();
      if (_activeSafePlaceId != place.id || !continuous) {
        if (_activeSafePlaceId != null) {
          _finishSafePlaceVisit(previous?.timestamp ?? position.timestamp);
        }
        _startSafePlaceVisit(
          id: place.id,
          name: place.name,
          category: place.category,
          latitude: place.latitude,
          longitude: place.longitude,
          radiusMeters: place.radiusMeters,
          startedAt: position.timestamp,
        );
      } else {
        final elapsedSeconds =
            position.timestamp.difference(previous.timestamp).inSeconds;
        _activeSafePlaceSeconds += elapsedSeconds;
        _tripSafePlaceSeconds.update(
          place.id,
          (seconds) => seconds + elapsedSeconds,
          ifAbsent: () => elapsedSeconds,
        );
      }
      _previousSafePlacePosition = position;
      return;
    }

    if (_activeSafePlaceId != null &&
        (_activeSafePlaceCategory != SafePlaceCategory.unknown ||
            !continuous ||
            !_isInsideUnknownCandidate(position))) {
      _finishSafePlaceVisit(previous?.timestamp ?? position.timestamp);
    }

    if (_activeSafePlaceId == null) {
      if (!continuous || !_isInsideUnknownCandidate(position)) {
        _startUnknownCandidate(position);
      } else {
        final elapsedSeconds =
            position.timestamp.difference(previous.timestamp).inSeconds;
        _unknownCandidateSeconds += elapsedSeconds;
        if (_unknownCandidateSeconds >=
            TripService.unknownStopConfirmationDuration.inSeconds) {
          final startedAt = _unknownCandidateStartedAt!;
          final latitude = _unknownCandidateLatitude!;
          final longitude = _unknownCandidateLongitude!;
          final id = 'unknown-${startedAt.millisecondsSinceEpoch}';
          _startSafePlaceVisit(
            id: id,
            name: 'Unknown stop',
            category: SafePlaceCategory.unknown,
            latitude: latitude,
            longitude: longitude,
            radiusMeters: TripService.unknownStopRadiusMeters,
            startedAt: startedAt,
            durationSeconds: _unknownCandidateSeconds,
          );
          _tripSafePlaceSeconds[id] = _unknownCandidateSeconds.round();
        }
      }
    } else if (continuous) {
      final elapsedSeconds =
          position.timestamp.difference(previous.timestamp).inSeconds;
      _activeSafePlaceSeconds += elapsedSeconds;
      _tripSafePlaceSeconds.update(
        _activeSafePlaceId!,
        (seconds) => seconds + elapsedSeconds,
        ifAbsent: () => elapsedSeconds,
      );
    }

    _previousSafePlacePosition = position;
  }

  void _startSafePlaceVisit({
    required String id,
    required String name,
    required SafePlaceCategory category,
    required double latitude,
    required double longitude,
    required double radiusMeters,
    required DateTime startedAt,
    double durationSeconds = 0,
  }) {
    _activeSafePlaceId = id;
    _activeSafePlaceName = name;
    _activeSafePlaceCategory = category;
    _activeSafePlaceLatitude = latitude;
    _activeSafePlaceLongitude = longitude;
    _activeSafePlaceRadiusMeters = radiusMeters;
    _activeSafePlaceStartedAt = startedAt;
    _activeSafePlaceSeconds = durationSeconds;
  }

  void _startUnknownCandidate(Position position) {
    final center = TripService.roundedPlaceCenter(
      position.latitude,
      position.longitude,
    );
    _unknownCandidateStartedAt = position.timestamp;
    _unknownCandidateLatitude = center.latitude;
    _unknownCandidateLongitude = center.longitude;
    _unknownCandidateSeconds = 0;
  }

  bool _isInsideUnknownCandidate(Position position) {
    final latitude = _unknownCandidateLatitude ?? _activeSafePlaceLatitude;
    final longitude = _unknownCandidateLongitude ?? _activeSafePlaceLongitude;
    if (latitude == null || longitude == null) return false;
    return Geolocator.distanceBetween(
          latitude,
          longitude,
          position.latitude,
          position.longitude,
        ) <=
        TripService.unknownStopRadiusMeters;
  }

  void _resetUnknownCandidate() {
    _unknownCandidateStartedAt = null;
    _unknownCandidateLatitude = null;
    _unknownCandidateLongitude = null;
    _unknownCandidateSeconds = 0;
  }

  void _finishSafePlaceVisit(DateTime visitedAt) {
    final placeId = _activeSafePlaceId;
    final placeName = _activeSafePlaceName;
    final startedAt = _activeSafePlaceStartedAt;
    final visitSeconds = _activeSafePlaceSeconds.round();
    if (placeId != null &&
        placeName != null &&
        startedAt != null &&
        visitSeconds > 0 &&
        visitedAt.isAfter(startedAt)) {
      unawaited(_saveSafePlaceVisit(
        placeId: placeId,
        placeName: placeName,
        visitSeconds: visitSeconds,
        startedAt: startedAt,
        endedAt: visitedAt,
        category: _activeSafePlaceCategory,
        latitude: _activeSafePlaceLatitude,
        longitude: _activeSafePlaceLongitude,
        radiusMeters: _activeSafePlaceRadiusMeters,
      ));
    }
    _activeSafePlaceId = null;
    _activeSafePlaceName = null;
    _activeSafePlaceStartedAt = null;
    _activeSafePlaceSeconds = 0;
    _activeSafePlaceLatitude = null;
    _activeSafePlaceLongitude = null;
    _activeSafePlaceRadiusMeters = null;
    _activeSafePlaceCategory = SafePlaceCategory.other;
  }

  Future<void> _saveSafePlaceVisit({
    required String placeId,
    required String placeName,
    required int visitSeconds,
    required DateTime startedAt,
    required DateTime endedAt,
    required SafePlaceCategory category,
    required double? latitude,
    required double? longitude,
    required double? radiusMeters,
  }) async {
    try {
      await widget.firestoreService.recordSafePlaceVisit(
        userId: widget.user.uid,
        placeId: placeId,
        placeName: placeName,
        visitSeconds: visitSeconds,
        startedAt: startedAt,
        endedAt: endedAt,
        category: category,
        latitude: latitude,
        longitude: longitude,
        radiusMeters: radiusMeters,
      );
    } catch (error) {
      widget.firestoreService.status.value =
          'Safe-place visit could not be saved';
      debugPrint('Could not save safe-place visit: $error');
    }
  }

  Future<void> _configureMessaging(bool enabled) async {
    if (_configuringMessaging) return;
    _configuringMessaging = true;
    try {
      final messaging = FirebaseMessaging.instance;
      if (!enabled) {
        final token = _messagingToken ?? await messaging.getToken();
        if (token != null) {
          await widget.firestoreService.removeMessagingToken(
            userId: widget.user.uid,
            token: token,
          );
        }
        _messagingToken = null;
        await _messagingTokenSubscription?.cancel();
        await _foregroundMessageSubscription?.cancel();
        await _openedMessageSubscription?.cancel();
        _messagingTokenSubscription = null;
        _foregroundMessageSubscription = null;
        _openedMessageSubscription = null;
        return;
      }

      final permission = await messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );
      if (permission.authorizationStatus == AuthorizationStatus.denied) return;

      final token = await messaging.getToken();
      if (token != null) await _saveMessagingToken(token);
      _messagingTokenSubscription ??= messaging.onTokenRefresh.listen(
        (refreshedToken) => unawaited(_saveMessagingToken(refreshedToken)),
      );
      _foregroundMessageSubscription ??= FirebaseMessaging.onMessage.listen(
        _showForegroundInvitation,
      );
      _openedMessageSubscription ??=
          FirebaseMessaging.onMessageOpenedApp.listen(
        _openNotificationFromMessage,
      );

      final initialMessage = await messaging.getInitialMessage();
      if (initialMessage != null) _openNotificationFromMessage(initialMessage);
    } catch (error) {
      debugPrint('Could not configure push notifications: $error');
    } finally {
      _configuringMessaging = false;
    }
  }

  Future<void> _saveMessagingToken(String token) async {
    try {
      await widget.firestoreService.saveMessagingToken(
        userId: widget.user.uid,
        token: token,
      );
      _messagingToken = token;
    } catch (error) {
      debugPrint('Could not save push notification token: $error');
    }
  }

  void _showForegroundInvitation(RemoteMessage message) {
    if (message.data['type'] != 'family_invitation' || !mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(
          message.notification?.title ?? 'You have a new family request.',
        ),
        action: SnackBarAction(
          label: 'View',
          onPressed: _openNotifications,
        ),
      ),
    );
  }

  void _openNotificationFromMessage(RemoteMessage message) {
    if (message.data['type'] != 'family_invitation') return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _openNotifications();
    });
  }

  @override
  void dispose() {
    _trackingTimer?.cancel();
    _automaticResumeTimer?.cancel();
    FlutterForegroundTask.removeTaskDataCallback(_onForegroundTaskData);
    _finishSafePlaceVisit(
      _previousSafePlacePosition?.timestamp ?? DateTime.now(),
    );
    unawaited(_tripSubscription?.cancel());
    unawaited(_safePlaceVisitSubscription?.cancel());
    unawaited(_invitationSubscription?.cancel());
    unawaited(_safePlaceSubscription?.cancel());
    unawaited(_locationSubscription?.cancel());
    unawaited(_messagingTokenSubscription?.cancel());
    unawaited(_foregroundMessageSubscription?.cancel());
    unawaited(_openedMessageSubscription?.cancel());
    if (_userSettings.familySharing) {
      unawaited(widget.firestoreService.clearFamilyLocation(widget.user.uid));
    }
    super.dispose();
  }

  Future<void> _setTracking(
    bool enabled, {
    bool manualAction = true,
  }) async {
    final messenger = ScaffoldMessenger.maybeOf(context);

    if (enabled) {
      try {
        if (!await widget.locationService.requestTrackingPermission(
          background: _userSettings.automaticTracking,
        )) {
          if (mounted) {
            messenger?.showSnackBar(
              const SnackBar(
                content: Text(
                  'Enable location services and grant location permission to track movement.',
                ),
              ),
            );
          }
          return;
        }
        await TrackingForegroundService.start();
      } catch (error) {
        if (mounted) {
          messenger?.showSnackBar(SnackBar(content: Text(error.toString())));
        }
        return;
      }
      final isNewSession = !_trackingSessionActive;
      late final bool started;
      try {
        started = _trackingSessionActive
            ? await widget.locationService.resumeTracking()
            : await widget.locationService.startTracking();
      } catch (error) {
        await TrackingForegroundService.stop();
        if (mounted) {
          messenger?.showSnackBar(
            SnackBar(
                content: Text('Could not start location tracking: $error')),
          );
        }
        return;
      }
      if (!started && mounted) {
        await TrackingForegroundService.stop();
        messenger?.showSnackBar(
          const SnackBar(
              content:
                  Text('Location permission is required to track movement.')),
        );
        return;
      }
      if (isNewSession) _tripSafePlaceSeconds.clear();
      _pendingTripSave = null;
      _userSettings = _userSettings.copyWith(
        clearAutomaticTrackingResumeAt: true,
      );
      _trackingSessionActive = true;
      _startTrackingClock();
      _automaticTripDate ??= DateTime.now();
      _updateTrackingState(true, manualAction: manualAction);
      final generation = ++_trackingSaveGeneration;
      unawaited(_saveTrackingSettings(generation));
      return;
    }

    _trackingTimer?.cancel();
    _trackingTimer = null;
    _finishSafePlaceVisit(
      _previousSafePlacePosition?.timestamp ?? DateTime.now(),
    );
    _resetUnknownCandidate();
    final pauseFuture = widget.locationService.pauseTracking();
    _updateTrackingState(false, manualAction: manualAction);
    final generation = ++_trackingSaveGeneration;
    unawaited(_finishPausingTracking(
      pause: pauseFuture,
      clearSharedLocation: _userSettings.familySharing,
      generation: generation,
    ));
  }

  Future<void> _endTrip({bool automaticRollover = false}) async {
    if (!_trackingSessionActive) return;

    final messenger = ScaffoldMessenger.maybeOf(context);
    _trackingTimer?.cancel();
    _trackingTimer = null;
    final resumeAutomatically = !automaticRollover &&
        _userSettings.automaticTracking;
    if (resumeAutomatically) {
      _userSettings = _userSettings.copyWith(
        automaticTrackingResumeAt: _nextLocalMidnight(),
      );
    }
    _finishSafePlaceVisit(
      _previousSafePlacePosition?.timestamp ?? DateTime.now(),
    );
    _resetUnknownCandidate();
    final pauseFuture = widget.locationService.pauseTracking();
    _updateTrackingState(
      false,
      manualAction: !automaticRollover && !resumeAutomatically,
    );
    await pauseFuture;

    final positions = widget.locationService.trackedPositions;
    final lastPosition = positions.isEmpty ? null : positions.last;
    final savedTrip =
        _pendingTripSave ??= widget.tripService.recordTripFromPositions(
      positions,
      name: _safePlaceContaining(lastPosition)?.name,
      segmentStartIndices: widget.locationService.trackingSegmentStartIndices,
      addToHistory: false,
    );
    final generation = ++_trackingSaveGeneration;
    var saved = false;
    try {
      await TrackingForegroundService.update(text: 'Saving your trip…');
      await _finishStoppingTracking(
        savedTrip: savedTrip,
        clearSharedLocation: _userSettings.familySharing,
        generation: generation,
        messenger: messenger,
      );
      if (savedTrip != null) widget.tripService.addTrip(savedTrip);
      _pendingTripSave = null;
      saved = true;
    } catch (error) {
      widget.firestoreService.status.value = 'Trip save failed: $error';
      if (mounted) {
        messenger?.showSnackBar(
          SnackBar(content: Text('Trip could not be saved: $error')),
        );
      }
      try {
        await TrackingForegroundService.update(
          text: 'Trip not saved · tap End trip to retry',
        );
      } catch (notificationError) {
        debugPrint(
          'Could not update failed trip notification: $notificationError',
        );
      }
    } finally {
      if (saved) {
        await widget.locationService.stopTracking();
        _trackingSessionActive = false;
        _tripSafePlaceSeconds.clear();
        _automaticTripDate = null;
        try {
          await TrackingForegroundService.stop();
        } catch (error) {
          widget.firestoreService.status.value =
              'Could not stop tracking notification: $error';
        }
      }
      if (mounted) setState(() {});
    }
    if (automaticRollover && mounted && _userSettings.automaticTracking) {
      _automaticTripDate = DateTime.now();
      await _setTracking(true, manualAction: false);
    }
  }

  void _updateTrackingState(bool enabled, {required bool manualAction}) {
    final nextSettings = _userSettings.copyWith(
      trackingEnabled: enabled,
      automaticTracking:
          manualAction && !enabled ? false : _userSettings.automaticTracking,
      clearAutomaticTrackingResumeAt: manualAction && !enabled,
    );
    _userSettings = nextSettings;
    if (!nextSettings.automaticTracking) {
      _automaticResumeTimer?.cancel();
      _automaticResumeTimer = null;
    }
    if (mounted) setState(() => _trackingEnabled = enabled);
  }

  Future<void> _setAutomaticTracking(bool enabled) async {
    final previousSettings = _userSettings;
    _userSettings = _userSettings.copyWith(
      automaticTracking: enabled,
      clearAutomaticTrackingResumeAt: true,
    );
    _automaticTripDate = enabled ? DateTime.now() : null;
    if (enabled) {
      _automaticResumeTimer ??= Timer.periodic(
        const Duration(seconds: 20),
        (_) => unawaited(_checkAutomaticResume()),
      );
    } else {
      _automaticResumeTimer?.cancel();
      _automaticResumeTimer = null;
    }
    if (mounted) setState(() {});

    await widget.firestoreService
        .saveUserSettings(widget.user.uid, _userSettings);

    if (!enabled || _trackingEnabled) return;
    _automaticResumeInProgress = true;
    try {
      await _setTracking(true, manualAction: false);
    } finally {
      _automaticResumeInProgress = false;
    }
    if (widget.locationService.trackingEnabled) return;

    _userSettings = previousSettings.copyWith(
      trackingEnabled: false,
      automaticTracking: false,
    );
    _automaticTripDate = null;
    _automaticResumeTimer?.cancel();
    _automaticResumeTimer = null;
    if (mounted) {
      setState(() {});
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(
          content: Text(
            'Automatic tracking could not be started. Check location permission.',
          ),
        ),
      );
    }

    await widget.firestoreService
        .saveUserSettings(widget.user.uid, _userSettings);
  }

  Future<void> _checkAutomaticResume({
    bool allowImmediateStart = false,
  }) async {
    if (_automaticResumeInProgress ||
        !_userSettings.automaticTracking ||
        _trackingEnabled ||
        _trackingSessionActive) {
      return;
    }
    final resumeAt = _userSettings.automaticTrackingResumeAt;
    if (resumeAt == null && !allowImmediateStart) return;
    if (resumeAt != null && resumeAt.isAfter(DateTime.now())) return;

    _automaticResumeInProgress = true;
    try {
      if (resumeAt != null) {
        _userSettings = _userSettings.copyWith(
          clearAutomaticTrackingResumeAt: true,
        );
        await widget.firestoreService
            .saveUserSettings(widget.user.uid, _userSettings);
      }
      _automaticTripDate = DateTime.now();
      await _setTracking(true, manualAction: false);
    } catch (error) {
      widget.firestoreService.status.value =
          'Automatic tracking could not resume: $error';
      debugPrint('Automatic tracking could not resume: $error');
    } finally {
      _automaticResumeInProgress = false;
    }
  }

  DateTime _nextLocalMidnight() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day + 1);
  }

  Future<void> _saveTrackingSettings(int generation) async {
    if (generation != _trackingSaveGeneration) return;
    await widget.firestoreService
        .saveUserSettings(widget.user.uid, _userSettings);
  }

  Future<void> _finishStoppingTracking({
    required TripEntry? savedTrip,
    required bool clearSharedLocation,
    required int generation,
    required ScaffoldMessengerState? messenger,
  }) async {
    if (savedTrip != null) {
      await widget.firestoreService.saveTrip(widget.user.uid, savedTrip);
      if (mounted && generation == _trackingSaveGeneration) {
        messenger?.showSnackBar(
          SnackBar(
            content: Text(
              'Trip saved: ${(savedTrip.distanceMeters / 1000).toStringAsFixed(2)} km',
            ),
          ),
        );
      }
    }
    if (clearSharedLocation && generation == _trackingSaveGeneration) {
      await widget.firestoreService.clearFamilyLocation(widget.user.uid);
    }
    await _saveTrackingSettings(generation);
    await TrackingForegroundService.stop();
  }

  Future<void> _finishPausingTracking({
    required Future<void> pause,
    required bool clearSharedLocation,
    required int generation,
  }) async {
    try {
      await pause;
      if (clearSharedLocation && generation == _trackingSaveGeneration) {
        await widget.firestoreService.clearFamilyLocation(widget.user.uid);
      }
      await _saveTrackingSettings(generation);
    } catch (error) {
      widget.firestoreService.status.value = 'Could not pause tracking: $error';
      debugPrint('Could not finish pausing tracking: $error');
    } finally {
      try {
        await TrackingForegroundService.stop();
      } catch (error) {
        widget.firestoreService.status.value =
            'Could not stop tracking notification: $error';
        debugPrint('Could not stop tracking notification: $error');
      }
    }
  }

  void _startTrackingClock() {
    _trackingTimer ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {});
      final now = DateTime.now();
      final tripDate = _automaticTripDate;
      if (_userSettings.automaticTracking &&
          _trackingEnabled &&
          tripDate != null &&
          !_isSameDay(now, tripDate) &&
          !_automaticRolloverInProgress) {
        _automaticRolloverInProgress = true;
        unawaited(_endTrip(automaticRollover: true).whenComplete(() {
          _automaticRolloverInProgress = false;
        }));
        return;
      }
      if (_lastTrackingNotificationUpdate == null ||
          now.difference(_lastTrackingNotificationUpdate!) >=
              const Duration(seconds: 5)) {
        _lastTrackingNotificationUpdate = now;
        unawaited(_updateTrackingNotification());
      }
    });
  }

  bool _isSameDay(DateTime first, DateTime second) =>
      first.year == second.year &&
      first.month == second.month &&
      first.day == second.day;

  Future<void> _updateTrackingNotification() async {
    final duration = widget.locationService.trackingDuration;
    final distanceMeters = widget.locationService.trackedDistanceMeters;
    final movement = widget.locationService.movementStatus.value;
    final speedLabel = movement.isKnown && movement.isFresh
        ? '${movement.emoji} ${movement.label} · ${movement.speedKmh.round()} km/h'
        : 'Speed unavailable';
    final location =
        _activeSafePlaceName ?? widget.locationService.lastLocationLabel;
    final text = '${_formatTrackingDistance(distanceMeters)} · '
        '${_formatTrackingDuration(duration)} · '
        '$speedLabel · $location';
    try {
      await TrackingForegroundService.update(text: text);
    } catch (error) {
      widget.firestoreService.status.value =
          'Tracking notification update failed: $error';
      debugPrint('Could not update tracking notification: $error');
    }
  }

  int get _activeSafePlaceVisitSeconds {
    final lastPosition = _previousSafePlacePosition;
    final trailingSeconds = _trackingEnabled && _activeSafePlaceId != null
        ? (DateTime.now()
                .difference(lastPosition?.timestamp ?? DateTime.now())
                .inSeconds)
            .clamp(0, 20)
        : 0;
    return _activeSafePlaceSeconds.round() + trailingSeconds;
  }

  int _safePlaceTripSeconds(String placeId) {
    final trailingSeconds = _trackingEnabled && _activeSafePlaceId == placeId
        ? (DateTime.now()
                .difference(
                    _previousSafePlacePosition?.timestamp ?? DateTime.now())
                .inSeconds)
            .clamp(0, 20)
        : 0;
    return (_tripSafePlaceSeconds[placeId] ?? 0) + trailingSeconds;
  }

  void _shareFamilyLocation(Position position) {
    final now = DateTime.now();
    if (_lastFamilyLocationWrite != null &&
        now.difference(_lastFamilyLocationWrite!) <
            const Duration(seconds: 30)) {
      return;
    }
    _lastFamilyLocationWrite = now;
    unawaited(_saveFamilyLocation(position));
  }

  Future<void> _saveFamilyLocation(Position position) async {
    try {
      await _writeFamilyLocation(position);
    } catch (error) {
      widget.firestoreService.status.value = 'Family location update failed';
      debugPrint('Could not share family location: $error');
    }
  }

  Future<void> _writeFamilyLocation(Position position) async {
    final precision = _userSettings.approximateLocation ? 2 : 6;
    await widget.firestoreService.updateFamilyLocation(
      userId: widget.user.uid,
      latitude: double.parse(position.latitude.toStringAsFixed(precision)),
      longitude: double.parse(position.longitude.toStringAsFixed(precision)),
    );
  }

  Future<void> _setFamilySharing(bool enabled) async {
    final previousSettings = _userSettings;
    final nextSettings = _userSettings.copyWith(
      familySharing: enabled,
    );
    _userSettings = nextSettings;
    try {
      if (enabled && _trackingEnabled) {
        final position = await widget.locationService.getCurrentPosition();
        if (position == null) {
          throw StateError('Allow location access to share with your circle.');
        }
        await _writeFamilyLocation(position);
        _lastFamilyLocationWrite = DateTime.now();
      } else if (!enabled) {
        await widget.firestoreService.clearFamilyLocation(widget.user.uid);
        _lastFamilyLocationWrite = null;
      }

      await widget.firestoreService
          .saveUserSettings(widget.user.uid, nextSettings);
      if (mounted) setState(() {});
    } catch (_) {
      _userSettings = previousSettings;
      rethrow;
    }
  }

  void _openProfile() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ProfilePage(
          user: widget.user,
          authService: widget.authService,
          themePreset: widget.themePreset,
          onOpenSettings: _openSettings,
        ),
      ),
    );
  }

  void _openSettings(BuildContext profileContext) {
    Navigator.of(profileContext).push(
      MaterialPageRoute<void>(
        builder: (_) => SettingsPage(
          trackingEnabled: _trackingEnabled,
          onTrackingChanged: _setTracking,
          onAutomaticTrackingChanged: (enabled) {
            unawaited(_setAutomaticTracking(enabled));
          },
          userEmail: widget.user.email,
          userSettings: _userSettings,
          themePreset: widget.themePreset,
          onUserSettingsChanged: (settings) async {
            final previous = _userSettings;
            _userSettings = settings;
            if (previous.themePreset != settings.themePreset) {
              widget.onThemeChanged(settings.themePreset);
              unawaited(_cacheThemePreset(settings.themePreset));
            }
            if (mounted) setState(() {});
            await widget.firestoreService
                .saveUserSettings(widget.user.uid, settings);
            if (previous.approximateLocation != settings.approximateLocation &&
                settings.familySharing &&
                _trackingEnabled) {
              final position =
                  await widget.locationService.getCurrentPosition();
              if (position != null) await _writeFamilyLocation(position);
            }
            if (previous.notifications != settings.notifications) {
              unawaited(_configureMessaging(settings.notifications));
            }
          },
          onLogout: _signOutFromSettings,
        ),
      ),
    );
  }

  Future<void> _signOutFromSettings() async {
    final token = _messagingToken;
    if (token != null) {
      try {
        await widget.firestoreService.removeMessagingToken(
          userId: widget.user.uid,
          token: token,
        );
      } catch (error) {
        debugPrint('Could not remove push notification token: $error');
      }
      _messagingToken = null;
    }
    await widget.authService.signOut();
    if (mounted) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  void _openNotifications() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => NotificationsPage(
          userId: widget.user.uid,
          currentUser: widget.user,
          firestoreService: widget.firestoreService,
          locationService: widget.locationService,
          themePreset: widget.themePreset,
          currentPlaceName:
              _trackingEnabled ? _activeSafePlaceName : null,
          currentPlaceDurationSeconds: _activeSafePlaceVisitSeconds,
          initialInvitations: _pendingInvitations,
        ),
      ),
    );
  }

  void _openChats() {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ChatsPage(
          currentUser: widget.user,
          firestoreService: widget.firestoreService,
        ),
      ),
    );
  }

  void _openEmergency() {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => EmergencyPage(
          user: widget.user,
          locationService: widget.locationService,
          firestoreService: widget.firestoreService,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = BeaconAppTheme.forPreset(widget.themePreset);
    final activeVisitSeconds = _activeSafePlaceVisitSeconds;
    final activeVisitStartedAt = _activeSafePlaceStartedAt;
    final activeSafePlaceId = _activeSafePlaceId;
    final activeSafePlaceName = _activeSafePlaceName;
    final currentSafePlaceVisit = activeSafePlaceId == null ||
            activeSafePlaceName == null ||
            activeVisitStartedAt == null
        ? null
        : SafePlaceVisit(
            id: 'active-$activeSafePlaceId',
            placeId: activeSafePlaceId,
            placeName: activeSafePlaceName,
            startedAt: activeVisitStartedAt,
            endedAt: activeVisitStartedAt.add(
              Duration(seconds: activeVisitSeconds),
            ),
            durationSeconds: activeVisitSeconds,
            category: _activeSafePlaceCategory,
            latitude: _activeSafePlaceLatitude,
            longitude: _activeSafePlaceLongitude,
            radiusMeters: _activeSafePlaceRadiusMeters,
          );
    final currentSafePlaceTripSeconds = activeSafePlaceId == null
        ? 0
        : _safePlaceTripSeconds(activeSafePlaceId);
    final pages = [
      HomePage(
        trackingEnabled: _trackingEnabled,
        onTrackingChanged: _setTracking,
        trackingSessionActive: _trackingSessionActive,
        userName: widget.user.displayName,
        onOpenChats: _openChats,
        onOpenProfile: _openProfile,
        onOpenNotifications: _openNotifications,
        onOpenEmergency: _openEmergency,
        pendingNotificationCount: _pendingInvitationCount,
        locationLabel: widget.locationService.lastLocationLabel,
        trips: widget.tripService.trips,
        liveTrackingDistanceMeters:
            widget.locationService.trackedDistanceMeters,
        trackingStartedAt: widget.locationService.trackingStartedAt,
        trackingDuration: widget.locationService.trackingDuration,
        onEndTrip: _endTrip,
        currentSafePlaceName: _trackingEnabled ? activeSafePlaceName : null,
        currentSafePlaceTripSeconds: currentSafePlaceTripSeconds,
        currentSafePlaceVisitSeconds: activeVisitSeconds,
        safePlaceVisits: _safePlaceVisits,
        activeSafePlaceVisit: currentSafePlaceVisit,
      ),
      InsightsPage(
        tripService: widget.tripService,
        safePlaceVisits: _safePlaceVisits,
        activeSafePlaceVisit: currentSafePlaceVisit,
        trackingSessionActive: _trackingSessionActive,
        trackingStartedAt: widget.locationService.trackingStartedAt,
        liveDistanceMeters: widget.locationService.trackedDistanceMeters,
        liveTrackingDuration: widget.locationService.trackingDuration,
      ),
      MapPage(
        active: _selectedIndex == 2,
        trackingEnabled: _trackingEnabled,
        userId: widget.user.uid,
        locationService: widget.locationService,
        firestoreService: widget.firestoreService,
        tripService: widget.tripService,
        safePlaces: _safePlaces,
        activePlaceVisit: currentSafePlaceVisit,
      ),
      FamilyPage(
        userId: widget.user.uid,
        currentUser: widget.user,
        firestoreService: widget.firestoreService,
        locationService: widget.locationService,
        familySharing: _userSettings.familySharing,
        activeSafePlaceId: _activeSafePlaceId,
        activeSafePlaceSeconds: activeVisitSeconds,
        onFamilySharingChanged: _setFamilySharing,
      ),
      ActivityPage(
        tripService: widget.tripService,
        safePlaceVisits: _safePlaceVisits,
      ),
    ];

    return Container(
      color: theme.backgroundColor,
      child: Stack(
        children: [
          Positioned.fill(
            child: Image(
              image: theme.backgroundImageProvider(),
              fit: BoxFit.cover,
              color: theme.backgroundColor.withValues(alpha: 0.12),
              colorBlendMode: BlendMode.srcOver,
              errorBuilder: (context, error, stackTrace) => const SizedBox(),
            ),
          ),
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: theme.backgroundColor.withValues(alpha: 0.45),
              ),
            ),
          ),
          Positioned.fill(
            child: Scaffold(
              backgroundColor: Colors.transparent,
              extendBody: _selectedIndex == 2,
              body: SafeArea(
                top: _selectedIndex != 2,
                bottom: _selectedIndex != 2,
                child: IndexedStack(index: _selectedIndex, children: pages),
              ),
              bottomNavigationBar: SafeArea(
                minimum: const EdgeInsets.fromLTRB(14, 0, 14, 10),
                child: Material(
                  color: theme.cardColor.withValues(alpha: 0.82),
                  elevation: 8,
                  borderRadius: BorderRadius.circular(30),
                  clipBehavior: Clip.antiAlias,
                  child: NavigationBar(
                    backgroundColor: theme.cardColor.withValues(alpha: 0.82),
                    selectedIndex: _selectedIndex,
                    indicatorColor: Colors.transparent,
                    onDestinationSelected: (index) =>
                        setState(() => _selectedIndex = index),
                    destinations: [
                      NavigationDestination(
                        icon: const Icon(Icons.near_me_outlined),
                        selectedIcon: _SelectedNavIcon(
                          icon: Icons.near_me,
                          color: theme.preset == BeaconThemePreset.active
                              ? BeaconColors.lime
                              : theme.accentColor,
                        ),
                        label: 'Today',
                      ),
                      NavigationDestination(
                        icon: const Icon(Icons.insights_outlined),
                        selectedIcon: _SelectedNavIcon(
                          icon: Icons.insights,
                          color: theme.preset == BeaconThemePreset.active
                              ? BeaconColors.lime
                              : theme.accentColor,
                        ),
                        label: 'Insights',
                      ),
                      NavigationDestination(
                        icon: const Icon(Icons.map_outlined),
                        selectedIcon: _SelectedNavIcon(
                          icon: Icons.map,
                          color: theme.preset == BeaconThemePreset.active
                              ? BeaconColors.lime
                              : theme.accentColor,
                        ),
                        label: 'Map',
                      ),
                      NavigationDestination(
                        icon: const Icon(Icons.family_restroom_outlined),
                        selectedIcon: _SelectedNavIcon(
                          icon: Icons.family_restroom,
                          color: theme.preset == BeaconThemePreset.active
                              ? BeaconColors.lime
                              : theme.accentColor,
                        ),
                        label: 'Family',
                      ),
                      NavigationDestination(
                        icon: const Icon(Icons.route_outlined),
                        selectedIcon: _SelectedNavIcon(
                          icon: Icons.route,
                          color: theme.preset == BeaconThemePreset.active
                              ? BeaconColors.lime
                              : theme.accentColor,
                        ),
                        label: 'History',
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SelectedNavIcon extends StatelessWidget {
  const _SelectedNavIcon({required this.icon, required this.color});

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Icon(
      icon,
      key: const ValueKey('selected-nav-icon'),
      size: 22,
      color: color,
    );
  }
}

String _formatTrackingDistance(double meters) => meters >= 1000
    ? '${(meters / 1000).toStringAsFixed(1)} km'
    : '${meters.round()} m';

String _formatTrackingDuration(Duration duration) {
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  if (hours > 0) return '${hours}h ${minutes}m';
  return '${duration.inMinutes} min';
}
