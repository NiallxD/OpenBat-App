#!/usr/bin/env python3
"""
mvt_lite.py

A tiny Mapbox Vector Tile reader — just enough to pull point positions out of
GBIF's occurrence density tiles, with no third-party dependencies.

WHY NOT mapbox-vector-tile
--------------------------
This is a build-time tool that has to still run in five years on whatever Python
is installed then. The MVT wire format is protobuf, and the handful of fields we
need (layer extent, feature geometry) can be read straight off the wire without
the schema or a compiled descriptor. That is ~100 lines here against a
dependency chain (protobuf + shapely) that has broken across major versions
before. Nothing about this ships in the app.

WHY COUNTS ARE READ, NOT JUST POSITIONS
---------------------------------------
An earlier version skipped attributes on the reasoning that presence was the
only question. That was wrong, and the data says so plainly: asking for the gray
bat — a Tennessee and Alabama cave species — returns bins as far out as Alaska.
Raw occurrence records carry misidentifications, transposed coordinates and
museum specimens catalogued at their institution rather than their collection
site, so "any record here" is not "the species lives here". The density tiles
carry a count per bin, which is what makes an outlier separable from a range, so
the key/value tables have to be decoded after all.

WHAT IT DELIBERATELY DOESN'T DO
-------------------------------
Lines and polygons are decoded as their vertices, not as shapes — we only ever
ask whether a bin sits over a place, so a ring's interior is irrelevant.
"""

import math
import struct

# Protobuf wire types we care about.
_VARINT = 0
_LEN = 2

# Field numbers from the MVT spec (version 2).
_TILE_LAYERS = 3
_LAYER_NAME = 1
_LAYER_FEATURES = 2
_LAYER_KEYS = 3
_LAYER_VALUES = 4
_LAYER_EXTENT = 5
_FEATURE_TAGS = 2
_FEATURE_GEOMETRY = 4

# Value message field numbers — a Value carries exactly one of these.
_VALUE_STRING = 1
_VALUE_FLOAT = 2
_VALUE_DOUBLE = 3
_VALUE_INT64 = 4
_VALUE_UINT64 = 5
_VALUE_SINT64 = 6

# MVT geometry commands.
_MOVE_TO = 1
_LINE_TO = 2


def _read_varint(data: bytes, pos: int) -> tuple[int, int]:
    result = 0
    shift = 0
    while True:
        if pos >= len(data):
            raise ValueError("truncated varint")
        byte = data[pos]
        pos += 1
        result |= (byte & 0x7F) << shift
        if not byte & 0x80:
            return result, pos
        shift += 7
        if shift > 63:
            raise ValueError("varint too long")


def _iter_fields(data: bytes):
    """Yield (field_number, payload) for every field in a protobuf message.

    Payload is bytes for length-delimited fields and an int for varints. The two
    fixed-width wire types are skipped rather than returned: MVT uses neither for
    anything read here, and silently mis-parsing them would be worse than
    ignoring them.
    """
    pos = 0
    while pos < len(data):
        key, pos = _read_varint(data, pos)
        field, wire = key >> 3, key & 0x07
        if wire == _VARINT:
            value, pos = _read_varint(data, pos)
            yield field, value
        elif wire == _LEN:
            length, pos = _read_varint(data, pos)
            yield field, data[pos:pos + length]
            pos += length
        elif wire == 1:   # 64-bit
            pos += 8
        elif wire == 5:   # 32-bit
            pos += 4
        else:
            raise ValueError(f"unsupported wire type {wire}")


def _decode_geometry(commands: list[int]) -> list[tuple[int, int]]:
    """Turn an MVT command sequence into tile-local vertices.

    Coordinates are zigzag-encoded deltas from the previous point, which is why
    this has to be walked in order rather than sampled.
    """
    points = []
    x = y = 0
    index = 0
    while index < len(commands):
        header = commands[index]
        index += 1
        command = header & 0x07
        count = header >> 3
        if command in (_MOVE_TO, _LINE_TO):
            for _ in range(count):
                if index + 1 >= len(commands):
                    return points
                dx = (commands[index] >> 1) ^ (-(commands[index] & 1))
                dy = (commands[index + 1] >> 1) ^ (-(commands[index + 1] & 1))
                index += 2
                x += dx
                y += dy
                points.append((x, y))
        else:
            # ClosePath carries no coordinates.
            continue
    return points


def _packed_varints(payload: bytes) -> list[int]:
    values = []
    pos = 0
    while pos < len(payload):
        value, pos = _read_varint(payload, pos)
        values.append(value)
    return values


def _decode_value(payload: bytes) -> int | float | str | None:
    """One MVT Value message. Fixed-width wire types are handled here because
    `_iter_fields` skips them — harmless everywhere else in a tile, but a float
    count would otherwise silently read as absent."""
    pos = 0
    while pos < len(payload):
        key, pos = _read_varint(payload, pos)
        field, wire = key >> 3, key & 0x07
        if wire == _VARINT:
            value, pos = _read_varint(payload, pos)
            if field == _VALUE_SINT64:
                return (value >> 1) ^ (-(value & 1))
            if field in (_VALUE_INT64, _VALUE_UINT64):
                return value
        elif wire == _LEN:
            length, pos = _read_varint(payload, pos)
            chunk = payload[pos:pos + length]
            pos += length
            if field == _VALUE_STRING:
                return chunk.decode("utf-8", "replace")
        elif wire == 1:
            chunk = payload[pos:pos + 8]
            pos += 8
            if field == _VALUE_DOUBLE:
                return struct.unpack("<d", chunk)[0]
        elif wire == 5:
            chunk = payload[pos:pos + 4]
            pos += 4
            if field == _VALUE_FLOAT:
                return struct.unpack("<f", chunk)[0]
        else:
            break
    return None


def tile_bins(data: bytes, count_key: str = "total") -> list[tuple[float, float, int]]:
    """Every feature in a tile as (lat, lon, count) in WGS84.

    Position is the feature's first vertex — for GBIF's binned density tiles that
    is a corner of the bin, which at zoom 0 is far finer than the presence grid
    it feeds, so the corner and the centre land in the same cell.

    `count` is the feature's `total` attribute, or 1 when the tile carries no
    such attribute. Assumes the whole-world tile at zoom 0 (GBIF's 0/0/0), which
    is what the generator requests — one tile per species instead of paging
    through tens of thousands of individual records.
    """
    out = []
    for field, payload in _iter_fields(data):
        if field != _TILE_LAYERS or not isinstance(payload, bytes):
            continue

        extent = 4096
        keys: list[str] = []
        values: list[int | float | str | None] = []
        features: list[bytes] = []
        for lfield, lpayload in _iter_fields(payload):
            if lfield == _LAYER_EXTENT and isinstance(lpayload, int):
                extent = lpayload
            elif lfield == _LAYER_KEYS and isinstance(lpayload, bytes):
                keys.append(lpayload.decode("utf-8", "replace"))
            elif lfield == _LAYER_VALUES and isinstance(lpayload, bytes):
                values.append(_decode_value(lpayload))
            elif lfield == _LAYER_FEATURES and isinstance(lpayload, bytes):
                features.append(lpayload)

        for feature in features:
            vertices: list[tuple[int, int]] = []
            tags: list[int] = []
            for ffield, fpayload in _iter_fields(feature):
                if ffield == _FEATURE_GEOMETRY and isinstance(fpayload, bytes):
                    vertices = _decode_geometry(_packed_varints(fpayload))
                elif ffield == _FEATURE_TAGS and isinstance(fpayload, bytes):
                    tags = _packed_varints(fpayload)
            if not vertices:
                continue

            count = 1
            for key_index, value_index in zip(tags[0::2], tags[1::2]):
                if key_index < len(keys) and keys[key_index] == count_key:
                    if value_index < len(values):
                        raw = values[value_index]
                        if isinstance(raw, (int, float)):
                            count = int(raw)
                    break

            lat, lon = _unproject(vertices[0][0], vertices[0][1], extent)
            out.append((lat, lon, count))
    return out


def tile_points(data: bytes) -> list[tuple[float, float]]:
    """Positions only, for callers that genuinely don't care how many."""
    return [(lat, lon) for lat, lon, _ in tile_bins(data)]


def _unproject(x: int, y: int, extent: int) -> tuple[float, float]:
    """Tile-local coordinates at zoom 0 back to (lat, lon).

    Web Mercator: x is linear in longitude, y is not linear in latitude. Points
    outside the tile (MVT allows a buffer beyond the edges) are clamped rather
    than dropped — at zoom 0 the buffer is off the edge of the world, and a bat
    is not at longitude 200.
    """
    fx = min(1.0, max(0.0, x / extent))
    fy = min(1.0, max(0.0, y / extent))
    lon = fx * 360.0 - 180.0
    n = math.pi * (1 - 2 * fy)
    lat = math.degrees(math.atan(math.sinh(n)))
    return lat, lon
