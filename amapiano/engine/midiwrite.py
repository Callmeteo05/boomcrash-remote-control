"""Minimal type-1 MIDI writer (no external deps).

Notes are given in beats; the writer converts to ticks, sorts events and
emits one MTrk per part so a DAW shows them as separate tracks.
"""

import struct

PPQ = 480


def _vlq(value):
    """Variable-length quantity encoding used by MIDI delta times."""
    value = int(value)
    out = bytearray([value & 0x7F])
    value >>= 7
    while value:
        out.insert(0, (value & 0x7F) | 0x80)
        value >>= 7
    return bytes(out)


def _chunk(tag, payload):
    return tag + struct.pack('>I', len(payload)) + payload


def _track(name, notes, tempo=None, channel=0, ppq=PPQ):
    """notes: iterable of (start_beat, length_beats, midi_note, velocity)."""
    events = []  # (tick, order, bytes)

    meta = bytearray()
    nb = name.encode('ascii', 'replace')
    meta += b'\x00\xff\x03' + _vlq(len(nb)) + nb
    if tempo is not None:
        us = int(round(60_000_000 / tempo))
        meta += b'\x00\xff\x51\x03' + struct.pack('>I', us)[1:]
        meta += b'\x00\xff\x58\x04\x04\x02\x18\x08'  # 4/4

    for start, length, note, vel in notes:
        on = int(round(start * ppq))
        off = max(on + 1, int(round((start + length) * ppq)))
        note = int(max(0, min(127, note)))
        vel = int(max(1, min(127, vel)))
        # note-offs sort before note-ons at the same tick to avoid stuck notes
        events.append((off, 0, bytes([0x80 | channel, note, 64])))
        events.append((on, 1, bytes([0x90 | channel, note, vel])))

    events.sort(key=lambda e: (e[0], e[1]))
    payload = bytearray(meta)
    last = 0
    for tick, _, data in events:
        payload += _vlq(tick - last) + data
        last = tick
    payload += b'\x00\xff\x2f\x00'
    return _chunk(b'MTrk', bytes(payload))


def write_midi(path, tracks, tempo=112.0, ppq=PPQ):
    """tracks: list of (name, notes, channel)."""
    header = _chunk(b'MThd', struct.pack('>HHH', 1, len(tracks) + 1, ppq))
    body = _track('Tempo', [], tempo=tempo, ppq=ppq)
    for name, notes, channel in tracks:
        body += _track(name, notes, channel=channel, ppq=ppq)
    with open(path, 'wb') as f:
        f.write(header + body)
    return path
