#!/usr/bin/env python3
from __future__ import annotations

import argparse
import struct
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

from skyfield import almanac, searchlib
from skyfield.api import Loader


MAGIC = b"MOONP01\0"
VERSION = 3
HEADER_SIZE = 132
SYNODIC_MONTH_DAYS = 29.530588853
ANOMALISTIC_MONTH_DAYS = 27.55454988
DRACONIC_MONTH_DAYS = 27.212220817
SYNODIC_MONTH_MICROS = round(SYNODIC_MONTH_DAYS * 86_400 * 1_000_000)
ANOMALISTIC_MONTH_MICROS = round(ANOMALISTIC_MONTH_DAYS * 86_400 * 1_000_000)
DRACONIC_MONTH_MICROS = round(DRACONIC_MONTH_DAYS * 86_400 * 1_000_000)


@dataclass(frozen=True)
class LunarEvent:
    unix_seconds: int
    phase: int
    cycle_index: int
    correction: int


def parse_utc(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(timezone.utc)


def round_div(numerator: int, denominator: int) -> int:
    if numerator >= 0:
        return (numerator + denominator // 2) // denominator
    return -((-numerator + denominator // 2) // denominator)


def predicted_seconds(reference_unix: int, cycle_index: int, period_micros: int, offset_micros: int = 0) -> int:
    predicted_micros = reference_unix * 1_000_000 + cycle_index * period_micros + offset_micros
    return round_div(predicted_micros, 1_000_000)


def event_index(unix_seconds: int, reference_unix: int, period_micros: int, offset_micros: int = 0) -> int:
    raw = (unix_seconds - reference_unix - offset_micros / 1_000_000) / (period_micros / 1_000_000)
    return round(raw)


def make_event(unix_seconds: int, reference_unix: int, period_micros: int, phase: int = 0, offset_micros: int = 0) -> LunarEvent:
    cycle_index = event_index(unix_seconds, reference_unix, period_micros, offset_micros)
    correction = unix_seconds - predicted_seconds(reference_unix, cycle_index, period_micros, offset_micros)
    return LunarEvent(
        unix_seconds=unix_seconds,
        phase=phase,
        cycle_index=cycle_index,
        correction=correction,
    )


def make_phase_event(unix_seconds: int, reference_unix: int, phase: int) -> LunarEvent:
    offset_micros = 0
    if phase == 2:
        offset_micros = SYNODIC_MONTH_MICROS // 2
    cycle_index = event_index(unix_seconds, reference_unix, SYNODIC_MONTH_MICROS, offset_micros)
    correction = unix_seconds - predicted_seconds(reference_unix, cycle_index, SYNODIC_MONTH_MICROS, offset_micros)
    return LunarEvent(
        unix_seconds=unix_seconds,
        phase=phase,
        cycle_index=cycle_index,
        correction=correction,
    )


def make_dense_events(unix_seconds_values: list[int], reference_unix: int, period_micros: int) -> list[LunarEvent]:
    sorted_values = sorted(unix_seconds_values)
    reference_position = min(
        range(len(sorted_values)),
        key=lambda index: abs(sorted_values[index] - reference_unix),
    )
    first_index = -reference_position
    events: list[LunarEvent] = []
    for offset, unix_seconds in enumerate(sorted_values):
        cycle_index = first_index + offset
        correction = unix_seconds - predicted_seconds(reference_unix, cycle_index, period_micros)
        events.append(LunarEvent(
            unix_seconds=unix_seconds,
            phase=0,
            cycle_index=cycle_index,
            correction=correction,
        ))
    return events


def generate_events(
    *,
    data_dir: Path,
    coverage_start: datetime,
    coverage_end: datetime,
    search_start: datetime,
    search_end: datetime,
    reference_date: datetime,
) -> tuple[
    int,
    list[LunarEvent],
    list[LunarEvent],
    int,
    list[LunarEvent],
    int,
    list[LunarEvent],
    int,
    list[LunarEvent],
    int,
    list[LunarEvent],
]:
    load = Loader(str(data_dir))
    timescale = load.timescale()
    ephemeris = load("de440s.bsp")

    search_t0 = timescale.from_datetime(search_start)
    search_t1 = timescale.from_datetime(search_end)

    reference_unix, new_events, full_events = generate_phase_events(
        ephemeris=ephemeris,
        search_t0=search_t0,
        search_t1=search_t1,
        coverage_start=coverage_start,
        coverage_end=coverage_end,
        reference_date=reference_date,
    )
    reference_apogee_unix, apogee_events, reference_perigee_unix, perigee_events = generate_anomalistic_events(
        ephemeris=ephemeris,
        search_t0=search_t0,
        search_t1=search_t1,
        coverage_start=coverage_start,
        coverage_end=coverage_end,
        reference_date=reference_date,
    )
    reference_ascending_unix, ascending_node_events, reference_descending_unix, descending_node_events = generate_node_events(
        ephemeris=ephemeris,
        search_t0=search_t0,
        search_t1=search_t1,
        coverage_start=coverage_start,
        coverage_end=coverage_end,
        reference_date=reference_date,
    )

    return (
        reference_unix,
        new_events,
        full_events,
        reference_apogee_unix,
        apogee_events,
        reference_perigee_unix,
        perigee_events,
        reference_ascending_unix,
        ascending_node_events,
        reference_descending_unix,
        descending_node_events,
    )


def generate_phase_events(
    *,
    ephemeris,
    search_t0,
    search_t1,
    coverage_start: datetime,
    coverage_end: datetime,
    reference_date: datetime,
) -> tuple[int, list[LunarEvent], list[LunarEvent]]:
    phase_function = almanac.moon_phases(ephemeris)
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
        event = make_phase_event(unix_seconds, reference_unix, phase)
        if phase == 0:
            new_events.append(event)
        else:
            full_events.append(event)

    new_events.sort(key=lambda event: event.cycle_index)
    full_events.sort(key=lambda event: event.cycle_index)

    assert_contiguous(new_events, "new")
    assert_contiguous(full_events, "full")
    assert_brackets_coverage(new_events, coverage_start, coverage_end, "new moon")

    return reference_unix, new_events, full_events


def generate_anomalistic_events(
    *,
    ephemeris,
    search_t0,
    search_t1,
    coverage_start: datetime,
    coverage_end: datetime,
    reference_date: datetime,
) -> tuple[int, list[LunarEvent], list[LunarEvent]]:
    earth = ephemeris["earth"]
    moon = ephemeris["moon"]

    def moon_distance(t):
        return earth.at(t).observe(moon).distance().km

    moon_distance.step_days = 4.0
    apogee_times, apogee_distances = searchlib.find_maxima(search_t0, search_t1, moon_distance, epsilon=1e-5, num=24)
    raw_apogees = dedupe_close_events(
        [
            (round(time.utc_datetime().replace(tzinfo=timezone.utc).timestamp()), float(distance))
            for time, distance in zip(apogee_times, apogee_distances)
        ],
        tolerance_seconds=3_600,
    )
    perigee_times, perigee_distances = searchlib.find_minima(search_t0, search_t1, moon_distance, epsilon=1e-5, num=24)
    raw_perigees = dedupe_close_events(
        [
            (round(time.utc_datetime().replace(tzinfo=timezone.utc).timestamp()), -float(distance))
            for time, distance in zip(perigee_times, perigee_distances)
        ],
        tolerance_seconds=3_600,
    )

    reference_timestamp = round(reference_date.timestamp())
    reference_unix = min(raw_apogees, key=lambda event: abs(event[0] - reference_timestamp))[0]
    reference_perigee_unix = min(raw_perigees, key=lambda event: abs(event[0] - reference_timestamp))[0]
    apogee_events = [
        make_event(unix_seconds, reference_unix, ANOMALISTIC_MONTH_MICROS)
        for unix_seconds, _ in raw_apogees
    ]
    perigee_events = make_dense_events(
        [unix_seconds for unix_seconds, _ in raw_perigees],
        reference_perigee_unix,
        ANOMALISTIC_MONTH_MICROS,
    )
    apogee_events.sort(key=lambda event: event.cycle_index)
    perigee_events.sort(key=lambda event: event.cycle_index)
    assert_contiguous(apogee_events, "apogee")
    assert_contiguous(perigee_events, "perigee")
    assert_brackets_coverage(apogee_events, coverage_start, coverage_end, "apogee")
    assert_brackets_coverage(perigee_events, coverage_start, coverage_end, "perigee")
    return reference_unix, apogee_events, reference_perigee_unix, perigee_events


def generate_node_events(
    *,
    ephemeris,
    search_t0,
    search_t1,
    coverage_start: datetime,
    coverage_end: datetime,
    reference_date: datetime,
) -> tuple[int, list[LunarEvent], int, list[LunarEvent]]:
    node_function = almanac.moon_nodes(ephemeris)
    times, node_states = almanac.find_discrete(search_t0, search_t1, node_function)
    raw_ascending = [
        round(time.utc_datetime().replace(tzinfo=timezone.utc).timestamp())
        for time, is_above_ecliptic in zip(times, node_states)
        if bool(is_above_ecliptic)
    ]
    raw_descending = [
        round(time.utc_datetime().replace(tzinfo=timezone.utc).timestamp())
        for time, is_above_ecliptic in zip(times, node_states)
        if not bool(is_above_ecliptic)
    ]

    reference_timestamp = round(reference_date.timestamp())
    reference_unix = min(raw_ascending, key=lambda unix_seconds: abs(unix_seconds - reference_timestamp))
    reference_descending_unix = min(raw_descending, key=lambda unix_seconds: abs(unix_seconds - reference_timestamp))
    ascending_events = [
        make_event(unix_seconds, reference_unix, DRACONIC_MONTH_MICROS)
        for unix_seconds in raw_ascending
    ]
    descending_events = make_dense_events(raw_descending, reference_descending_unix, DRACONIC_MONTH_MICROS)
    ascending_events.sort(key=lambda event: event.cycle_index)
    descending_events.sort(key=lambda event: event.cycle_index)
    assert_contiguous(ascending_events, "ascending node")
    assert_contiguous(descending_events, "descending node")
    assert_brackets_coverage(ascending_events, coverage_start, coverage_end, "ascending node")
    assert_brackets_coverage(descending_events, coverage_start, coverage_end, "descending node")
    return reference_unix, ascending_events, reference_descending_unix, descending_events


def dedupe_close_events(events: list[tuple[int, float]], tolerance_seconds: int) -> list[tuple[int, float]]:
    deduped: list[tuple[int, float]] = []
    for unix_seconds, score in sorted(events):
        if deduped and unix_seconds - deduped[-1][0] <= tolerance_seconds:
            if score > deduped[-1][1]:
                deduped[-1] = (unix_seconds, score)
        else:
            deduped.append((unix_seconds, score))
    return deduped


def signed_int24(value: int) -> bytes:
    if not -(1 << 23) <= value < (1 << 23):
        raise ValueError(f"Correction {value} does not fit in signed 24-bit storage")
    if value < 0:
        value += 1 << 24
    return bytes((value & 0xFF, (value >> 8) & 0xFF, (value >> 16) & 0xFF))


def assert_contiguous(events: list[LunarEvent], label: str) -> None:
    indices = [event.cycle_index for event in events]
    expected = list(range(indices[0], indices[0] + len(indices)))
    if indices != expected:
        raise ValueError(f"{label} cycle indices are not contiguous")


def assert_brackets_coverage(events: list[LunarEvent], coverage_start: datetime, coverage_end: datetime, label: str) -> None:
    start = round(coverage_start.timestamp())
    end = round(coverage_end.timestamp())
    if not events[0].unix_seconds <= start:
        raise ValueError(f"First {label} does not bracket coverage start")
    if not events[-1].unix_seconds >= end:
        raise ValueError(f"Last {label} does not bracket coverage end")


def write_database(
    output: Path,
    *,
    coverage_start: datetime,
    coverage_end: datetime,
    reference_unix: int,
    new_events: list[LunarEvent],
    full_events: list[LunarEvent],
    reference_apogee_unix: int,
    apogee_events: list[LunarEvent],
    reference_perigee_unix: int,
    perigee_events: list[LunarEvent],
    reference_ascending_unix: int,
    ascending_node_events: list[LunarEvent],
    reference_descending_unix: int,
    descending_node_events: list[LunarEvent],
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
    header += struct.pack("<i", new_events[0].cycle_index)
    header += struct.pack("<H", len(new_events))
    header += struct.pack("<i", full_events[0].cycle_index)
    header += struct.pack("<H", len(full_events))
    header += struct.pack("<q", reference_apogee_unix)
    header += struct.pack("<q", ANOMALISTIC_MONTH_MICROS)
    header += struct.pack("<i", apogee_events[0].cycle_index)
    header += struct.pack("<H", len(apogee_events))
    header += struct.pack("<q", reference_ascending_unix)
    header += struct.pack("<q", DRACONIC_MONTH_MICROS)
    header += struct.pack("<i", ascending_node_events[0].cycle_index)
    header += struct.pack("<H", len(ascending_node_events))
    header += struct.pack("<q", reference_perigee_unix)
    header += struct.pack("<i", perigee_events[0].cycle_index)
    header += struct.pack("<H", len(perigee_events))
    header += struct.pack("<q", reference_descending_unix)
    header += struct.pack("<i", descending_node_events[0].cycle_index)
    header += struct.pack("<H", len(descending_node_events))
    header += struct.pack("<I", 0)
    if len(header) != HEADER_SIZE:
        raise ValueError(f"Header is {len(header)} bytes, expected {HEADER_SIZE}")

    body = bytearray()
    for event in new_events:
        body += signed_int24(event.correction)
    for event in full_events:
        body += signed_int24(event.correction)
    for event in apogee_events:
        body += signed_int24(event.correction)
    for event in ascending_node_events:
        body += signed_int24(event.correction)
    for event in perigee_events:
        body += signed_int24(event.correction)
    for event in descending_node_events:
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

    (
        reference_unix,
        new_events,
        full_events,
        reference_apogee_unix,
        apogee_events,
        reference_perigee_unix,
        perigee_events,
        reference_ascending_unix,
        ascending_node_events,
        reference_descending_unix,
        descending_node_events,
    ) = generate_events(
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
        reference_apogee_unix=reference_apogee_unix,
        apogee_events=apogee_events,
        reference_perigee_unix=reference_perigee_unix,
        perigee_events=perigee_events,
        reference_ascending_unix=reference_ascending_unix,
        ascending_node_events=ascending_node_events,
        reference_descending_unix=reference_descending_unix,
        descending_node_events=descending_node_events,
    )

    corrections = [
        event.correction
        for event in new_events + full_events + apogee_events + ascending_node_events + perigee_events + descending_node_events
    ]
    print(f"Wrote {args.output}")
    print(f"size={args.output.stat().st_size} bytes")
    print(f"reference_new_moon_unix={reference_unix}")
    print(f"reference_apogee_unix={reference_apogee_unix}")
    print(f"reference_perigee_unix={reference_perigee_unix}")
    print(f"reference_ascending_node_unix={reference_ascending_unix}")
    print(f"reference_descending_node_unix={reference_descending_unix}")
    print(f"new_count={len(new_events)} full_count={len(full_events)}")
    print(f"apogee_count={len(apogee_events)} ascending_node_count={len(ascending_node_events)}")
    print(f"perigee_count={len(perigee_events)} descending_node_count={len(descending_node_events)}")
    print(f"first_new_index={new_events[0].cycle_index} first_full_index={full_events[0].cycle_index}")
    print(f"first_apogee_index={apogee_events[0].cycle_index} first_ascending_node_index={ascending_node_events[0].cycle_index}")
    print(f"first_perigee_index={perigee_events[0].cycle_index} first_descending_node_index={descending_node_events[0].cycle_index}")
    print(f"correction_range_seconds={min(corrections)}..{max(corrections)}")


if __name__ == "__main__":
    main()
