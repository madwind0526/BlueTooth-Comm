import 'dart:convert';
import 'dart:typed_data';

import 'package:mesh_comm/core/packet/mesh_packet.dart';
import 'package:mesh_comm/core/transport/transport_status.dart';
import 'package:mesh_comm/features/contacts/contact_model.dart';
import 'package:mesh_comm/features/identity/user_level.dart';

class TopologyNodeSummary {
  final Uint8List nodeId;
  final String? displayName;
  final MeshDeviceType deviceType;
  final UserLevel userLevel;
  final TransportKind transportKind;
  final bool isSaved;
  final int lastSeen;

  const TopologyNodeSummary({
    required this.nodeId,
    this.displayName,
    required this.deviceType,
    required this.userLevel,
    this.transportKind = TransportKind.bluetooth,
    required this.isSaved,
    required this.lastSeen,
  });

  factory TopologyNodeSummary.fromContact(Contact contact) {
    return TopologyNodeSummary(
      nodeId: contact.nodeId,
      displayName: contact.displayName,
      deviceType: contact.deviceType,
      userLevel: contact.userLevel,
      transportKind: TransportKind.bluetooth,
      isSaved: contact.isSaved,
      lastSeen: contact.lastSeen,
    );
  }

  factory TopologyNodeSummary.fromJson(Map<String, dynamic> json) {
    final nodeId = _hexToBytes(json['nodeId'] as String?);
    if (nodeId == null || nodeId.length != 16) {
      throw const FormatException('Invalid topology nodeId.');
    }
    return TopologyNodeSummary(
      nodeId: nodeId,
      displayName: _cleanText(json['displayName'] as String?),
      deviceType: MeshDeviceType.fromWire(json['deviceType'] as String?),
      userLevel: UserLevel.fromWire(json['userLevel'] as String?),
      transportKind: _transportKindFromWire(json['transportKind'] as String?),
      isSaved: json['isSaved'] == true,
      lastSeen: json['lastSeen'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
    'nodeId': _bytesToHex(nodeId),
    'displayName': displayName,
    'deviceType': deviceType.wireName,
    'userLevel': userLevel.wireName,
    'transportKind': transportKind.name,
    'isSaved': isSaved,
    'lastSeen': lastSeen,
  };
}

class TopologyRequest {
  final String requestId;
  final int requestedDepth;

  const TopologyRequest({
    required this.requestId,
    required this.requestedDepth,
  });

  factory TopologyRequest.fromPayload(Uint8List payload) {
    final decoded = jsonDecode(utf8.decode(payload));
    if (decoded is! Map<String, dynamic> ||
        decoded['protocolVersion'] != MeshPacket.currentProtocolVersion) {
      throw const FormatException('Invalid topology request.');
    }
    final requestId = _cleanText(decoded['requestId'] as String?);
    if (requestId == null || requestId.isEmpty) {
      throw const FormatException('Invalid topology request id.');
    }
    return TopologyRequest(
      requestId: requestId,
      requestedDepth: decoded['requestedDepth'] as int? ?? 1,
    );
  }

  Uint8List toPayload() {
    return Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'protocolVersion': MeshPacket.currentProtocolVersion,
          'requestId': requestId,
          'requestedDepth': requestedDepth,
        }),
      ),
    );
  }
}

class TopologyResponse {
  final String requestId;
  final TopologyNodeSummary responder;
  final List<TopologyNodeSummary> neighbors;
  final int timestamp;

  const TopologyResponse({
    required this.requestId,
    required this.responder,
    required this.neighbors,
    required this.timestamp,
  });

  factory TopologyResponse.fromPayload(Uint8List payload) {
    final decoded = jsonDecode(utf8.decode(payload));
    if (decoded is! Map<String, dynamic> ||
        decoded['protocolVersion'] != MeshPacket.currentProtocolVersion) {
      throw const FormatException('Invalid topology response.');
    }
    final requestId = _cleanText(decoded['requestId'] as String?);
    final responder = decoded['responder'];
    final neighbors = decoded['neighbors'];
    if (requestId == null ||
        responder is! Map<String, dynamic> ||
        neighbors is! List) {
      throw const FormatException('Invalid topology response fields.');
    }
    return TopologyResponse(
      requestId: requestId,
      responder: TopologyNodeSummary.fromJson(responder),
      neighbors: neighbors
          .whereType<Map<String, dynamic>>()
          .map(TopologyNodeSummary.fromJson)
          .toList(),
      timestamp: decoded['timestamp'] as int? ?? 0,
    );
  }

  Uint8List toPayload() {
    return Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'protocolVersion': MeshPacket.currentProtocolVersion,
          'requestId': requestId,
          'responder': responder.toJson(),
          'neighbors': neighbors.map((node) => node.toJson()).toList(),
          'timestamp': timestamp,
        }),
      ),
    );
  }
}

String _bytesToHex(Uint8List bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

Uint8List? _hexToBytes(String? hex) {
  if (hex == null || hex.length.isOdd) return null;
  final bytes = <int>[];
  for (var i = 0; i < hex.length; i += 2) {
    final value = int.tryParse(hex.substring(i, i + 2), radix: 16);
    if (value == null) return null;
    bytes.add(value);
  }
  return Uint8List.fromList(bytes);
}

String? _cleanText(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

TransportKind _transportKindFromWire(String? value) {
  for (final kind in TransportKind.values) {
    if (kind.name == value) return kind;
  }
  return TransportKind.bluetooth;
}
