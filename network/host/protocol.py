"""Serial protocol for FPGA medical image monitor."""
from __future__ import annotations
from dataclasses import dataclass
import struct
from typing import Iterable

MAGIC = b"\xAA\x55"
VERSION = 1
MAX_PAYLOAD = 16384

CMD_SET_MODE = 0x01
CMD_SET_THRESHOLD = 0x02
CMD_SET_ROI = 0x03
CMD_REQUEST_STATUS = 0x04
CMD_START_ANALYZE = 0x05
CMD_STATUS = 0x81
CMD_MASK_RLE = 0x82
CMD_IMAGE_RAW = 0x83
CMD_ERROR = 0x84
CMD_ACK = 0x85

STATUS_STRUCT = struct.Struct("<BBBBIIII")
MASK_HEADER = struct.Struct("<HHHHH")
IMAGE_HEADER = struct.Struct("<HHHII")
RUN_STRUCT = struct.Struct("<HB")
PACKET_HEADER = struct.Struct("<BBHH")

def crc16_ccitt(data: bytes) -> int:
    crc = 0xFFFF
    for value in data:
        crc ^= value << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if (crc & 0x8000) else (crc << 1) & 0xFFFF
    return crc

@dataclass(frozen=True)
class Packet:
    command: int
    sequence: int
    payload: bytes

def encode_packet(command: int, payload: bytes = b"", sequence: int = 0) -> bytes:
    if len(payload) > MAX_PAYLOAD:
        raise ValueError("payload too large")
    body = PACKET_HEADER.pack(VERSION, command & 0xFF, sequence & 0xFFFF, len(payload)) + payload
    return MAGIC + body + struct.pack("<H", crc16_ccitt(body))

class FrameDecoder:
    def __init__(self, max_payload: int = MAX_PAYLOAD):
        self.buffer = bytearray()
        self.max_payload = max_payload

    def feed(self, data: bytes) -> list[Packet]:
        self.buffer.extend(data)
        packets: list[Packet] = []
        while True:
            if len(self.buffer) < 2:
                break
            start = self.buffer.find(MAGIC)
            if start < 0:
                self.buffer.clear()
                break
            if start:
                del self.buffer[:start]
            if len(self.buffer) < 8:
                break
            version, command, sequence, length = PACKET_HEADER.unpack_from(self.buffer, 2)
            if version != VERSION:
                del self.buffer[0]
                continue
            if length > self.max_payload:
                del self.buffer[0]
                continue
            total = 8 + length + 2
            if len(self.buffer) < total:
                break
            expected = struct.unpack_from("<H", self.buffer, 8 + length)[0]
            body = bytes(self.buffer[2:8 + length])
            if crc16_ccitt(body) != expected:
                del self.buffer[0]
                continue
            payload = bytes(self.buffer[8:8 + length])
            del self.buffer[:total]
            packets.append(Packet(command, sequence, payload))
        return packets

def encode_set_mode(mode: int) -> bytes:
    return encode_packet(CMD_SET_MODE, bytes([mode & 0xFF]))

def encode_set_threshold(threshold: int) -> bytes:
    return encode_packet(CMD_SET_THRESHOLD, bytes([threshold & 0xFF]))

def encode_request_status() -> bytes:
    return encode_packet(CMD_REQUEST_STATUS)

def encode_start_analyze() -> bytes:
    return encode_packet(CMD_START_ANALYZE)

def encode_status(mode: int, threshold: int, area_pixels: int, area_mm2_x100: int,
                  frame_id: int, inference_us: int, flags: int = 0) -> bytes:
    payload = STATUS_STRUCT.pack(mode & 0xFF, threshold & 0xFF, flags & 0xFF, 0,
                                 area_pixels & 0xFFFFFFFF, area_mm2_x100 & 0xFFFFFFFF,
                                 frame_id & 0xFFFFFFFF, inference_us & 0xFFFFFFFF)
    return encode_packet(CMD_STATUS, payload)

def decode_status(payload: bytes) -> dict[str, int | float]:
    if len(payload) != STATUS_STRUCT.size:
        raise ValueError(f"bad status length: {len(payload)}")
    mode, threshold, flags, reserved, area_pixels, area_x100, frame_id, inference_us = STATUS_STRUCT.unpack(payload)
    return {
        "mode": mode,
        "threshold": threshold,
        "flags": flags,
        "reserved": reserved,
        "area_pixels": area_pixels,
        "area_mm2": area_x100 / 100.0,
        "frame_id": frame_id,
        "inference_us": inference_us,
    }

def mask_to_runs(mask: Iterable[int], width: int, height: int) -> list[tuple[int, int]]:
    values = [1 if int(v) else 0 for v in (mask.flat if hasattr(mask, 'flat') else mask)]
    expected = width * height
    if len(values) != expected:
        raise ValueError(f"mask size {len(values)} != {expected}")
    runs: list[tuple[int, int]] = []
    current = values[0]
    count = 1
    for value in values[1:]:
        if value == current and count < 0xFFFF:
            count += 1
        else:
            runs.append((count, current))
            current = value
            count = 1
    runs.append((count, current))
    return runs

def encode_mask_packets(mask: Iterable[int], width: int, height: int,
                        frame_id: int, max_runs_per_packet: int = 1200) -> list[bytes]:
    runs = mask_to_runs(mask, width, height)
    chunks = [runs[i:i + max_runs_per_packet] for i in range(0, len(runs), max_runs_per_packet)]
    packets = []
    for index, chunk in enumerate(chunks):
        payload = bytearray(MASK_HEADER.pack(width, height, frame_id & 0xFFFF, index, len(chunks)))
        for count, value in chunk:
            payload.extend(RUN_STRUCT.pack(count, value))
        packets.append(encode_packet(CMD_MASK_RLE, bytes(payload)))
    return packets

def decode_mask_runs(runs: list[tuple[int, int]], width: int, height: int) -> bytes:
    result = bytearray()
    for count, value in runs:
        result.extend(bytes([1 if value else 0]) * count)
    if len(result) != width * height:
        raise ValueError(f"decoded mask size {len(result)} != {width * height}")
    return bytes(result)

class MaskAssembler:
    def __init__(self):
        self.frames: dict[int, dict[str, object]] = {}

    def feed(self, payload: bytes) -> tuple[int, int, int, bytes] | None:
        if len(payload) < MASK_HEADER.size:
            raise ValueError("short mask header")
        width, height, frame_id, index, count = MASK_HEADER.unpack_from(payload, 0)
        if count <= 0 or index >= count:
            raise ValueError("invalid mask chunk index")
        data = payload[MASK_HEADER.size:]
        if len(data) % RUN_STRUCT.size:
            raise ValueError("invalid mask run payload")
        runs = []
        for offset in range(0, len(data), RUN_STRUCT.size):
            runs.append(RUN_STRUCT.unpack_from(data, offset))
        entry = self.frames.setdefault(frame_id, {"width": width, "height": height, "count": count, "chunks": {}})
        if entry["width"] != width or entry["height"] != height or entry["count"] != count:
            raise ValueError("inconsistent mask chunks")
        entry["chunks"][index] = runs
        if len(entry["chunks"]) != count:
            return None
        all_runs = []
        for chunk_index in range(count):
            all_runs.extend(entry["chunks"][chunk_index])
        del self.frames[frame_id]
        return frame_id, width, height, decode_mask_runs(all_runs, width, height)

class ImageAssembler:
    def __init__(self, max_bytes: int = 4 * 1024 * 1024):
        self.frames: dict[int, dict[str, object]] = {}
        self.max_bytes = max_bytes

    def feed(self, payload: bytes) -> tuple[int, int, int, bytes] | None:
        if len(payload) < IMAGE_HEADER.size:
            raise ValueError("short image header")
        width, height, frame_id, offset, total = IMAGE_HEADER.unpack_from(payload, 0)
        if total <= 0 or total > self.max_bytes or offset + len(payload) - IMAGE_HEADER.size > total:
            raise ValueError("invalid image chunk")
        entry = self.frames.setdefault(frame_id, {"width": width, "height": height, "total": total, "buffer": bytearray(total), "received": 0})
        if entry["width"] != width or entry["height"] != height or entry["total"] != total:
            raise ValueError("inconsistent image chunks")
        data = payload[IMAGE_HEADER.size:]
        entry["buffer"][offset:offset + len(data)] = data
        entry["received"] += len(data)
        if entry["received"] < total:
            return None
        result = bytes(entry["buffer"])
        del self.frames[frame_id]
        return frame_id, width, height, result

def encode_image_packets(image: bytes, width: int, height: int, frame_id: int,
                         chunk_size: int = 1024) -> list[bytes]:
    total = len(image)
    if total != width * height:
        raise ValueError("image size mismatch")
    packets = []
    for offset in range(0, total, chunk_size):
        chunk = image[offset:offset + chunk_size]
        payload = IMAGE_HEADER.pack(width, height, frame_id & 0xFFFF, offset, total) + chunk
        packets.append(encode_packet(CMD_IMAGE_RAW, payload))
    return packets
