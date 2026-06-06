import 'dart:collection';
import 'dart:typed_data';

import 'package:mesh_comm/core/transport/transport_status.dart';
import 'package:mesh_comm/features/contacts/contact_model.dart';

import 'topology_message.dart';

class TopologyGraph {
  final List<TopologyGraphNode> nodes;
  final List<TopologyGraphEdge> edges;

  const TopologyGraph({required this.nodes, required this.edges});
}

class TopologyGraphNode {
  final String id;
  final TopologyNodeSummary summary;
  final Contact? contact;
  final int depth;
  final int connectionCount;

  const TopologyGraphNode({
    required this.id,
    required this.summary,
    this.contact,
    required this.depth,
    required this.connectionCount,
  });
}

class TopologyGraphEdge {
  final String fromId;
  final String toId;
  final TransportKind transportKind;

  const TopologyGraphEdge({
    required this.fromId,
    required this.toId,
    required this.transportKind,
  });
}

TopologyGraph buildTopologyGraph({
  required TopologyNodeSummary self,
  required Iterable<Contact> directContacts,
  required Iterable<TopologyResponse> responses,
  required int depth,
  int maxNodes = 80,
}) {
  final selfId = nodeIdHex(self.nodeId);
  final contactsById = <String, Contact>{};
  final summariesById = <String, TopologyNodeSummary>{selfId: self};
  final adjacency = <String, Set<String>>{};
  final edgeKinds = <String, TransportKind>{};

  void addNode(TopologyNodeSummary summary) {
    summariesById[nodeIdHex(summary.nodeId)] = summary;
  }

  void addEdge(
    String left,
    String right, {
    TransportKind transportKind = TransportKind.bluetooth,
  }) {
    if (left == right) return;
    adjacency.putIfAbsent(left, () => <String>{}).add(right);
    adjacency.putIfAbsent(right, () => <String>{}).add(left);
    final key = _edgeKey(left, right);
    final existing = edgeKinds[key];
    if (existing == null ||
        _transportPriority(transportKind) > _transportPriority(existing)) {
      edgeKinds[key] = transportKind;
    }
  }

  for (final contact in directContacts) {
    final contactId = nodeIdHex(contact.nodeId);
    contactsById[contactId] = contact;
    addNode(TopologyNodeSummary.fromContact(contact));
    addEdge(selfId, contactId);
  }

  for (final response in responses) {
    final responderId = nodeIdHex(response.responder.nodeId);
    addNode(response.responder);
    for (final neighbor in response.neighbors) {
      final neighborId = nodeIdHex(neighbor.nodeId);
      addNode(neighbor);
      addEdge(responderId, neighborId, transportKind: neighbor.transportKind);
    }
  }

  final reachableDepth = <String, int>{selfId: 0};
  final queue = Queue<String>()..add(selfId);
  while (queue.isNotEmpty && reachableDepth.length < maxNodes) {
    final current = queue.removeFirst();
    final currentDepth = reachableDepth[current]!;
    if (depth >= 0 && currentDepth >= depth) continue;

    final neighbors = (adjacency[current] ?? const <String>{}).toList()
      ..sort((left, right) {
        return _nodeName(
          summariesById[left],
          left,
        ).compareTo(_nodeName(summariesById[right], right));
      });
    for (final neighbor in neighbors) {
      if (reachableDepth.containsKey(neighbor)) continue;
      reachableDepth[neighbor] = currentDepth + 1;
      queue.add(neighbor);
      if (reachableDepth.length >= maxNodes) break;
    }
  }

  final included = reachableDepth.keys.toSet();
  final edges = <TopologyGraphEdge>[];
  final seenEdges = <String>{};
  adjacency.forEach((from, neighbors) {
    if (!included.contains(from)) return;
    for (final to in neighbors) {
      if (!included.contains(to)) continue;
      final edgeKey = from.compareTo(to) <= 0 ? '$from:$to' : '$to:$from';
      if (!seenEdges.add(edgeKey)) continue;
      edges.add(
        TopologyGraphEdge(
          fromId: from,
          toId: to,
          transportKind: edgeKinds[edgeKey] ?? TransportKind.bluetooth,
        ),
      );
    }
  });

  final degree = <String, int>{};
  for (final edge in edges) {
    degree[edge.fromId] = (degree[edge.fromId] ?? 0) + 1;
    degree[edge.toId] = (degree[edge.toId] ?? 0) + 1;
  }

  final nodes =
      included
          .map(
            (id) => TopologyGraphNode(
              id: id,
              summary: summariesById[id]!,
              contact: contactsById[id],
              depth: reachableDepth[id]!,
              connectionCount: degree[id] ?? 0,
            ),
          )
          .toList()
        ..sort((left, right) {
          final depthOrder = left.depth.compareTo(right.depth);
          if (depthOrder != 0) return depthOrder;
          return _nodeName(
            left.summary,
            left.id,
          ).compareTo(_nodeName(right.summary, right.id));
        });

  edges.sort((left, right) {
    final leftKey = '${left.fromId}:${left.toId}';
    final rightKey = '${right.fromId}:${right.toId}';
    return leftKey.compareTo(rightKey);
  });

  return TopologyGraph(nodes: nodes, edges: edges);
}

String nodeIdHex(Uint8List bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

String _nodeName(TopologyNodeSummary? summary, String id) {
  final name = summary?.displayName?.trim();
  return name == null || name.isEmpty ? id : name.toLowerCase();
}

String _edgeKey(String left, String right) =>
    left.compareTo(right) <= 0 ? '$left:$right' : '$right:$left';

int _transportPriority(TransportKind kind) {
  return switch (kind) {
    TransportKind.lan => 3,
    TransportKind.wifi => 2,
    TransportKind.bluetooth => 1,
  };
}
