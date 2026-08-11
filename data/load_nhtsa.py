#!/usr/bin/env python3
"""
load_nhtsa.py — load the NHTSA ODI flat files into Postgres for the Mercedes demo.

WHERE THIS FITS IN THE DEMO
---------------------------
Step 3 of 4:

    1. data/download.sh              fetch flat files + dictionaries
    2. sql/01_schema.sql             create odi.cmpl / odi.rcl / odi.inv (all TEXT)
    3. data/load_nhtsa.py            <-- you are here
    4. scripts/generate_comments.py  dictionaries -> sql/02_comments.sql

Everything lands as TEXT. The schema DDL is responsible for typing (and, in this
demo, deliberately does not type anything). We never cast during COPY: a cast
failure two thirds of the way through a 2.2 M-row load, forty minutes before you
present, is not a situation worth engineering for when TEXT costs nothing.

DEFENSIVE BEHAVIOUR — the reason this file is longer than it looks like it needs
to be. Each of these is a real failure mode that would surface as a wrong answer
on stage rather than an error:

  * FIELD COUNT DRIFT. NHTSA adds columns without notice — complaints went from
    49 to 51 fields on 2026-04-30, recalls from 27 to 29 in May 2025. A file with
    more fields than the table silently shifts every value one column left, so
    `compdesc` would contain city names and the demo would produce confident
    nonsense. We check the first data line against the expected count and refuse
    to load on mismatch, with instructions.

  * ENCODING. Historic guidance says these files are latin-1/cp1252. As of
    2026-08-07 that is no longer true: all four flat files are 100% valid UTF-8
    (measured line-by-line across every row, not sampled). Decoding UTF-8 content
    as cp1252 turns a curly quote into 'a-hat-euro-oe' mojibake, which then gets
    embedded and retrieved by the semantic layer. Default is --encoding auto:
    try UTF-8 per line, fall back to cp1252. Correct under both regimes.

  * BLANK LINES. FLAT_RCL_PRE_2010.txt contains 5 lines that are a bare CR.
    Skipped, and counted, not treated as a schema mismatch.

  * DATE RANGE. Printed at the end for every table. A previous version of this
    demo asked the agent about a year with no data and returned an empty result
    live. Know your range before you present.

Usage:
    python3 data/load_nhtsa.py --dsn "$DEMO_DSN"
    python3 data/load_nhtsa.py --dsn "$DEMO_DSN" --subset 250000
    python3 data/load_nhtsa.py --dsn "$DEMO_DSN" --tables cmpl,rcl

Requires: Python 3.9+, psycopg (v3).   pip install 'psycopg[binary]'
"""

from __future__ import annotations

import argparse
import csv
import io
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable, Iterator, Sequence

try:
    import psycopg
except ImportError:  # pragma: no cover
    sys.exit(
        "ERROR: psycopg (v3) is not installed.\n"
        "       pip install 'psycopg[binary]'\n"
        "       (psycopg2 will NOT work — this script uses the v3 cursor.copy() API.)"
    )


# ---------------------------------------------------------------------------
# Table definitions.
#
# `expected_fields` and the column order in sql/01_schema.sql are two halves of
# the same contract. If you change one, change the other, or the positional COPY
# will misalign.
#
# Verified 2026-08-07 against the published dictionaries AND by counting the
# fields of every line of every flat file.
# ---------------------------------------------------------------------------
@dataclass(frozen=True)
class TableSpec:
    key: str
    table: str
    expected_fields: int
    sources: Sequence[str]          # candidate filenames in --raw-dir, in load order
    dictionary: str                 # dictionary filename, for the error message
    date_col_index: int             # 0-based index of the date column to report
    date_col_name: str

    @property
    def optional_sources(self) -> bool:
        return len(self.sources) > 1


TABLES: dict[str, TableSpec] = {
    "cmpl": TableSpec(
        key="cmpl",
        table="odi.cmpl",
        expected_fields=51,         # was 49 before 2026-04-30; see module docstring
        sources=("FLAT_CMPL.txt",),
        dictionary="CMPL.txt",
        date_col_index=15,          # field 16, DATEA
        date_col_name="datea",
    ),
    "rcl": TableSpec(
        key="rcl",
        table="odi.rcl",
        expected_fields=29,         # was 27 before May 2025
        # Recalls are published split at 2010. There is no combined FLAT_RCL.zip.
        # Load whichever parts are present; POST_2010 alone is fine for the demo.
        sources=("FLAT_RCL_PRE_2010.txt", "FLAT_RCL_POST_2010.txt", "FLAT_RCL.txt"),
        dictionary="RCL.txt",
        date_col_index=16,          # field 17, DATEA
        date_col_name="datea",
    ),
    "inv": TableSpec(
        key="inv",
        table="odi.inv",
        expected_fields=11,
        sources=("FLAT_INV.txt",),
        dictionary="INV.txt",
        date_col_index=6,           # field 7, ODATE (inv has no datea)
        date_col_name="odate",
    ),
}


# ---------------------------------------------------------------------------
# Decoding
# ---------------------------------------------------------------------------
def decode_line(raw: bytes, mode: str) -> tuple[str, bool]:
    """Decode one raw line. Returns (text, used_fallback).

    mode 'auto' is the default and the only one you should need: UTF-8 first,
    cp1252 second. As of 2026-08-07 every line of every ODI flat file is valid
    UTF-8, so the fallback never fires — but it costs nothing and protects
    against NHTSA reverting to their historic cp1252 output.

    Note cp1252 has five *undefined* byte values (0x81 0x8D 0x8F 0x90 0x9D), so
    strict cp1252 can itself raise. latin-1 is the last resort because it maps
    all 256 bytes and cannot fail — at the cost of mojibake.
    """
    if mode == "auto":
        try:
            return raw.decode("utf-8"), False
        except UnicodeDecodeError:
            pass
        try:
            return raw.decode("cp1252"), True
        except UnicodeDecodeError:
            return raw.decode("latin-1"), True
    return raw.decode(mode, errors="replace"), False


def iter_lines(path: Path, mode: str, stats: "LoadStats") -> Iterator[str]:
    """Yield decoded, newline-normalised lines.

    We split on b'\\n' only and strip a trailing b'\\r'. This is safe because we
    verified that no record in any ODI flat file contains an embedded CR or LF —
    every line is exactly one record. Complaints and investigations are LF
    terminated; both recalls parts are CRLF terminated.

    Blank lines (the 5 bare-CR lines in FLAT_RCL_PRE_2010.txt) are dropped here
    so they never reach the field-count check.
    """
    with path.open("rb") as fh:
        for raw in fh:
            raw = raw.rstrip(b"\n")
            if raw.endswith(b"\r"):
                raw = raw[:-1]
            if not raw.strip():
                stats.blank_lines += 1
                continue
            text, fell_back = decode_line(raw, mode)
            if fell_back:
                stats.encoding_fallback_lines += 1
            yield text


def iter_rows(path: Path, mode: str, stats: "LoadStats") -> Iterator[list[str]]:
    """Parse rows out of a flat file.

    QUOTE_NONE is mandatory. The source contains bare double quotes inside free
    text (12,138 lines in the first 400 K of FLAT_CMPL.txt alone) which are NOT
    RFC4180-escaped. With default quoting, csv would swallow delimiters and
    produce short rows.

    csv.reader accepts any iterable of strings, so we feed it our own
    newline-normalised generator rather than a file object. That keeps csv from
    treating an embedded CR as a record separator.
    """
    yield from csv.reader(
        iter_lines(path, mode, stats),
        delimiter="\t",
        quoting=csv.QUOTE_NONE,
    )


# ---------------------------------------------------------------------------
# COPY text-format encoding
# ---------------------------------------------------------------------------
_COPY_ESCAPES = str.maketrans(
    {"\\": "\\\\", "\t": "\\t", "\n": "\\n", "\r": "\\r"}
)


def to_copy_line(row: Sequence[str]) -> str:
    """Render one row in Postgres COPY TEXT format.

    Default NULL marker is \\N, so an empty field becomes an empty string, not
    NULL — which is what we want: the source uses empty strings, and the demo's
    whole premise is that the physical data is untidy.
    """
    return "\t".join(v.translate(_COPY_ESCAPES) for v in row) + "\n"


# ---------------------------------------------------------------------------
# Stats
# ---------------------------------------------------------------------------
@dataclass
class LoadStats:
    rows_read: int = 0
    rows_written: int = 0
    blank_lines: int = 0
    encoding_fallback_lines: int = 0
    bad_field_count_lines: int = 0
    files: list[str] = field(default_factory=list)


class FieldCountError(RuntimeError):
    pass


def check_field_count(
    spec: TableSpec, path: Path, actual: int, line_no: int, raw_dir: Path
) -> None:
    if actual == spec.expected_fields:
        return
    raise FieldCountError(
        f"""
================================================================================
 FIELD COUNT MISMATCH — REFUSING TO LOAD
================================================================================
 File            : {path}
 Line            : {line_no}
 Fields found    : {actual}
 Fields expected : {spec.expected_fields}   (target table {spec.table})

 This almost certainly means NHTSA changed the file format. They do this without
 announcement — complaints went 49 -> 51 fields on 2026-04-30, recalls 27 -> 29
 in May 2025.

 DO NOT force this load. A field count mismatch does not fail loudly at query
 time: it shifts every value one column sideways, so `compdesc` fills up with
 city names and the demo answers questions confidently and wrongly.

 WHAT TO DO
 ----------
 1. Re-read the publisher's data dictionary. For this table that is:

        {raw_dir / spec.dictionary}
        https://static.nhtsa.gov/odi/ffdd/{spec.key}/{spec.dictionary}

    Look at the "Change log" section at the top — new fields are listed there
    with the date they were added.

 2. Update the column list for {spec.table} in sql/01_schema.sql to match the
    dictionary exactly, in the dictionary's field order. Keep the publisher's
    names, including their misspellings.

 3. Update TABLES["{spec.key}"].expected_fields in this file to {actual}.

 4. Re-run sql/01_schema.sql (it DROPs and recreates), then re-run this loader,
    then regenerate sql/02_comments.sql with scripts/generate_comments.py so the
    semantic layer describes the new columns too.

 If you are certain the file is fine and only want to eyeball it:

        head -1 "{path}" | awk -F'\\t' '{{print NF}}'
================================================================================
"""
    )


# ---------------------------------------------------------------------------
# Subset selection
# ---------------------------------------------------------------------------
def find_date_cutoff(
    spec: TableSpec, paths: Sequence[Path], subset: int, mode: str
) -> tuple[str, int]:
    """Find the DATEA value that bounds the `subset` most recent rows.

    Two-pass rather than sorting 2.2 M rows in memory. Pass 1 histograms the date
    column (~11 K distinct dates — trivially small). Pass 2, done by the caller,
    streams the file again and emits rows at or after the cutoff.

    Returns (cutoff_date, quota_at_cutoff) where quota_at_cutoff is how many rows
    of exactly that date to take, so the total lands on `subset` rather than
    overshooting by a whole day.

    Rows with an unparseable date sort last (they are excluded from the subset).
    """
    hist: dict[str, int] = {}
    scratch = LoadStats()
    for path in paths:
        for row in iter_rows(path, mode, scratch):
            if len(row) != spec.expected_fields:
                continue
            d = row[spec.date_col_index].strip()
            if len(d) == 8 and d.isdigit():
                hist[d] = hist.get(d, 0) + 1

    if not hist:
        raise RuntimeError(
            f"--subset was requested but no parseable {spec.date_col_name} values "
            f"were found in {[p.name for p in paths]}. Refusing to guess."
        )

    running = 0
    for date in sorted(hist, reverse=True):
        n = hist[date]
        if running + n >= subset:
            return date, subset - running
        running += n

    # subset larger than the file: take everything.
    oldest = min(hist)
    return oldest, hist[oldest]


# ---------------------------------------------------------------------------
# Loading
# ---------------------------------------------------------------------------
def resolve_sources(spec: TableSpec, raw_dir: Path) -> list[Path]:
    found = [raw_dir / name for name in spec.sources if (raw_dir / name).is_file()]
    if not found:
        candidates = "\n    ".join(str(raw_dir / n) for n in spec.sources)
        raise FileNotFoundError(
            f"No source file found for {spec.table}. Looked for:\n    {candidates}\n"
            f"Run data/download.sh first."
        )
    return found


def load_table(
    conn: "psycopg.Connection",
    spec: TableSpec,
    raw_dir: Path,
    subset: int,
    mode: str,
    batch_bytes: int,
) -> LoadStats:
    paths = resolve_sources(spec, raw_dir)
    stats = LoadStats(files=[p.name for p in paths])

    print(f"\n--- {spec.table} " + "-" * (60 - len(spec.table)))
    for p in paths:
        print(f"  source          : {p.name}  ({p.stat().st_size:,} bytes)")
    print(f"  expected fields : {spec.expected_fields}")

    cutoff: str | None = None
    quota_at_cutoff = 0
    if subset and spec.key == "cmpl":
        print(f"  subset          : {subset:,} most recent rows by {spec.date_col_name}")
        print("                    (pass 1/2: scanning date column...)", flush=True)
        t0 = time.time()
        cutoff, quota_at_cutoff = find_date_cutoff(spec, paths, subset, mode)
        print(
            f"                    cutoff {spec.date_col_name} >= {cutoff} "
            f"({time.time() - t0:.1f}s)"
        )
    elif subset:
        # Recalls (326 K) and investigations (154 K) fit on any laptop whole, and
        # subsetting them would silently break joins from the complaints subset.
        print(f"  subset          : ignored for {spec.table} (small table, loaded whole)")

    # Idempotent: wipe before loading so a re-run does not double the data.
    with conn.cursor() as cur:
        cur.execute(f"TRUNCATE TABLE {spec.table}")

    t0 = time.time()
    taken_at_cutoff = 0
    checked_first_line = False

    with conn.cursor() as cur:
        with cur.copy(f"COPY {spec.table} FROM STDIN") as copy:
            buf = io.StringIO()
            buf_len = 0

            for path in paths:
                line_no = 0
                for row in iter_rows(path, mode, stats):
                    line_no += 1
                    stats.rows_read += 1

                    # Hard check on the first data line of each file. This is the
                    # guard that stops a silent column shift from poisoning the demo.
                    if not checked_first_line or line_no == 1:
                        check_field_count(spec, path, len(row), line_no, raw_dir)
                        checked_first_line = True

                    if len(row) != spec.expected_fields:
                        # Past line 1 we still refuse rather than tolerate — a
                        # mid-file change means the file is not what we think.
                        stats.bad_field_count_lines += 1
                        check_field_count(spec, path, len(row), line_no, raw_dir)

                    if cutoff is not None:
                        d = row[spec.date_col_index].strip()
                        if not (len(d) == 8 and d.isdigit() and d >= cutoff):
                            continue
                        if d == cutoff:
                            if taken_at_cutoff >= quota_at_cutoff:
                                continue
                            taken_at_cutoff += 1

                    line = to_copy_line(row)
                    buf.write(line)
                    buf_len += len(line)
                    stats.rows_written += 1

                    if buf_len >= batch_bytes:
                        copy.write(buf.getvalue())
                        buf = io.StringIO()
                        buf_len = 0

                    if stats.rows_written and stats.rows_written % 100_000 == 0:
                        rate = stats.rows_written / max(time.time() - t0, 1e-6)
                        print(
                            f"    {stats.rows_written:>10,} rows written "
                            f"({rate:,.0f}/s)",
                            flush=True,
                        )

            if buf_len:
                copy.write(buf.getvalue())

    conn.commit()
    elapsed = time.time() - t0
    print(
        f"  loaded          : {stats.rows_written:,} rows in {elapsed:.1f}s "
        f"({stats.rows_written / max(elapsed, 1e-6):,.0f}/s)"
    )
    if stats.blank_lines:
        print(f"  blank lines     : {stats.blank_lines} skipped (expected for recalls)")
    if stats.encoding_fallback_lines:
        print(
            f"  encoding        : {stats.encoding_fallback_lines:,} lines were NOT "
            f"valid UTF-8 and fell back to cp1252"
        )
    return stats


# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------
def report(conn: "psycopg.Connection", specs: Iterable[TableSpec]) -> None:
    print("\n" + "=" * 78)
    print(" LOAD SUMMARY — check the date range before you present")
    print("=" * 78)
    print(f" {'TABLE':<12} {'ROWS':>12}  {'DATE COL':<10} {'MIN':<10} {'MAX':<10}")
    print("-" * 78)

    for spec in specs:
        col = spec.date_col_name
        with conn.cursor() as cur:
            cur.execute(
                f"""
                SELECT count(*),
                       min(NULLIF(btrim({col}), '')),
                       max(NULLIF(btrim({col}), ''))
                FROM {spec.table}
                """
            )
            n, lo, hi = cur.fetchone()
        print(f" {spec.table:<12} {n:>12,}  {col:<10} {lo or '-':<10} {hi or '-':<10}")

    print("-" * 78)
    print(
        " Dates are YYYYMMDD strings, not DATEs — that is intentional, this is the\n"
        " raw landing schema. The demo's point is that nothing here is friendly.\n"
        "\n"
        " PRESENTER CHECK: every scripted question must fall inside the range above.\n"
        " Asking about a year with no rows returns an empty result on stage and\n"
        " reads as a broken demo. This has happened before."
    )
    print("=" * 78)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Load NHTSA ODI flat files into Postgres (schema odi).",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Examples:\n"
            "  %(prog)s --dsn \"$DEMO_DSN\"\n"
            "  %(prog)s --dsn \"$DEMO_DSN\" --subset 250000\n"
            "  %(prog)s --dsn \"$DEMO_DSN\" --tables cmpl --subset 50000\n"
        ),
    )
    p.add_argument("--dsn", required=True, help="Postgres connection string (required)")
    p.add_argument(
        "--subset",
        type=int,
        default=0,
        metavar="N",
        help="Load only the N most recent complaints by DATEA (0 = all, default). "
        "Recalls and investigations are always loaded whole — they are small, "
        "and subsetting them would break joins from the complaints subset.",
    )
    p.add_argument(
        "--tables",
        default="cmpl,rcl,inv",
        help="Comma-separated subset of cmpl,rcl,inv (default: all)",
    )
    p.add_argument(
        "--raw-dir",
        default="data/raw",
        help="Directory containing the unzipped flat files (default: data/raw)",
    )
    p.add_argument(
        "--encoding",
        default="auto",
        choices=["auto", "utf-8", "cp1252", "latin-1"],
        help="auto (default) tries UTF-8 then falls back to cp1252 per line. "
        "As of 2026-08-07 all ODI flat files are valid UTF-8; older guidance "
        "saying cp1252 is out of date. Override only if you know why.",
    )
    p.add_argument(
        "--batch-bytes",
        type=int,
        default=8 * 1024 * 1024,
        help="COPY buffer size in bytes (default 8 MiB)",
    )
    return p.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)

    raw_dir = Path(args.raw_dir).expanduser()
    if not raw_dir.is_absolute():
        # Resolve relative to the repo root (this file lives in <root>/data/).
        raw_dir = (Path(__file__).resolve().parent.parent / raw_dir).resolve()
    if not raw_dir.is_dir():
        print(f"ERROR: --raw-dir does not exist: {raw_dir}", file=sys.stderr)
        print("       Run data/download.sh first.", file=sys.stderr)
        return 2

    keys = [k.strip().lower() for k in args.tables.split(",") if k.strip()]
    unknown = [k for k in keys if k not in TABLES]
    if unknown:
        print(
            f"ERROR: unknown table(s) {unknown}. Valid: {', '.join(TABLES)}",
            file=sys.stderr,
        )
        return 2
    specs = [TABLES[k] for k in keys]

    print("NHTSA ODI loader")
    print(f"  raw dir  : {raw_dir}")
    print(f"  tables   : {', '.join(s.table for s in specs)}")
    print(f"  encoding : {args.encoding}")
    print(f"  subset   : {args.subset or 'none (full load)'}")

    try:
        with psycopg.connect(args.dsn, autocommit=False) as conn:
            for spec in specs:
                load_table(
                    conn,
                    spec,
                    raw_dir,
                    args.subset,
                    args.encoding,
                    args.batch_bytes,
                )
            report(conn, specs)
    except FieldCountError as exc:
        print(str(exc), file=sys.stderr)
        return 3
    except FileNotFoundError as exc:
        print(f"\nERROR: {exc}", file=sys.stderr)
        return 2
    except psycopg.Error as exc:
        print(f"\nERROR: database error: {exc}", file=sys.stderr)
        print(
            "       If this is 'relation odi.cmpl does not exist', run\n"
            "         psql \"$DSN\" -f sql/01_schema.sql\n"
            "       first.",
            file=sys.stderr,
        )
        return 4

    print("\nNext: python3 scripts/generate_comments.py > sql/02_comments.sql")
    return 0


if __name__ == "__main__":
    sys.exit(main())
