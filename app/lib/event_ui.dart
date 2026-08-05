/// Shared per-event-type presentation constants (icon, color, short label),
/// used by the live detection ticker (main.dart) so an event type always
/// looks the same everywhere.
library;

import 'package:flutter/material.dart';

import 'models.dart';

class EventUi {
  static const Map<String, IconData> typeIcon = {
    EventTypes.pothole: Icons.warning_amber_rounded,
    EventTypes.roughRoad: Icons.opacity_outlined,
    EventTypes.braking: Icons.front_hand,
    EventTypes.tap: Icons.touch_app_outlined,
    EventTypes.turn: Icons.turn_right,
    EventTypes.speedBump: Icons.speed,
    EventTypes.bump: Icons.adjust,
    EventTypes.concreteJoint: Icons.linear_scale,
    EventTypes.laneChange: Icons.merge,
  };

  static const Map<String, Color> typeColor = {
    EventTypes.pothole: Colors.redAccent,
    EventTypes.roughRoad: Colors.orangeAccent,
    EventTypes.braking: Colors.redAccent,
    EventTypes.tap: Colors.teal,
    EventTypes.turn: Colors.blueAccent,
    EventTypes.speedBump: Colors.orange,
    EventTypes.bump: Colors.deepOrangeAccent,
    EventTypes.concreteJoint: Colors.amber,
    EventTypes.laneChange: Colors.blueGrey,
  };

  static const Map<String, String> shortLabel = {
    EventTypes.pothole: 'Pothole',
    EventTypes.concreteJoint: 'Joint',
    EventTypes.speedBump: 'Speed Bump',
    EventTypes.bump: 'Bump',
    EventTypes.roughRoad: 'Rough Road',
    EventTypes.turn: 'Turn',
    EventTypes.laneChange: 'Lane Change',
    EventTypes.tap: 'Screen Taps',
    EventTypes.braking: 'Braking',
  };

  /// The single most-likely confusion per detector type (pothole ↔ joint,
  /// speed bump ↔ bump), surfaced first among the reclassify options.
  static const Map<String, String> quickAlternate = {
    EventTypes.pothole: EventTypes.concreteJoint,
    EventTypes.concreteJoint: EventTypes.pothole,
    EventTypes.speedBump: EventTypes.bump,
    EventTypes.bump: EventTypes.speedBump,
  };

  /// Road-surface ("bump family") event types.
  static const Set<String> roadSurfaceTypes = {
    EventTypes.pothole,
    EventTypes.bump,
    EventTypes.speedBump,
    EventTypes.concreteJoint,
    EventTypes.roughRoad,
  };

  static IconData icon(String type) => typeIcon[type] ?? Icons.info_outline;
  static Color color(String type) => typeColor[type] ?? Colors.blueAccent;
  static String label(String type) => shortLabel[type] ?? type;

  /// Ordered reclassification targets for a detected [type]: most-likely
  /// confusion first, then the other road-surface labels.
  static List<String> corrections(String type) {
    final alt = quickAlternate[type];
    return <String>{
      if (alt != null) alt,
      EventTypes.pothole,
      EventTypes.concreteJoint,
      EventTypes.speedBump,
      EventTypes.bump,
      EventTypes.roughRoad,
    }.where((t) => t != type).toList();
  }
}
