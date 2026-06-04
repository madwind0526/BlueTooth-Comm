import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_comm/core/ble/ble_constants.dart';
import 'package:mesh_comm/core/ble/ble_fragment_codec.dart';
import 'package:mesh_comm/core/crypto/crypto_service.dart';
import 'package:mesh_comm/core/packet/mesh_packet.dart';
import 'package:mesh_comm/core/packet/msg_type.dart';
import 'package:mesh_comm/features/contacts/contact_model.dart';
import 'package:mesh_comm/features/settings/app_settings.dart';
import 'package:mesh_comm/ui/avatar/avatar_registry.dart';
import 'package:mesh_comm/features/messaging/message_policy.dart';
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

  test('message policy keeps notice messages short and rate limited', () {
    expect(MessagePolicy.normalMaxLength, 160);
    expect(MessagePolicy.noticeMaxLength, 50);
    expect(MessagePolicy.noticeCooldown, const Duration(days: 1));
    expect(MessagePolicy.timedMessageReadTtl, const Duration(minutes: 1));
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
}

Contact _contact({required String name, String? group, bool favorite = false}) {
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
  );
}
