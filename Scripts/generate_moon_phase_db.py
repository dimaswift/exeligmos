#!/usr/bin/env python3
from __future__ import annotations

import argparse
import struct
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

from skyfield import almanac
from skyfield.api import Loader


MAGIC = b"MOONP01\0"
VERSION = 1
HEADER_SIZE = 56
SYNODIC_MONTH_DAYS = 29.530588853
SYNODIC_MONTH_MICROS = round(SYNODIC_MONTH_DAYS * 86_400 * 1_000_000)


@dataclass(frozen=True)
class LunarEvent:
    unix_seconds: int
    phase: int
    lunation_index: int
    correction: int


def parse_utc(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(timezone.utc)


def round_div(numerator: int, denominator: int) -> int:
    if numerator >= 0:
        return (numerator + denominator // 2) // denominator
    return -((-numerator + denominator // 2) // denominator)


def predicted_seconds(reference_unix: int, lunation_index: int, is_full: bool) -> int:
    predicted_micros = reference_unix * 1_000_000 + lunation_index * SYNODIC_MONTH_MICROS
    if is_full:
        predicted_micros += SYNODIC_MONTH_MICROS // 2
    return round_div(predicted_micros, 1_000_000)


def signed_int24(value: int) -> bytes:
    if not -(1 << 23) <= value < (1 << 23):
        raise ValueError(f"Correction {value} does not fit in signed 24-bit storage")
    if value < 0:
        value += 1 << 24
    return bytes((value & 0xFF, (value >> 8) & 0xFF, (value >> 16) & 0xFF))


def event_index(unix_seconds: int, reference_unix: int, phase: int) -> int:
    phase_offset = 0.5 if phase == 2 else 0.0
    raw = (unix_seconds - reference_unix) / (SYNODIC_MONTH_MICROS / 1_000_000) - phase_offset
    return round(raw)


def generate_events(
    *,
    data_dir: Path,
    coverage_start: datetime,
    coverage_end: datetime,
    search_start: datetime,
    search_end: datetime,
    reference_date: datetime,
) -> tuple[int, list[LunarEvent], list[LunarEvent]]:
    load = Loader(str(data_dir))
    timescale = load.timescale()
    ephemeris = load("de440s.bsp")
    phase_function = almanac.moon_phases(ephemeris)

    search_t0 = timescale.from_datetime(search_start)
    search_t1 = timescale.from_datetime(search_end)
    times, phases = almanac.find_discrete(search_t0, search_t1, phase_function)

    raw_events: list[tuple[int, int]] = []
    for time, phase in zip(times, phases):
        phase_code = int(phase)
        if phase_code not in (0, 2):
            continue
        timestamp = round(time.utc_datetime().replace(tzinfo=timezone.utc).timestamp())
        raw_events.append((timestamp, phase_code))

    reference_timestamp = round(reference_date.timestamp())
    new_moons = [event for event in raw_events if event[1] == 0]
    reference_unix = min(new_moons, key=lambda event: abs(event[0] - reference_timestamp))[0]

    new_events: list[LunarEvent] = []
    full_events: list[LunarEvent] = []
    for unix_seconds, phase in raw_events:
        lunation_index = event_index(unix_seconds, reference_unix, phase)
        correction = unix_seconds - predicted_seconds(reference_unix, lunation_index, phase == 2)
        event = LunarEvent(
            unix_seconds=unix_seconds,
            phase=phase,
            lunation_index=lunation_index,
            correction=correction,
        )
        if phase == 0:
            new_events.append(event)
        else:
            full_events.append(event)

    new_events.sort(key=lambda event: event.lunation_index)
    full_events.sort(key=lambda event: event.lunation_index)

    assert_contiguous(new_events, "new")
    assert_contiguous(full_events, "full")
    assert_brackets_coverage(new_events, coverage_start, coverage_end)

    return reference_unix, new_events, full_events


def assert_contiguous(events: list[LunarEvent], label: str) -> None:
    indices = [event.lunation_index for event in events]
    expected = list(range(indices[0], indices[0] + len(indices)))
    if indices != expected:
        raise ValueError(f"{label} moon lunation indices are not contiguous")


def assert_brackets_coverage(events: list[LunarEvent], coverage_start: datetime, coverage_end: datetime) -> None:
    start = round(coverage_start.timestamp())
    end = round(coverage_end.timestamp())
    if not events[0].unix_seconds <= start:
        raise ValueError("First new moon does not bracket coverage start")
    if not events[-1].unix_seconds >= end:
        raise ValueError("Last new moon does not bracket coverage end")


def write_database(
    output: Path,
    *,
    coverage_start: datetime,
    coverage_end: datetime,
    reference_unix: int,
    new_events: list[LunarEvent],
    full_events: list[LunarEvent],
) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    header = bytearray()
    header += MAGIC
    header += struct.pack("<H", VERSION)
    header += struct.pack("<H", HEADER_SIZE)
    header += struct.pack("<q", round(coverage_start.timestamp()))
    header += struct.pack("<q", round(coverage_end.timestamp()))
    header += struct.pack("<q", reference_unix)
    header += struct.pack("<q", SYNODIC_MONTH_MICROS)
    header += struct.pack("<i", new_events[0].lunation_index)
    header += struct.pack("<H", len(new_events))
    header += struct.pack("<i", full_events[0].lunation_index)
    header += struct.pack("<H", len(full_events))
    if len(header) != HEADER_SIZE:
        raise ValueError(f"Header is {len(header)} bytes, expected {HEADER_SIZE}")

    body = bytearray()
    for event in new_events:
        body += signed_int24(event.correction)
    for event in full_events:
        body += signed_int24(event.correction)

    output.write_bytes(header + body)


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate compact moon phase correction database.")
    parser.add_argument(
        "--output",
        default="SarosHarmonicJournal/Resources/MoonData/moon_phases.db",
        type=Path,
    )
    parser.add_argument("--data-dir", default="/tmp/skyfield-data", type=Path)
    args = parser.parse_args()

    coverage_start = parse_utc("1900-01-01T00:00:00Z")
    coverage_end = parse_utc("2100-01-01T00:00:00Z")
    search_start = parse_utc("1899-11-01T00:00:00Z")
    search_end = parse_utc("2100-03-01T00:00:00Z")
    reference_date = parse_utc("1992-01-04T00:00:00Z")

    reference_unix, new_events, full_events = generate_events(
        data_dir=args.data_dir,
        coverage_start=coverage_start,
        coverage_end=coverage_end,
        search_start=search_start,
        search_end=search_end,
        reference_date=reference_date,
    )
    write_database(
        args.output,
        coverage_start=coverage_start,
        coverage_end=coverage_end,
        reference_unix=reference_unix,
        new_events=new_events,
        full_events=full_events,
    )

    corrections = [event.correction for event in new_events + full_events]
    print(f"Wrote {args.output}")
    print(f"size={args.output.stat().st_size} bytes")
    print(f"reference_new_moon_unix={reference_unix}")
    print(f"new_count={len(new_events)} full_count={len(full_events)}")
    print(f"first_new_index={new_events[0].lunation_index} first_full_index={full_events[0].lunation_index}")
    print(f"correction_range_seconds={min(corrections)}..{max(corrections)}")


if __name__ == "__main__":
    main()
