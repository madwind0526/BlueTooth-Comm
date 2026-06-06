import 'dart:collection';
import 'dart:typed_data';

import 'package:mesh_comm/core/packet/mesh_packet.dart';
import 'package:mesh_comm/core/transport/transport_status.dart';
import 'package:mesh_comm/features/contacts/contact_model.dart';
import 'package:mesh_comm/features/identity/user_level.dart';

import 'message_policy.dart';
import 'topology_demo.dart';
import 'topology_graph.dart';
import 'topology_message.dart';

class VirtualMeshNode {
  final String id;
  final String name;
  final MeshDeviceType deviceType;
  final UserLevel userLevel;
  final Set<String> contactIds;
  int lastShortNoticeAt;
  int lastLongNoticeAt;

  VirtualMeshNode({
    required this.id,
    required this.name,
    required this.deviceType,
    required this.userLevel,
    Set<String>? contactIds,
    this.lastShortNoticeAt = 0,
    this.lastLongNoticeAt = 0,
  }) : contactIds = contactIds ?? <String>{};

  bool get canShowMessages => userLevel.canSendMessages;
}

class VirtualMeshLink {
  final String a;
  final String b;
  final TransportKind transportKind;
  final bool enabled;

  const VirtualMeshLink({
    required this.a,
    required this.b,
    required this.transportKind,
    this.enabled = true,
  });

  bool connects(String nodeId) => a == nodeId || b == nodeId;

  String other(String nodeId) {
    if (nodeId == a) return b;
    if (nodeId == b) return a;
    throw ArgumentError('Node $nodeId is not connected by this link.');
  }
}

class VirtualMeshDelivery {
  final String senderId;
  final String targetId;
  final String text;
  final MessageSendMode mode;
  final List<String> path;
  final List<TransportKind> transports;
  final int deliveredAtMs;
  final int? expiresAtMs;

  const VirtualMeshDelivery({
    required this.senderId,
    required this.targetId,
    required this.text,
    required this.mode,
    required this.path,
    required this.transports,
    required this.deliveredAtMs,
    this.expiresAtMs,
  });

  int get hopCount => path.length <= 1 ? 0 : path.length - 1;

  bool isVisibleAt(int nowMs) => expiresAtMs == null || nowMs < expiresAtMs!;
}

class VirtualMeshSendResult {
  final bool accepted;
  final String? blockedReason;
  final List<VirtualMeshDelivery> deliveries;

  const VirtualMeshSendResult._({
    required this.accepted,
    required this.blockedReason,
    required this.deliveries,
  });

  factory VirtualMeshSendResult.blocked(String reason) {
    return VirtualMeshSendResult._(
      accepted: false,
      blockedReason: reason,
      deliveries: const [],
    );
  }

  factory VirtualMeshSendResult.sent(List<VirtualMeshDelivery> deliveries) {
    return VirtualMeshSendResult._(
      accepted: deliveries.isNotEmpty,
      blockedReason: deliveries.isEmpty ? 'No reachable recipients.' : null,
      deliveries: List.unmodifiable(deliveries),
    );
  }
}

class VirtualMeshSimulator {
  final Map<String, VirtualMeshNode> nodes;
  final List<VirtualMeshLink> links;

  VirtualMeshSimulator({
    required Iterable<VirtualMeshNode> nodes,
    required Iterable<VirtualMeshLink> links,
  }) : nodes = {for (final node in nodes) node.id: node},
       links = List.unmodifiable(links);

  factory VirtualMeshSimulator.fromDemo({
    required TopologyNodeSummary self,
    DemoTopologyScenario? scenario,
  }) {
    final demo = scenario ?? DemoTopologyScenario.large();
    final nodeMap = <String, VirtualMeshNode>{
      nodeIdHex(self.nodeId): VirtualMeshNode(
        id: nodeIdHex(self.nodeId),
        name: self.displayName ?? 'Me',
        deviceType: self.deviceType,
        userLevel: self.userLevel,
      ),
    };
    final linkMap = <String, VirtualMeshLink>{};

    void addNode(TopologyNodeSummary summary) {
      final id = nodeIdHex(summary.nodeId);
      nodeMap.putIfAbsent(
        id,
        () => VirtualMeshNode(
          id: id,
          name: summary.displayName ?? id.substring(0, 8),
          deviceType: summary.deviceType,
          userLevel: summary.userLevel,
        ),
      );
    }

    void addLink(
      String a,
      String b, {
      TransportKind transportKind = TransportKind.bluetooth,
    }) {
      if (a == b) return;
      final key = _edgeKey(a, b);
      final existing = linkMap[key];
      if (existing == null ||
          _transportPriority(transportKind) >
              _transportPriority(existing.transportKind)) {
        linkMap[key] = VirtualMeshLink(
          a: a,
          b: b,
          transportKind: transportKind,
        );
      }
    }

    final selfId = nodeIdHex(self.nodeId);
    for (final contact in demo.directContacts) {
      final summary = TopologyNodeSummary.fromContact(contact);
      addNode(summary);
      final contactId = nodeIdHex(contact.nodeId);
      nodeMap[selfId]!.contactIds.add(contactId);
      addLink(selfId, contactId);
    }

    for (final response in demo.responses) {
      addNode(response.responder);
      final responderId = nodeIdHex(response.responder.nodeId);
      for (final neighbor in response.neighbors) {
        addNode(neighbor);
        addLink(
          responderId,
          nodeIdHex(neighbor.nodeId),
          transportKind: neighbor.transportKind,
        );
      }
    }

    return VirtualMeshSimulator(nodes: nodeMap.values, links: linkMap.values);
  }

  List<VirtualMeshLink> linksOf(String nodeId) {
    return links
        .where((link) => link.enabled && link.connects(nodeId))
        .toList();
  }

  VirtualMeshSendResult send({
    required String senderId,
    required String targetId,
    required String text,
    required MessageSendMode mode,
    required int nowMs,
  }) {
    final sender = nodes[senderId];
    if (sender == null) return VirtualMeshSendResult.blocked('Unknown sender.');
    if (!sender.userLevel.canSendMessages) {
      return VirtualMeshSendResult.blocked('Server nodes can only relay.');
    }
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      return VirtualMeshSendResult.blocked('Message is empty.');
    }
    if (trimmed.length > mode.maxLength) {
      return VirtualMeshSendResult.blocked('Message is too long.');
    }

    if (mode == MessageSendMode.shortNotice ||
        mode == MessageSendMode.longNotice) {
      return _sendNotice(
        sender: sender,
        text: trimmed,
        mode: mode,
        nowMs: nowMs,
      );
    }

    final target = nodes[targetId];
    if (target == null) return VirtualMeshSendResult.blocked('Unknown target.');
    if (!target.canShowMessages) {
      return VirtualMeshSendResult.blocked('Target is relay-only server.');
    }
    final route = _shortestRoute(
      senderId: senderId,
      targetId: targetId,
      ttl: MeshPacket.defaultTtl,
    );
    if (route == null) {
      return VirtualMeshSendResult.blocked('No route to target.');
    }
    return VirtualMeshSendResult.sent([
      _deliveryFromRoute(route, text: trimmed, mode: mode, nowMs: nowMs),
    ]);
  }

  VirtualMeshSendResult _sendNotice({
    required VirtualMeshNode sender,
    required String text,
    required MessageSendMode mode,
    required int nowMs,
  }) {
    final cooldown = sender.userLevel.noticeCooldown(mode);
    if (cooldown == null) {
      return VirtualMeshSendResult.blocked('Server nodes can only relay.');
    }
    final lastUsedMs = mode == MessageSendMode.shortNotice
        ? sender.lastShortNoticeAt
        : sender.lastLongNoticeAt;
    if (cooldown > Duration.zero &&
        lastUsedMs > 0 &&
        nowMs - lastUsedMs < cooldown.inMilliseconds) {
      return VirtualMeshSendResult.blocked('Notice cooldown is active.');
    }

    final deliveries = mode == MessageSendMode.shortNotice
        ? _shortNoticeDeliveries(sender, text, nowMs)
        : _longNoticeDeliveries(sender, text, nowMs);
    if (deliveries.isEmpty) {
      return VirtualMeshSendResult.blocked('No reachable recipients.');
    }

    if (mode == MessageSendMode.shortNotice) {
      sender.lastShortNoticeAt = nowMs;
    } else {
      sender.lastLongNoticeAt = nowMs;
    }
    return VirtualMeshSendResult.sent(deliveries);
  }

  List<VirtualMeshDelivery> _shortNoticeDeliveries(
    VirtualMeshNode sender,
    String text,
    int nowMs,
  ) {
    final deliveries = <VirtualMeshDelivery>[];
    for (final contactId in sender.contactIds) {
      final target = nodes[contactId];
      if (target == null || !target.canShowMessages) continue;
      final route = _shortestRoute(
        senderId: sender.id,
        targetId: contactId,
        ttl: MessagePolicy.shortNoticeTtl,
      );
      if (route == null) continue;
      deliveries.add(
        _deliveryFromRoute(
          route,
          text: text,
          mode: MessageSendMode.shortNotice,
          nowMs: nowMs,
        ),
      );
    }
    return deliveries;
  }

  List<VirtualMeshDelivery> _longNoticeDeliveries(
    VirtualMeshNode sender,
    String text,
    int nowMs,
  ) {
    final routes = _broadcastRoutes(
      senderId: sender.id,
      ttl: MessagePolicy.longNoticeTtl,
    );
    return routes
        .where((route) {
          final target = nodes[route.nodeIds.last];
          return target != null && target.canShowMessages;
        })
        .map(
          (route) => _deliveryFromRoute(
            route,
            text: text,
            mode: MessageSendMode.longNotice,
            nowMs: nowMs,
          ),
        )
        .toList();
  }

  _VirtualRoute? _shortestRoute({
    required String senderId,
    required String targetId,
    required int ttl,
  }) {
    if (senderId == targetId) {
      return _VirtualRoute(nodeIds: [senderId], transports: const []);
    }
    final queue = Queue<_VirtualRoute>()
      ..add(_VirtualRoute(nodeIds: [senderId], transports: const []));
    final visited = <String>{senderId};
    while (queue.isNotEmpty) {
      final route = queue.removeFirst();
      if (route.hopCount >= ttl) continue;
      for (final link in _sortedLinksOf(route.nodeIds.last)) {
        final next = link.other(route.nodeIds.last);
        if (!visited.add(next)) continue;
        final nextRoute = route.extend(next, link.transportKind);
        if (next == targetId) return nextRoute;
        queue.add(nextRoute);
      }
    }
    return null;
  }

  List<_VirtualRoute> _broadcastRoutes({
    required String senderId,
    required int ttl,
  }) {
    final routes = <_VirtualRoute>[];
    final queue = Queue<_VirtualRoute>()
      ..add(_VirtualRoute(nodeIds: [senderId], transports: const []));
    final visited = <String>{senderId};
    while (queue.isNotEmpty) {
      final route = queue.removeFirst();
      if (route.hopCount >= ttl) continue;
      for (final link in _sortedLinksOf(route.nodeIds.last)) {
        final next = link.other(route.nodeIds.last);
        if (!visited.add(next)) continue;
        final nextRoute = route.extend(next, link.transportKind);
        routes.add(nextRoute);
        queue.add(nextRoute);
      }
    }
    return routes;
  }

  List<VirtualMeshLink> _sortedLinksOf(String nodeId) {
    return linksOf(nodeId)..sort((left, right) {
      final priorityOrder = _transportPriority(
        right.transportKind,
      ).compareTo(_transportPriority(left.transportKind));
      if (priorityOrder != 0) return priorityOrder;
      return left.other(nodeId).compareTo(right.other(nodeId));
    });
  }

  VirtualMeshDelivery _deliveryFromRoute(
    _VirtualRoute route, {
    required String text,
    required MessageSendMode mode,
    required int nowMs,
  }) {
    final deliveredAtMs =
        nowMs +
        route.transports.fold<int>(
          0,
          (sum, kind) => sum + _transportLatencyMs(kind),
        );
    return VirtualMeshDelivery(
      senderId: route.nodeIds.first,
      targetId: route.nodeIds.last,
      text: text,
      mode: mode,
      path: route.nodeIds,
      transports: route.transports,
      deliveredAtMs: deliveredAtMs,
      expiresAtMs: mode == MessageSendMode.timed
          ? deliveredAtMs + MessagePolicy.timedMessageReadTtl.inMilliseconds
          : null,
    );
  }
}

class _VirtualRoute {
  final List<String> nodeIds;
  final List<TransportKind> transports;

  const _VirtualRoute({required this.nodeIds, required this.transports});

  int get hopCount => nodeIds.length - 1;

  _VirtualRoute extend(String nodeId, TransportKind transportKind) {
    return _VirtualRoute(
      nodeIds: [...nodeIds, nodeId],
      transports: [...transports, transportKind],
    );
  }
}

String virtualNodeId(int seed) {
  return Uint8List.fromList(
    List.generate(16, (index) => seed + index),
  ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}

String _edgeKey(String a, String b) => a.compareTo(b) <= 0 ? '$a:$b' : '$b:$a';

int _transportPriority(TransportKind kind) {
  return switch (kind) {
    TransportKind.lan => 3,
    TransportKind.wifi => 2,
    TransportKind.bluetooth => 1,
  };
}

int _transportLatencyMs(TransportKind kind) {
  return switch (kind) {
    TransportKind.lan => 10,
    TransportKind.wifi => 40,
    TransportKind.bluetooth => 180,
  };
}
