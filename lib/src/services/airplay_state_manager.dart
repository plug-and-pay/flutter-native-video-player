import 'dart:async';

/// Global singleton manager for AirPlay state across all video player instances.
///
/// Since AirPlay is a system-level feature (the entire app connects to an AirPlay
/// device, not individual players), this manager provides a centralized source of
/// truth for AirPlay state that can be shared across all video player controllers.
class AirPlayStateManager {
  AirPlayStateManager._internal();
  static final AirPlayStateManager _instance = AirPlayStateManager._internal();

  /// Gets the singleton instance of [AirPlayStateManager]
  static AirPlayStateManager get instance => _instance;

  // Stream controllers for AirPlay state
  final StreamController<bool> _isAirPlayAvailableController =
      StreamController<bool>.broadcast();
  final StreamController<bool> _isAirPlayConnectedController =
      StreamController<bool>.broadcast();
  final StreamController<bool> _isAirPlayConnectingController =
      StreamController<bool>.broadcast();
  final StreamController<String?> _airPlayDeviceNameController =
      StreamController<String?>.broadcast();

  // Current state values
  bool _isAirPlayAvailable = false;
  bool _isAirPlayConnected = false;
  bool _isAirPlayConnecting = false;
  String? _airPlayDeviceName;

  // Cache the last known device name to handle cases where iOS temporarily
  // reports null while the device is still connected
  String? _lastKnownDeviceName;

  /// Whether AirPlay is available on the device
  bool get isAirPlayAvailable => _isAirPlayAvailable;

  /// Whether the app is currently connected to an AirPlay device
  bool get isAirPlayConnected => _isAirPlayConnected;

  /// Whether the app is currently connecting to an AirPlay device
  bool get isAirPlayConnecting => _isAirPlayConnecting;

  /// The name of the currently connected AirPlay device, or null if not connected
  String? get airPlayDeviceName => _airPlayDeviceName;

  /// Stream of AirPlay availability changes
  ///
  /// New subscribers immediately receive the current availability state,
  /// then receive all future changes.
  Stream<bool> get isAirPlayAvailableStream async* {
    yield _isAirPlayAvailable; // Emit current value first
    yield* _isAirPlayAvailableController.stream; // Then stream all updates
  }

  /// Stream of AirPlay connection state changes
  ///
  /// New subscribers immediately receive the current connection state,
  /// then receive all future changes.
  Stream<bool> get isAirPlayConnectedStream async* {
    yield _isAirPlayConnected; // Emit current value first
    yield* _isAirPlayConnectedController.stream; // Then stream all updates
  }

  /// Stream of AirPlay connecting state changes
  ///
  /// New subscribers immediately receive the current connecting state,
  /// then receive all future changes.
  ///
  /// Emits true when connecting to an AirPlay device,
  /// false when connection completes or fails.
  Stream<bool> get isAirPlayConnectingStream async* {
    yield _isAirPlayConnecting; // Emit current value first
    yield* _isAirPlayConnectingController.stream; // Then stream all updates
  }

  /// Stream of AirPlay device name changes
  ///
  /// New subscribers immediately receive the current device name,
  /// then receive all future changes.
  ///
  /// Emits the device name when connected to an AirPlay device,
  /// or null when disconnected.
  Stream<String?> get airPlayDeviceNameStream async* {
    yield _airPlayDeviceName; // Emit current value first
    yield* _airPlayDeviceNameController.stream; // Then stream all updates
  }

  /// Updates the AirPlay availability state
  void updateAvailability(bool isAvailable) {
    if (_isAirPlayAvailable != isAvailable) {
      _isAirPlayAvailable = isAvailable;
      if (!_isAirPlayAvailableController.isClosed) {
        _isAirPlayAvailableController.add(isAvailable);
      }
    }
  }

  /// Updates the AirPlay connection state and device name
  void updateConnection(
    bool isConnected, {
    bool? isConnecting,
    String? deviceName,
  }) {
    final bool connectionChanged = _isAirPlayConnected != isConnected;
    final bool connectingChanged =
        isConnecting != null && _isAirPlayConnecting != isConnecting;

    // Smart device name handling:
    // - If we receive a device name, cache it and use it
    // - If we receive null but are connected, use the cached name
    // - Only clear the name when disconnected
    String? effectiveDeviceName;
    if (isConnected) {
      if (deviceName != null) {
        // We got a device name from iOS - cache it and use it
        _lastKnownDeviceName = deviceName;
        effectiveDeviceName = deviceName;
      } else if (_lastKnownDeviceName != null) {
        // iOS sent null but we have a cached name and are still connected
        // Use the cached name
        effectiveDeviceName = _lastKnownDeviceName;
      } else {
        // No device name and no cache - device name is unknown
        effectiveDeviceName = null;
      }
    } else {
      // Disconnected - clear everything
      effectiveDeviceName = null;
      _lastKnownDeviceName = null;
    }

    final bool deviceNameChanged = _airPlayDeviceName != effectiveDeviceName;

    if (connectionChanged) {
      _isAirPlayConnected = isConnected;
      if (!_isAirPlayConnectedController.isClosed) {
        _isAirPlayConnectedController.add(isConnected);
      }

      // When connected, automatically clear connecting state
      if (isConnected && _isAirPlayConnecting) {
        _isAirPlayConnecting = false;
        if (!_isAirPlayConnectingController.isClosed) {
          _isAirPlayConnectingController.add(false);
        }
      }
    }

    // Update connecting state if provided
    if (connectingChanged) {
      _isAirPlayConnecting = isConnecting!;
      if (!_isAirPlayConnectingController.isClosed) {
        _isAirPlayConnectingController.add(isConnecting);
      }
    }

    // Update device name
    if (deviceNameChanged) {
      _airPlayDeviceName = effectiveDeviceName;
      if (!_airPlayDeviceNameController.isClosed) {
        _airPlayDeviceNameController.add(_airPlayDeviceName);
      }
    }
  }

  /// Disposes all stream controllers
  ///
  /// Note: This should only be called when the app is shutting down,
  /// as this is a singleton instance.
  void dispose() {
    _isAirPlayAvailableController.close();
    _isAirPlayConnectedController.close();
    _isAirPlayConnectingController.close();
    _airPlayDeviceNameController.close();
  }
}
