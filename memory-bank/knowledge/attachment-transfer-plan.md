# Attachment Transfer Plan

## Current Constraint

- `MeshPacket.maxPayloadSize` is 4096 bytes.
- BLE fragmentation currently splits one `MeshPacket` across low-MTU BLE frames.
- It does not yet split a large file into many signed/encrypted `MeshPacket`s.

Because of this, sending normal documents, zip files, audio/video, or multiple images directly over the current TEXT path is not safe.

## Recommended Phases

### Attachment Phase A: Small Image Preview

- Add an attachment picker in `ChatScreen`.
- Allow one image first.
- Resize/compress the selected image into a small preview under 4096 bytes.
- Send it as a new attachment metadata payload.
- Receiver shows a small thumbnail bubble.

This is the safest first step and is useful for testing UI and storage.

### Attachment Phase B: Multi-Chunk File Transfer

Add a separate transfer protocol:

- `ATTACHMENT_OFFER`: file name, MIME type, byte size, SHA-256 hash, transfer ID, thumbnail if image.
- `ATTACHMENT_CHUNK`: transfer ID, chunk index, chunk count, encrypted bytes.
- `ATTACHMENT_ACK`: received chunk/complete confirmation.
- `ATTACHMENT_CANCEL`: sender/receiver cancel.

Each chunk must fit inside `MeshPacket.maxPayloadSize` after encryption overhead.

### Attachment Phase C: Multiple Images And Large Files

- Multiple images: up to 10 only after Phase B is stable.
- Documents/contact files/zip/audio/video: allow after resume, retry, and storage cleanup are implemented.
- For video/audio, prefer explicit user confirmation because transfer may take a long time over BLE mesh.

## Storage Policy

- Store attachment metadata in DB separately from `messages`.
- Store binary files in app documents directory, not directly in SQLite.
- Delete attachment files when:
  - the related contact is deleted,
  - the related timeout message expires,
  - the app is uninstalled.

## Security Policy

- 1:1 attachments use the same X25519 + AES-GCM end-to-end encryption as text.
- Relay nodes must not read file content.
- Shout/broadcast attachments should be blocked initially.

## Initial Scope Decision

Do not implement full file transfer in the current pass. The next safe coding step is:

1. Add attachment UI affordance in chat.
2. Add DB schema for attachment metadata.
3. Implement one compressed image preview under 4096 bytes.
4. Add tests for payload size rejection and metadata parsing.
