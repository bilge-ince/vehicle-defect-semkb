#!/usr/bin/env python3
"""
generate_comments.py — turn NHTSA's own data dictionaries into COMMENT ON statements.

WHERE THIS FITS IN THE DEMO
---------------------------
Step 4 of 4:

    1. data/download.sh              fetch flat files + dictionaries
    2. sql/01_schema.sql             create odi.cmpl / odi.rcl / odi.inv
    3. data/load_nhtsa.py            COPY the data in
    4. scripts/generate_comments.py  <-- you are here

    python3 scripts/generate_comments.py > sql/02_comments.sql

WHY THIS SCRIPT EXISTS AT ALL
-----------------------------
The single most damaging question this demo can get is:

    "Did you write the column comments yourself to make Text-to-SQL work?"

If the answer is "yes, a sales engineer wrote them", the demo proves nothing.
So the comments are mechanically derived from the publisher's own data
dictionary, which is downloaded from a public URL by download.sh. This script is
the whole audit trail. It is short enough to read on stage.

Consequently there is one rule it will not break:

    NEVER FABRICATE A DESCRIPTION.

If a field cannot be parsed, the output contains a literal

    -- UNPARSED: <table>.<column>  (field N, "<NAME>")

line instead of a guess. An unparsed field makes the semantic layer slightly
worse and is instantly visible in the diff. An invented field description makes
the demo dishonest and is invisible. The trade is not close.

DICTIONARY FORMAT — three files, three different layouts
--------------------------------------------------------
There is no schema here; these are hand-maintained text files. Observed
2026-08-07:

  CMPL.txt  CRLF line endings, no tabs. Header "Field#  Name  Type/Size  Description".
            Descriptions wrap across continuation lines indented to the
            description column. Several fields carry an indented code list, e.g.
                21      CMPL_TYPE   CHAR(4)   SOURCE OF COMPLAINT CODE:
                                                CAG  =CONSUMER ACTION GROUP
            Field numbers 40+ are indented one space less than 1-39, so any
            fixed-column parse breaks exactly halfway through the file.
            Descriptions are ALL CAPS.

  RCL.txt   LF line endings. Fields 1-27 are space aligned; fields 28 and 29 use
            literal TAB characters instead. Descriptions are Title Case.

  INV.txt   CRLF line endings, tabs in the header rule line. Field 1 is named
            "NHTSA ACTION NUMBER" — with spaces, so the name column cannot be
            matched as a bare identifier. Descriptions are Sentence case.

The parser therefore expands tabs, normalises line endings, and tries two
layout heuristics per line (strict identifier name, then spaced name) before
giving up and marking the field UNPARSED.
"""

from __future__ import annotations

import argparse
import datetime as _dt
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable, Sequence

# ---------------------------------------------------------------------------
# Physical column names.
#
# These MUST match sql/01_schema.sql exactly and in the same order — the mapping
# from dictionary field number to physical column is positional.
#
# Kept here rather than introspected from the database so the script runs with
# no connection and no dependencies, which matters when regenerating on a plane.
# ---------------------------------------------------------------------------
CMPL_COLUMNS = [
    "cmplid", "odino", "mfr_name", "maketxt", "modeltxt", "yeartxt", "crash",
    "faildate", "fire", "injured", "deaths", "compdesc", "city", "state", "vin",
    "datea", "ldate", "miles", "occurences", "cdescr", "cmpl_type",
    "police_rpt_yn", "purch_dt", "orig_owner_yn", "anti_brakes_yn",
    "cruise_cont_yn", "num_cyls", "drive_train", "fuel_sys", "fuel_type",
    "trans_type", "veh_speed", "dot", "tire_size", "loc_of_tire",
    "tire_fail_type", "orig_equip_yn", "manuf_dt", "seat_type", "restraint_type",
    "dealer_name", "dealer_tel", "dealer_city", "dealer_state", "dealer_zip",
    "prod_type", "repaired_yn", "medical_attn", "vehicles_towed_yn",
    "state_of_incident", "vehicle_operator",
]

RCL_COLUMNS = [
    "record_id", "campno", "maketxt", "modeltxt", "yeartxt", "mfgcampno",
    "compname", "mfgname", "bgman", "endman", "rcltypecd", "potaff", "odate",
    "influenced_by", "mfgtxt", "rcdate", "datea", "rpno", "fmvss", "desc_defect",
    "conequence_defect", "corrective_action", "notes", "rcl_cmpt_id",
    "mfr_comp_name", "mfr_comp_desc", "mfr_comp_ptno", "do_not_drive",
    "park_outside",
]

INV_COLUMNS = [
    # Field 1 is "NHTSA ACTION NUMBER" in the dictionary; NHTSA publishes no SQL
    # identifier for it, so nhtsa_action_number is our choice. See sql/01_schema.sql.
    "nhtsa_action_number", "make", "model", "year", "compname", "mfr_name",
    "odate", "cdate", "campno", "subject", "summary",
]


@dataclass(frozen=True)
class DictSpec:
    key: str
    table: str
    dictionary: str
    url: str
    columns: Sequence[str]
    table_comment: str


SPECS: list[DictSpec] = [
    DictSpec(
        key="cmpl",
        table="odi.cmpl",
        dictionary="CMPL.txt",
        url="https://static.nhtsa.gov/odi/ffdd/cmpl/CMPL.txt",
        columns=CMPL_COLUMNS,
        table_comment=(
            "NHTSA Office of Defects Investigation consumer complaints. "
            "All safety-related defect complaints received by NHTSA since "
            "1 January 1995. One row per complaint per component. "
            "Source: FLAT_CMPL.txt, tab delimited, public domain."
        ),
    ),
    DictSpec(
        key="rcl",
        table="odi.rcl",
        dictionary="RCL.txt",
        url="https://static.nhtsa.gov/odi/ffdd/rcl/RCL.txt",
        columns=RCL_COLUMNS,
        table_comment=(
            "NHTSA Office of Defects Investigation safety recall campaigns. "
            "All safety-related defect and compliance campaigns since 1967. "
            "Source: FLAT_RCL_PRE_2010.txt and FLAT_RCL_POST_2010.txt, "
            "tab delimited, public domain."
        ),
    ),
    DictSpec(
        key="inv",
        table="odi.inv",
        dictionary="INV.txt",
        url="https://static.nhtsa.gov/odi/ffdd/inv/INV.txt",
        columns=INV_COLUMNS,
        table_comment=(
            "NHTSA Office of Defects Investigation defect investigations. "
            "All safety-related defect investigations opened since 1972. "
            "CAMPNO, where present, identifies the recall campaign that resulted "
            "from the investigation and joins to odi.rcl.campno. "
            "Source: FLAT_INV.txt, tab delimited, public domain."
        ),
    ),
]


# ---------------------------------------------------------------------------
# Parsing
# ---------------------------------------------------------------------------

# Heuristic A: a plain identifier name.
#   "1        CMPLID            CHAR(9)       NHTSA'S INTERNAL..."
_FIELD_A = re.compile(
    r"""^\s*(?P<num>\d{1,3})\s+
         (?P<name>[A-Za-z_][A-Za-z0-9_]*)\s{2,}
         (?P<type>[A-Za-z]+\s*\([^)]*\)|[A-Za-z]+)\s{2,}
         (?P<desc>.*)$""",
    re.VERBOSE,
)

# Heuristic B: a name containing spaces (INV field 1, "NHTSA ACTION NUMBER").
# Anchored on the type token so the name cannot swallow the description.
_FIELD_B = re.compile(
    r"""^\s*(?P<num>\d{1,3})\s+
         (?P<name>[A-Za-z][A-Za-z0-9_ ]*?)\s{2,}
         (?P<type>(?:CHAR|VARCHAR|VARCHAR2|NUMBER|NUM|DATE|INTEGER|INT)\s*\([^)]*\)
                  |(?:CHAR|VARCHAR|VARCHAR2|NUMBER|NUM|DATE|INTEGER|INT))\s{2,}
         (?P<desc>.*)$""",
    re.VERBOSE | re.IGNORECASE,
)

# Heuristic C: last resort — number, name, type, and *no* description on this
# line (description is entirely on continuation lines).
_FIELD_C = re.compile(
    r"""^\s*(?P<num>\d{1,3})\s+
         (?P<name>[A-Za-z][A-Za-z0-9_ ]*?)\s{2,}
         (?P<type>[A-Za-z]+\s*\([^)]*\))\s*$""",
    re.VERBOSE,
)

# A code-list continuation line: "  CAG  =CONSUMER ACTION GROUP"
_CODE_LINE = re.compile(r"^\s*(?P<code>[A-Za-z0-9]{1,8})\s*=\s*(?P<meaning>\S.*)$")

# Where the field listing starts. Everything before this is prose and changelog.
_FIELDS_HEADER = re.compile(r"^\s*FIELDS\s*:?\s*$", re.IGNORECASE)
_COLUMN_HEADER = re.compile(r"^\s*Field\s*#", re.IGNORECASE)
_RULE_LINE = re.compile(r"^\s*[-=]{3,}")


@dataclass
class ParsedField:
    num: int
    name: str
    type_: str
    desc_lines: list[str] = field(default_factory=list)

    @property
    def description(self) -> str:
        return join_description(self.desc_lines)


def read_dictionary(path: Path) -> list[str]:
    """Read a dictionary file, normalising the three things that vary.

    * Encoding: UTF-8 first, cp1252 fallback (same policy as the loader).
    * Line endings: CMPL.txt and INV.txt are CRLF, RCL.txt is LF.
    * Tabs: RCL.txt fields 28-29 use tabs where 1-27 use spaces. expandtabs(8)
      turns both into the same space-aligned shape so one parser handles both.
    """
    raw = path.read_bytes()
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        text = raw.decode("cp1252", errors="replace")
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    return [line.expandtabs(8) for line in text.split("\n")]


def parse_fields(lines: Iterable[str]) -> list[ParsedField]:
    """Extract the field listing.

    Continuation handling: any non-blank line that does not itself start a new
    field, and that is indented past the field-number column, is appended to the
    current field's description. That covers both wrapped prose and the indented
    code lists.
    """
    fields: list[ParsedField] = []
    current: ParsedField | None = None
    in_listing = False

    for line in lines:
        stripped = line.strip()

        if not in_listing:
            # Skip the prose/changelog preamble. The listing starts at "FIELDS:"
            # if present, otherwise at the "Field#" column header.
            if _FIELDS_HEADER.match(line) or _COLUMN_HEADER.match(line):
                in_listing = True
            continue

        if not stripped:
            continue
        if _RULE_LINE.match(line) or _COLUMN_HEADER.match(line):
            continue

        m = _FIELD_A.match(line) or _FIELD_B.match(line) or _FIELD_C.match(line)
        if m:
            current = ParsedField(
                num=int(m.group("num")),
                name=m.group("name").strip(),
                type_=re.sub(r"\s+", "", m.group("type")),
            )
            desc = (m.groupdict().get("desc") or "").strip()
            if desc:
                current.desc_lines.append(desc)
            fields.append(current)
            continue

        # Continuation line.
        if current is not None and (len(line) - len(line.lstrip())) >= 4:
            current.desc_lines.append(stripped)

    return fields


def join_description(parts: Sequence[str]) -> str:
    """Join wrapped description lines into one sentence-ish string.

    Code-list lines become "CODE = meaning" entries separated by "; " so the
    structure survives; ordinary wrapped prose is joined with a space.
    """
    tagged: list[tuple[str, str]] = []
    for part in parts:
        code = _CODE_LINE.match(part)
        if code:
            meaning = code.group("meaning").strip()
            tagged.append(("code", f"{code.group('code').upper()} = {meaning}"))
        else:
            tagged.append(("prose", part.strip()))

    text = ""
    for kind, part in tagged:
        if not text:
            text = part
        elif kind == "code":
            # The first code follows the introducing line, which ends in ":" or
            # (CMPL field 40) ";" — so it only needs a space. Subsequent codes are
            # separated from each other by "; ".
            text += " " if text.endswith((":", ";")) else "; "
            text += part
        else:
            text += " " + part
    return re.sub(r"\s+", " ", text).strip()


# ---------------------------------------------------------------------------
# Readability normalisation
#
# CMPL.txt descriptions are ALL CAPS, which embeds and reads poorly. We
# lowercase them and re-capitalise sentences, while preserving anything that is
# plausibly an identifier, code or acronym. RCL.txt and INV.txt are already
# mixed case and are left alone. Case is the only thing that changes here —
# never wording, so the description remains the publisher's.
# ---------------------------------------------------------------------------

# Only genuine acronyms and cryptic identifiers belong in PRESERVE. Short *code*
# tokens from the dictionaries' code lists (A, B, C, IN, TD, FI, RC ...)
# deliberately do NOT, because they collide with ordinary English words —
# leaving "A" in this set produced "data for A given record" and "involved IN A
# crash". Code tokens are protected structurally by _CODE_KEY instead, which is
# both safer and self-maintaining.
PRESERVE = {
    # Organisations, standards, jargon
    "NHTSA", "ODI", "DOT", "VIN", "FOIA", "FMVSS", "OVSC", "MFR", "EWR", "VOQ",
    "USA", "U.S.", "U.S.C.", "ID", "PDF", "YYYYMMDD", "N/A", "TL",
    # Physical column names that the dictionaries cross-reference inside prose,
    # e.g. CMPL field 2: "...IF LDATE IS PRIOR TO DEC 15, 2002...".
    "LDATE", "DATEA", "FAILDATE", "CAMPNO", "CMPLID", "ODINO",
    # Inline bracketed enumerations that are not "CODE =" lists, e.g.
    # DRIVE_TRAIN "[AWD,4WD,FWD,RWD]" and TRANS_TYPE "[AUTO, MAN]".
    "AWD", "4WD", "FWD", "RWD", "AUTO", "MAN", "CNG", "LPG",
    # Y/N flag values, which appear quoted in most flag descriptions.
    "Y", "N",
}

# Month abbreviations are re-capitalised only when followed by a day number, so
# that "MAY BE REPEATED" stays "may be repeated" rather than becoming "May be
# repeated". Context, not a word list — "MAY" is both a month and a modal verb.
_MONTH_DATE = re.compile(
    r"\b(jan|feb|mar|apr|may|jun|jul|aug|sept?|oct|nov|dec)(\.?)(\s+\d)",
    re.IGNORECASE,
)

# A code-list key as emitted by join_description(): "CAG = consumer action group".
# Matching on the "= " that follows means we never have to enumerate the codes.
_CODE_KEY = re.compile(r"(?<![A-Za-z0-9])([A-Z0-9][A-Z0-9/]{0,7}) = ")


def is_allcaps(text: str) -> bool:
    letters = [c for c in text if c.isalpha()]
    if not letters:
        return False
    return sum(c.isupper() for c in letters) / len(letters) > 0.9


def sentence_case(text: str) -> str:
    """Lowercase ALL-CAPS prose, preserving identifiers, acronyms and codes.

    Only CMPL.txt is ALL CAPS; RCL.txt and INV.txt are already mixed case and are
    returned untouched. This changes letter case only — never wording — so the
    description stays the publisher's.
    """
    if not is_allcaps(text):
        return text

    # 1. Stash code-list keys so the token pass cannot lowercase them.
    stash: list[str] = []

    def _stash(m: re.Match) -> str:
        stash.append(m.group(1))
        return f"\x00{len(stash) - 1}\x00 = "

    text = _CODE_KEY.sub(_stash, text)

    # 2. Lowercase every token that is not an acronym, month or identifier.
    def fix(token: str) -> str:
        core = token.strip(".,;:()[]'\"")
        if not core or core.startswith("\x00"):
            return token
        upper = core.upper()
        # Possessives: "NHTSA'S" -> "NHTSA's", not "Nhtsa's".
        if upper.endswith("'S") and upper[:-2] in PRESERVE:
            return token.replace(core, core[:-2] + "'s")
        if upper in PRESERVE:
            return token
        # Slash-joined acronyms, e.g. "CNG/LPG" in the FUEL_TYPE code list.
        if "/" in upper and all(p in PRESERVE for p in upper.split("/") if p):
            return token
        # Anything with an underscore or a digit is an identifier or a code.
        if "_" in core or any(ch.isdigit() for ch in core):
            return token
        return token.lower()

    lowered = " ".join(fix(t) for t in text.split(" "))

    # 3. Capitalise the first letter, and the first letter after ". ".
    #    Explicitly NOT after ":" or ";" — those introduce code lists, and
    #    capitalising there would look like shouting.
    result = lowered
    for i, ch in enumerate(result):
        if ch.isalpha():
            result = result[:i] + ch.upper() + result[i + 1:]
            break
    result = re.sub(
        r"([.!?]\s+)([a-z])", lambda m: m.group(1) + m.group(2).upper(), result
    )
    result = _MONTH_DATE.sub(
        lambda m: m.group(1).capitalize() + m.group(2) + m.group(3), result
    )

    # 4. Restore the code-list keys.
    return re.sub(r"\x00(\d+)\x00", lambda m: stash[int(m.group(1))], result)


def sql_literal(text: str) -> str:
    return "'" + text.replace("'", "''") + "'"


# ---------------------------------------------------------------------------
# Emission
# ---------------------------------------------------------------------------
@dataclass
class Tally:
    parsed: int = 0
    unparsed: int = 0
    unmapped: int = 0
    notes: list[str] = field(default_factory=list)


def emit_table(spec: DictSpec, raw_dir: Path, tally: Tally, out) -> None:
    path = raw_dir / spec.dictionary
    print(file=out)
    print("-" * 78, file=out)
    print(f"-- {spec.table}", file=out)
    print(f"-- dictionary: {spec.dictionary}", file=out)
    print(f"-- source:     {spec.url}", file=out)
    print("-" * 78, file=out)

    if not path.is_file():
        msg = f"{spec.dictionary} not found in {raw_dir} — run data/download.sh"
        print(f"-- SKIPPED: {msg}", file=out)
        for col in spec.columns:
            print(f"-- UNPARSED: {spec.table}.{col}  (dictionary missing)", file=out)
            tally.unparsed += 1
        tally.notes.append(f"{spec.table}: {msg}")
        return

    fields = parse_fields(read_dictionary(path))
    by_num = {f.num: f for f in fields}

    print(
        f"COMMENT ON TABLE {spec.table} IS {sql_literal(spec.table_comment)};",
        file=out,
    )
    print(file=out)

    if len(fields) != len(spec.columns):
        note = (
            f"{spec.table}: dictionary lists {len(fields)} fields but "
            f"sql/01_schema.sql defines {len(spec.columns)} columns"
        )
        tally.notes.append(note)
        print(f"-- WARNING: {note}", file=out)
        print("-- The file format may have changed. Re-read the dictionary and", file=out)
        print("-- update sql/01_schema.sql before trusting these comments.", file=out)
        print(file=out)

    for idx, col in enumerate(spec.columns, start=1):
        pf = by_num.get(idx)
        if pf is None:
            print(
                f"-- UNPARSED: {spec.table}.{col}  "
                f"(field {idx} absent from {spec.dictionary})",
                file=out,
            )
            tally.unparsed += 1
            continue

        desc = pf.description.strip()
        if not desc:
            print(
                f"-- UNPARSED: {spec.table}.{col}  "
                f'(field {idx}, "{pf.name}" — no description text found)',
                file=out,
            )
            tally.unparsed += 1
            continue

        # Sanity: the dictionary name should match the physical column, allowing
        # for the INV "NHTSA ACTION NUMBER" case. Mismatches are surfaced, not
        # silently accepted — a shifted dictionary would attach the wrong text
        # to the wrong column, which is exactly the failure this demo is about.
        dict_col = pf.name.strip().lower().replace(" ", "_")
        if dict_col != col:
            tally.unmapped += 1
            print(
                f'-- NOTE: field {idx} is named "{pf.name}" in {spec.dictionary} '
                f"but the physical column is {col}",
                file=out,
            )

        text = sentence_case(desc)
        # Append the source type/size — genuinely useful grounding for the model
        # and unambiguously publisher-supplied.
        if pf.type_:
            text = f"{text} [{pf.type_}]"

        print(
            f"COMMENT ON COLUMN {spec.table}.{col} IS {sql_literal(text)};",
            file=out,
        )
        tally.parsed += 1


def banner(out, raw_dir: Path) -> None:
    today = _dt.date.today().isoformat()
    print("-- " + "=" * 74, file=out)
    print("-- 02_comments.sql — GENERATED FILE. DO NOT HAND-EDIT.", file=out)
    print("-- " + "=" * 74, file=out)
    print("--", file=out)
    print("-- Generated by : scripts/generate_comments.py", file=out)
    print(f"-- Generated on : {today}", file=out)
    print(f"-- Input dir    : {raw_dir}", file=out)
    print("--", file=out)
    print("-- Source dictionaries (public domain, US DOT / NHTSA):", file=out)
    for spec in SPECS:
        print(f"--   {spec.table:<10} {spec.url}", file=out)
    print("--", file=out)
    print("-- Every description below is derived mechanically from the publisher's", file=out)
    print("-- own data dictionary. Nothing here was written by hand to make the", file=out)
    print("-- demo work. Where a field could not be parsed, the line reads", file=out)
    print("--     -- UNPARSED: <table>.<column>", file=out)
    print("-- rather than carrying an invented description.", file=out)
    print("--", file=out)
    print("-- Regenerate with:", file=out)
    print("--   python3 scripts/generate_comments.py > sql/02_comments.sql", file=out)
    print("-- " + "=" * 74, file=out)
    print(file=out)
    print("\\set ON_ERROR_STOP on", file=out)


def main(argv: Sequence[str] | None = None) -> int:
    p = argparse.ArgumentParser(
        description="Generate COMMENT ON statements from NHTSA data dictionaries.",
    )
    p.add_argument(
        "--raw-dir",
        default="data/raw",
        help="Directory containing CMPL.txt, RCL.txt, INV.txt (default: data/raw)",
    )
    p.add_argument(
        "--tables",
        default="cmpl,rcl,inv",
        help="Comma-separated subset of cmpl,rcl,inv (default: all)",
    )
    args = p.parse_args(argv)

    raw_dir = Path(args.raw_dir).expanduser()
    if not raw_dir.is_absolute():
        raw_dir = (Path(__file__).resolve().parent.parent / raw_dir).resolve()

    keys = [k.strip().lower() for k in args.tables.split(",") if k.strip()]
    specs = [s for s in SPECS if s.key in keys]
    if not specs:
        print(f"ERROR: no known tables in --tables {args.tables!r}", file=sys.stderr)
        return 2

    out = sys.stdout
    tally = Tally()
    banner(out, raw_dir)
    for spec in specs:
        emit_table(spec, raw_dir, tally, out)
    print(file=out)

    # ---- stderr summary: this is what the presenter actually reads ----
    total = tally.parsed + tally.unparsed
    print("=" * 70, file=sys.stderr)
    print(" generate_comments.py summary", file=sys.stderr)
    print("=" * 70, file=sys.stderr)
    print(f"  fields parsed   : {tally.parsed}", file=sys.stderr)
    print(f"  fields UNPARSED : {tally.unparsed}", file=sys.stderr)
    print(f"  total columns   : {total}", file=sys.stderr)
    if tally.unmapped:
        print(
            f"  name mismatches : {tally.unmapped} "
            "(dictionary name != physical column; see -- NOTE lines)",
            file=sys.stderr,
        )
    for note in tally.notes:
        print(f"  WARNING: {note}", file=sys.stderr)
    if tally.unparsed:
        print(file=sys.stderr)
        print(
            "  Some fields have no comment. Grep the output for '-- UNPARSED:'\n"
            "  and decide per field. Do NOT invent text: either fix the parser or\n"
            "  leave the column undocumented and say so if it comes up.",
            file=sys.stderr,
        )
    print("=" * 70, file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
