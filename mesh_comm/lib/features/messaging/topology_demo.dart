import 'dart:typed_data';

import 'package:mesh_comm/core/transport/transport_status.dart';
import 'package:mesh_comm/features/contacts/contact_model.dart';
import 'package:mesh_comm/features/identity/user_level.dart';

import 'topology_message.dart';

class DemoTopologyScenario {
  final List<Contact> directContacts;
  final List<TopologyResponse> responses;

  const DemoTopologyScenario({
    required this.directContacts,
    required this.responses,
  });

  factory DemoTopologyScenario.large() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final nodes = {
      'relayA': _node(0x11, 'Relay A', MeshDeviceType.phone, UserLevel.user),
      'relayB': _node(0x12, 'Relay B', MeshDeviceType.pc, UserLevel.admin),
      'relayC': _node(0x13, 'Relay C', MeshDeviceType.phone, UserLevel.server),
      'relayD': _node(0x14, 'Relay D', MeshDeviceType.phone, UserLevel.user),
      'alpha': _node(0x21, 'Alpha', MeshDeviceType.phone, UserLevel.user),
      'bravo': _node(0x22, 'Bravo', MeshDeviceType.phone, UserLevel.builder),
      'camp': _node(0x23, 'Camp PC', MeshDeviceType.pc, UserLevel.user),
      'dock': _node(0x24, 'Dock', MeshDeviceType.phone, UserLevel.user),
      'delta': _node(0x31, 'Delta', MeshDeviceType.phone, UserLevel.user),
      'echo': _node(0x32, 'Echo', MeshDeviceType.phone, UserLevel.server),
      'field': _node(0x33, 'Field PC', MeshDeviceType.pc, UserLevel.user),
      'gate': _node(0x34, 'Gate', MeshDeviceType.phone, UserLevel.creator),
      'harbor': _node(0x35, 'Harbor', MeshDeviceType.phone, UserLevel.user),
      'iris': _node(0x41, 'Iris', MeshDeviceType.phone, UserLevel.user),
      'junction': _node(0x42, 'Junction', MeshDeviceType.pc, UserLevel.admin),
      'kite': _node(0x43, 'Kite', MeshDeviceType.phone, UserLevel.user),
      'lime': _node(0x44, 'Lime', MeshDeviceType.phone, UserLevel.server),
      'mango': _node(0x45, 'Mango', MeshDeviceType.phone, UserLevel.user),
      'north': _node(0x51, 'North', MeshDeviceType.phone, UserLevel.user),
      'oak': _node(0x52, 'Oak PC', MeshDeviceType.pc, UserLevel.user),
      'pico': _node(0x53, 'Pico', MeshDeviceType.phone, UserLevel.user),
      'quartz': _node(0x54, 'Quartz', MeshDeviceType.phone, UserLevel.builder),
      'river': _node(0x61, 'River', MeshDeviceType.phone, UserLevel.user),
      'summit': _node(0x62, 'Summit', MeshDeviceType.phone, UserLevel.user),
      'tower': _node(0x63, 'Tower PC', MeshDeviceType.pc, UserLevel.server),
      'umbra': _node(0x71, 'Umbra', MeshDeviceType.phone, UserLevel.user),
      'valley': _node(0x72, 'Valley', MeshDeviceType.phone, UserLevel.user),
    };

    return DemoTopologyScenario(
      directContacts: [
        _contact(nodes['relayA']!, now, saved: true),
        _contact(nodes['relayB']!, now, saved: true),
        _contact(nodes['relayC']!, now, saved: false),
        _contact(nodes['relayD']!, now, saved: false),
      ],
      responses: [
        _response('demo-large', nodes['relayA']!, [
          _via(nodes['alpha']!, TransportKind.bluetooth),
          _via(nodes['bravo']!, TransportKind.wifi),
        ], now),
        _response('demo-large', nodes['relayB']!, [
          _via(nodes['bravo']!, TransportKind.wifi),
          _via(nodes['camp']!, TransportKind.lan),
          _via(nodes['gate']!, TransportKind.bluetooth),
        ], now),
        _response('demo-large', nodes['relayC']!, [
          _via(nodes['echo']!, TransportKind.bluetooth),
          _via(nodes['dock']!, TransportKind.wifi),
        ], now),
        _response('demo-large', nodes['relayD']!, [
          _via(nodes['dock']!, TransportKind.wifi),
          _via(nodes['harbor']!, TransportKind.bluetooth),
        ], now),
        _response('demo-large', nodes['alpha']!, [
          _via(nodes['delta']!, TransportKind.bluetooth),
          _via(nodes['iris']!, TransportKind.lan),
        ], now),
        _response('demo-large', nodes['bravo']!, [
          _via(nodes['field']!, TransportKind.wifi),
          _via(nodes['junction']!, TransportKind.lan),
        ], now),
        _response('demo-large', nodes['camp']!, [
          _via(nodes['field']!, TransportKind.lan),
          _via(nodes['kite']!, TransportKind.bluetooth),
        ], now),
        _response('demo-large', nodes['dock']!, [
          _via(nodes['lime']!, TransportKind.bluetooth),
          _via(nodes['mango']!, TransportKind.wifi),
        ], now),
        _response('demo-large', nodes['delta']!, [
          _via(nodes['north']!, TransportKind.bluetooth),
        ], now),
        _response('demo-large', nodes['iris']!, [
          _via(nodes['oak']!, TransportKind.lan),
          _via(nodes['pico']!, TransportKind.bluetooth),
        ], now),
        _response('demo-large', nodes['junction']!, [
          _via(nodes['quartz']!, TransportKind.wifi),
        ], now),
        _response('demo-large', nodes['lime']!, [
          _via(nodes['river']!, TransportKind.bluetooth),
        ], now),
        _response('demo-large', nodes['mango']!, [
          _via(nodes['summit']!, TransportKind.wifi),
          _via(nodes['tower']!, TransportKind.lan),
        ], now),
        _response('demo-large', nodes['north']!, [
          _via(nodes['umbra']!, TransportKind.bluetooth),
        ], now),
        _response('demo-large', nodes['quartz']!, [
          _via(nodes['valley']!, TransportKind.wifi),
        ], now),
      ],
    );
  }

  factory DemoTopologyScenario.depth3() => DemoTopologyScenario.large();
}

TopologyNodeSummary _node(
  int seed,
  String name,
  MeshDeviceType deviceType,
  UserLevel userLevel,
) {
  return TopologyNodeSummary(
    nodeId: Uint8List.fromList(List.generate(16, (index) => seed + index)),
    displayName: name,
    deviceType: deviceType,
    userLevel: userLevel,
    transportKind: TransportKind.bluetooth,
    isSaved: false,
    lastSeen: DateTime.now().millisecondsSinceEpoch,
  );
}

TopologyNodeSummary _via(
  TopologyNodeSummary node,
  TransportKind transportKind,
) {
  return TopologyNodeSummary(
    nodeId: node.nodeId,
    displayName: node.displayName,
    deviceType: node.deviceType,
    userLevel: node.userLevel,
    transportKind: transportKind,
    isSaved: node.isSaved,
    lastSeen: node.lastSeen,
  );
}

Contact _contact(TopologyNodeSummary node, int now, {required bool saved}) {
  return Contact(
    nodeId: node.nodeId,
    publicKey: Uint8List.fromList(List.filled(32, node.nodeId.first)),
    encryptionPublicKey: Uint8List.fromList(List.filled(32, node.nodeId.last)),
    displayName: node.displayName,
    isTrusted: saved,
    fingerprint: 'DEMO',
    firstSeen: now,
    lastSeen: now,
    deviceType: node.deviceType,
    isSaved: saved,
    userLevel: node.userLevel,
  );
}

TopologyResponse _response(
  String requestId,
  TopologyNodeSummary responder,
  List<TopologyNodeSummary> neighbors,
  int now,
) {
  return TopologyResponse(
    requestId: requestId,
    responder: responder,
    neighbors: neighbors,
    timestamp: now,
  );
}
