import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_comm/core/ble/ble_constants.dart';
import 'package:mesh_comm/core/ble/ble_fragment_codec.dart';
import 'package:mesh_comm/core/crypto/crypto_service.dart';
import 'package:mesh_comm/core/packet/mesh_packet.dart';
import 'package:mesh_comm/core/packet/msg_type.dart';
import 'package:mesh_comm/core/transport/transport_status.dart';
import 'package:mesh_comm/features/contacts/contact_model.dart';
import 'package:mesh_comm/features/identity/user_level.dart';
import 'package:mesh_comm/features/settings/app_settings.dart';
import 'package:mesh_comm/ui/avatar/avatar_registry.dart';
import 'package:mesh_comm/features/messaging/message_attachment_policy.dart';
import 'package:mesh_comm/features/messaging/message_policy.dart';
import 'package:mesh_comm/features/messaging/topology_demo.dart';
import 'package:mesh_comm/features/messaging/topology_graph.dart';
import 'package:mesh_comm/features/messaging/topology_message.dart';
import 'package:mesh_comm/features/messaging/virtual_mesh_simulator.dart';
import 'package:mesh_comm/ui/home/home_models.dart';

void main() {
  test('MeshComm GATT UUIDs remain stable', () {
    expect(BleConstants.serviceUuid, '4a580001-b5a3-f393-e0a9-e50e24dcca9e');
    expect(
      BleConstants.messageCharUuid,
      '4a580002-b5a3-f393-e0a9-e50e24dcca9e',
    );
  });

  test('development manufacturer ID is explicitly marked', () {
    expect(BleConstants.developmentManufacturerId, 0xffff);
  });

  test('legacy contact rows default local metadata safely', () {
    final contact = Contact.fromMap({
      'node_id': Uint8List(16),
      'public_key': Uint8List(32),
      'is_trusted': 0,
    });

    expect(contact.isFavorite, isFalse);
    expect(contact.groupName, isNull);
    expect(contact.encryptionPublicKey, isNull);
  });

  test('contact rows persist local favorite and group metadata', () {
    final contact = Contact(
      nodeId: Uint8List(16),
      publicKey: Uint8List(32),
      encryptionPublicKey: Uint8List.fromList(List.filled(32, 7)),
      isTrusted: false,
      fingerprint: 'TEST',
      firstSeen: 1,
      lastSeen: 2,
      isFavorite: true,
      groupName: '가족',
    );

    expect(contact.toMap()['is_favorite'], 1);
    expect(contact.toMap()['group_name'], '가족');
    expect(contact.toMap()['encryption_public_key'], isNotNull);
  });

  test('protocol v2 packets serialize and reject another version', () {
    final packet = MeshPacket.create(
      senderId: Uint8List(16),
      targetId: Uint8List.fromList(List.filled(16, 1)),
      msgType: MsgType.text,
      payload: Uint8List.fromList([1, 2, 3]),
    );
    final bytes = packet.toBytes();

    expect(MeshPacket.fromBytes(bytes)?.protocolVersion, 2);
    bytes[0] = 1;
    expect(MeshPacket.fromBytes(bytes), isNull);
  });

  test('BLE fragments round trip at the default low MTU', () {
    final bytes = Uint8List.fromList(List.generate(300, (i) => i % 256));
    final frames = BleFragmentCodec.fragment(
      bytes,
      mtu: BleConstants.defaultMtu,
      transferId: 42,
    );
    final reassembler = BleFragmentReassembler();
    Uint8List? restored;
    for (final frame in frames.reversed) {
      restored = reassembler.add('test-device', frame) ?? restored;
    }

    expect(frames.length, greaterThan(1));
    expect(restored, bytes);
  });

  test('X25519 shared secret is symmetric', () async {
    final crypto = CryptoService();
    final alice = await crypto.generateEncryptionKeyPair();
    final bob = await crypto.generateEncryptionKeyPair();

    final aliceSecret = await crypto.computeSharedSecret(
      alice.privateKey,
      bob.publicKey,
    );
    final bobSecret = await crypto.computeSharedSecret(
      bob.privateKey,
      alice.publicKey,
    );

    expect(aliceSecret, bobSecret);
  });

  test('home contacts sort favorites first and then by display name', () {
    final contacts = [
      _contact(name: 'Charlie'),
      _contact(name: 'Beta', favorite: true),
      _contact(name: 'Alpha', favorite: true),
    ];

    expect(sortContacts(contacts).map(contactDisplayName), [
      'Alpha',
      'Beta',
      'Charlie',
    ]);
  });

  test('home groups derive members and sort favorite groups first', () {
    final contacts = [
      _contact(name: 'One', group: 'Bravo'),
      _contact(name: 'Two', group: 'Alpha', favorite: true),
      _contact(name: 'Three', group: 'Bravo'),
    ];

    final groups = buildGroups(contacts);
    expect(groups.map((group) => group.name), ['Alpha', 'Bravo']);
    expect(groups.last.memberCount, 2);
  });

  test('chat opens only when both local and contact levels can send', () {
    final userContact = _contact(name: 'User');
    final serverContact = _contact(name: 'Server', userLevel: UserLevel.server);

    expect(canOpenChatWithContact(UserLevel.user, userContact), isTrue);
    expect(canOpenChatWithContact(UserLevel.server, userContact), isFalse);
    expect(canOpenChatWithContact(UserLevel.creator, serverContact), isFalse);
  });

  test('message policy keeps notice messages short without cooldown', () {
    expect(MessagePolicy.normalMaxLength, 160);
    expect(MessagePolicy.noticeMaxLength, 50);
    expect(MessagePolicy.noticeCooldown, Duration.zero);
    expect(MessagePolicy.timedMessageReadTtl, const Duration(minutes: 1));
  });

  test('transport and attachment policies expose current limits', () {
    expect(TransportKind.bluetooth.implementedForMessages, isTrue);
    expect(TransportKind.lan.implementedForMessages, isTrue);

    expect(MessageAttachmentPolicy.maxImagesPerMessage, 10);
    expect(MessageAttachmentPolicy.isSupportedExtension('jpg'), isTrue);
    expect(MessageAttachmentPolicy.isSupportedExtension('.zip'), isTrue);
    expect(MessageAttachmentPolicy.isSupportedExtension('exe'), isFalse);
    expect(MessageAttachmentPolicy.canPreviewInline('png', 128 * 1024), isTrue);
    expect(
      MessageAttachmentPolicy.canPreviewInline('png', 512 * 1024),
      isFalse,
    );
  });

  test('avatar registry exposes small built-in animal options', () {
    expect(AppSettings().avatarKey, AvatarRegistry.defaultKey);
    expect(AvatarRegistry.options.length, 16);
    expect(
      AvatarRegistry.byKey('animal_elephant').assetPath,
      contains('animal-avartar-E'),
    );
    expect(AvatarRegistry.byKey('missing').key, AvatarRegistry.defaultKey);
  });

  test('message alert setting defaults to sound and round trips', () {
    expect(AppSettings().messageAlertMode, MessageAlertMode.sound);
    expect(AppSettings().demoMode, isFalse);

    final settings = AppSettings.fromMap({
      'message_alert_mode': 'vibration',
      'demo_mode': 'true',
    });
    expect(settings.messageAlertMode, MessageAlertMode.vibration);
    expect(settings.demoMode, isTrue);
    expect(settings.toMap()['message_alert_mode'], 'vibration');
    expect(settings.toMap()['demo_mode'], 'true');

    expect(
      AppSettings.fromMap({'message_alert_mode': 'silent'}).messageAlertMode,
      MessageAlertMode.silent,
    );
  });

  test('topology request and response payloads round trip', () {
    final nodeId = Uint8List.fromList(List.filled(16, 7));
    final request = TopologyRequest(requestId: 'abc123', requestedDepth: 3);
    expect(
      TopologyRequest.fromPayload(request.toPayload()).requestId,
      'abc123',
    );

    final response = TopologyResponse(
      requestId: 'abc123',
      responder: TopologyNodeSummary(
        nodeId: nodeId,
        displayName: 'PC',
        deviceType: MeshDeviceType.pc,
        userLevel: UserLevel.creator,
        isSaved: true,
        lastSeen: 10,
      ),
      neighbors: [
        TopologyNodeSummary(
          nodeId: Uint8List.fromList(List.filled(16, 8)),
          displayName: 'Phone',
          deviceType: MeshDeviceType.phone,
          userLevel: UserLevel.user,
          transportKind: TransportKind.lan,
          isSaved: false,
          lastSeen: 20,
        ),
      ],
      timestamp: 30,
    );
    final restored = TopologyResponse.fromPayload(response.toPayload());

    expect(restored.requestId, 'abc123');
    expect(restored.responder.deviceType, MeshDeviceType.pc);
    expect(restored.responder.userLevel, UserLevel.creator);
    expect(restored.neighbors.single.displayName, 'Phone');
    expect(restored.neighbors.single.transportKind, TransportKind.lan);
  });

  test('demo topology builds a visible five-depth private mesh', () {
    final scenario = DemoTopologyScenario.large();
    final self = TopologyNodeSummary(
      nodeId: Uint8List.fromList(List.filled(16, 1)),
      displayName: 'Me',
      deviceType: MeshDeviceType.pc,
      userLevel: UserLevel.creator,
      isSaved: true,
      lastSeen: 1,
    );

    final graph = buildTopologyGraph(
      self: self,
      directContacts: scenario.directContacts,
      responses: scenario.responses,
      depth: 5,
    );

    expect(graph.nodes.length, greaterThanOrEqualTo(25));
    expect(graph.edges.length, greaterThanOrEqualTo(24));
    expect(graph.nodes.map((node) => node.depth).reduce(mathMax), 5);
    expect(
      graph.nodes.where((node) => node.depth == 1).length,
      scenario.directContacts.length,
    );
  });

  test('virtual mesh routes normal messages across mixed transports', () {
    final self = _virtualSelf();
    final simulator = VirtualMeshSimulator.fromDemo(self: self);

    final result = simulator.send(
      senderId: nodeIdHex(self.nodeId),
      targetId: virtualNodeId(0x54), // Quartz through BLE -> Wi-Fi -> LAN.
      text: 'hello mixed mesh',
      mode: MessageSendMode.normal,
      nowMs: 1000,
    );

    expect(result.accepted, isTrue);
    final delivery = result.deliveries.single;
    expect(delivery.path.first, nodeIdHex(self.nodeId));
    expect(delivery.path.last, virtualNodeId(0x54));
    expect(delivery.transports, contains(TransportKind.bluetooth));
    expect(delivery.transports, contains(TransportKind.lan));
    expect(delivery.transports, contains(TransportKind.lan));
    expect(delivery.deliveredAtMs, greaterThan(1000));
  });

  test('virtual mesh timed messages expire after read ttl', () {
    final self = _virtualSelf();
    final simulator = VirtualMeshSimulator.fromDemo(self: self);

    final result = simulator.send(
      senderId: nodeIdHex(self.nodeId),
      targetId: virtualNodeId(0x11),
      text: 'one minute',
      mode: MessageSendMode.timed,
      nowMs: 2000,
    );

    expect(result.accepted, isTrue);
    final delivery = result.deliveries.single;
    expect(delivery.expiresAtMs, isNotNull);
    expect(delivery.isVisibleAt(delivery.expiresAtMs! - 1), isTrue);
    expect(delivery.isVisibleAt(delivery.expiresAtMs!), isFalse);
  });

  test('virtual mesh short and long notices use different reach', () {
    final self = _virtualSelf();
    final simulator = VirtualMeshSimulator.fromDemo(self: self);
    final selfId = nodeIdHex(self.nodeId);

    final short = simulator.send(
      senderId: selfId,
      targetId: MeshPacket.broadcast
          .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
          .join(),
      text: 'short notice',
      mode: MessageSendMode.shortNotice,
      nowMs: 3000,
    );
    final long = simulator.send(
      senderId: selfId,
      targetId: MeshPacket.broadcast
          .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
          .join(),
      text: 'long notice',
      mode: MessageSendMode.longNotice,
      nowMs: 4000,
    );

    expect(short.accepted, isTrue);
    expect(short.deliveries.map((delivery) => delivery.targetId), {
      virtualNodeId(0x11),
      virtualNodeId(0x12),
      virtualNodeId(0x14),
    });
    expect(long.accepted, isTrue);
    expect(long.deliveries.length, greaterThan(short.deliveries.length));
    expect(
      long.deliveries.map((delivery) => delivery.targetId),
      contains(virtualNodeId(0x21)),
    );
    expect(
      long.deliveries.map((delivery) => delivery.targetId),
      isNot(contains(virtualNodeId(0x13))), // Server relays but does not show.
    );
  });

  test('virtual mesh enforces server relay-only and allows repeated notices', () {
    final self = _virtualSelf();
    final simulator = VirtualMeshSimulator.fromDemo(self: self);
    final relayB = simulator.nodes[virtualNodeId(0x12)]!;
    relayB.contactIds.add(virtualNodeId(0x33));

    final serverSend = simulator.send(
      senderId: virtualNodeId(0x13),
      targetId: virtualNodeId(0x24),
      text: 'server should not send',
      mode: MessageSendMode.normal,
      nowMs: 5000,
    );
    final firstNotice = simulator.send(
      senderId: relayB.id,
      targetId: virtualNodeId(0x33),
      text: 'builder notice',
      mode: MessageSendMode.shortNotice,
      nowMs: 6000,
    );
    final secondNotice = simulator.send(
      senderId: relayB.id,
      targetId: virtualNodeId(0x33),
      text: 'builder notice again',
      mode: MessageSendMode.shortNotice,
      nowMs: 6000 + const Duration(minutes: 30).inMilliseconds,
    );

    expect(serverSend.accepted, isFalse);
    expect(serverSend.blockedReason, contains('Server'));
    expect(firstNotice.accepted, isTrue);
    expect(secondNotice.accepted, isTrue);
  });
}

int mathMax(int left, int right) => left > right ? left : right;

Contact _contact({
  required String name,
  String? group,
  bool favorite = false,
  UserLevel userLevel = UserLevel.user,
}) {
  return Contact(
    nodeId: Uint8List(16),
    publicKey: Uint8List(32),
    displayName: name,
    isTrusted: false,
    fingerprint: 'TEST',
    firstSeen: 1,
    lastSeen: 2,
    isFavorite: favorite,
    groupName: group,
    userLevel: userLevel,
  );
}

TopologyNodeSummary _virtualSelf() {
  return TopologyNodeSummary(
    nodeId: Uint8List.fromList(List.filled(16, 1)),
    displayName: 'Me',
    deviceType: MeshDeviceType.pc,
    userLevel: UserLevel.creator,
    isSaved: true,
    lastSeen: 1,
  );
}
