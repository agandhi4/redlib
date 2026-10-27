"""CVSS scores from vector strings, stdlib only, for metrics/vuln.py's severity_of.

v3.0 and v3.1: the base score by the specification's formulas (CVSS v3.1 section 7.1; temporal
and environmental metrics in the vector are ignored, they only adjust the base). Both use 3.1's
Roundup (Appendix A, through integers). 3.0's ceil(x * 10) / 10 can lift an exact score a tenth
on float error, but on base scores it never does: FIRST's cvsscalc30.js and cvsscalc31.js agree
on all 2592 base vectors, so 3.0 needs no arithmetic of its own (the 3.0/3.1 changes are in the
environmental formulas, which a base score does not use).
v4.0: the specification's one score of the vector as written (section 8: the MacroVector of
six equivalence classes looked up, then interpolated by the vector's severity distance to the
MacroVector's highest vectors). Threat and environmental metrics take part as in the spec, X or
absent being the worst case; supplemental metrics never do. The lookup table, the highest
vectors and the depths are FIRST's reference calculator's (github.com/FIRSTdotorg/
cvss-v4-calculator, cvss_lookup.js, max_composed.js, max_severity.js; BSD-2-Clause), and the
arithmetic is its cvss_score.js step for step, float error included (see _V4). Checked against
that code (and FIRST's cvsscalc30.js/cvsscalc31.js for v3) on every v3 and v4 base vector plus
20000 v4 vectors with threat and environmental metrics: tests/cvss_test.py pins a sample.
"""

from __future__ import annotations

import math
from collections.abc import Callable, Container, Mapping
from itertools import product


def score(vector: str) -> float:
    """The score of a `CVSS:3.0/`, `CVSS:3.1/` or `CVSS:4.0/` vector. ValueError for anything
    else, a base metric missing or out of range, or a metric given twice."""
    prefix, _, rest = vector.strip().partition("/")
    metrics = _metrics(rest)
    if prefix in ("CVSS:3.0", "CVSS:3.1"):
        return _v3(metrics)
    if prefix == "CVSS:4.0":
        return _v4(metrics)
    raise ValueError(f"not a CVSS v3/v4 vector: {vector!r}")


def _metrics(text: str) -> dict[str, str]:
    out: dict[str, str] = {}
    for part in filter(None, text.split("/")):
        key, sep, value = part.partition(":")
        if not sep or key in out:
            raise ValueError(f"bad CVSS metric {part!r}")
        out[key] = value
    return out


def _require(metrics: dict[str, str], allowed: Mapping[str, Container[str]]) -> None:
    for key, values in allowed.items():
        if metrics.get(key) not in values:
            raise ValueError(f"CVSS metric {key} missing or out of range: {metrics.get(key)!r}")


# --- v3 -----------------------------------------------------------------------------------

_CIA3 = {"H": 0.56, "L": 0.22, "N": 0.0}
_V3 = {
    "AV": {"N": 0.85, "A": 0.62, "L": 0.55, "P": 0.2},
    "AC": {"L": 0.77, "H": 0.44},
    "PR": {"N": 0.85, "L": 0.62, "H": 0.27},
    "UI": {"N": 0.85, "R": 0.62},
    "C": _CIA3,
    "I": _CIA3,
    "A": _CIA3,
}
_PR3_SCOPE_CHANGED = {"N": 0.85, "L": 0.68, "H": 0.5}


def _roundup(x: float) -> float:
    """The smallest one-decimal number >= x, without ceil's float error (4.000000000000001
    is 4.0, not 4.1)."""
    i = round(x * 100000)
    return i / 100000.0 if i % 10000 == 0 else (i // 10000 + 1) / 10.0


def _v3(metrics: dict[str, str]) -> float:
    _require(metrics, {**_V3, "S": ("U", "C")})
    w = {k: _V3[k][metrics[k]] for k in _V3}
    changed = metrics["S"] == "C"
    pr = _PR3_SCOPE_CHANGED[metrics["PR"]] if changed else w["PR"]
    iss = 1 - (1 - w["C"]) * (1 - w["I"]) * (1 - w["A"])
    impact = 7.52 * (iss - 0.029) - 3.25 * (iss - 0.02) ** 15 if changed else 6.42 * iss
    if impact <= 0:
        return 0.0
    exploitability = 8.22 * w["AV"] * w["AC"] * pr * w["UI"]
    return _roundup(min((1.08 if changed else 1.0) * (impact + exploitability), 10))


# --- v4 -----------------------------------------------------------------------------------

# Severity levels, 0.0 the most severe, one step of severity distance per tenth. Gotcha: these
# stay the reference's float tenths (and a depth is steps * 0.1, not / 10) because published
# scores carry its float error: exact arithmetic moves 88 of 124976 vectors across an x.x5
# rounding boundary (CVSS:4.0/AV:N/AC:L/AT:P/PR:H/UI:A/VC:L/VI:L/VA:L/SC:H/SI:H/SA:H is 4.9,
# not 5.0). SC has no S: Safety exists only as MSI/MSA.
_CIA4 = {"H": 0.0, "L": 0.1, "N": 0.2}
_SUB4 = {"S": 0.0, "H": 0.1, "L": 0.2, "N": 0.3}
_V4 = {
    "AV": {"N": 0.0, "A": 0.1, "L": 0.2, "P": 0.3},
    "AC": {"L": 0.0, "H": 0.1},
    "AT": {"N": 0.0, "P": 0.1},
    "PR": {"N": 0.0, "L": 0.1, "H": 0.2},
    "UI": {"N": 0.0, "P": 0.1, "A": 0.2},
    "VC": _CIA4,
    "VI": _CIA4,
    "VA": _CIA4,
    "SC": {"H": 0.1, "L": 0.2, "N": 0.3},
    "SI": {k: v for k, v in _SUB4.items() if k != "S"},
    "SA": {k: v for k, v in _SUB4.items() if k != "S"},
}
_REQ4 = {"H": 0.0, "M": 0.1, "L": 0.2}
# The optional metrics that score, with X (or absence) allowed. E and CR/IR/AR default to their
# worst value; a modified metric defaults to its base metric.
_V4_ENV = {
    "E": {"X", "A", "P", "U"},
    "CR": {"X", *_REQ4},
    "IR": {"X", *_REQ4},
    "AR": {"X", *_REQ4},
    **{f"M{k}": {"X", *levels} for k, levels in _V4.items()},
    "MSI": {"X", *_SUB4},
    "MSA": {"X", *_SUB4},
}
_V4_DEFAULTS = {"E": "A", "CR": "H", "IR": "H", "AR": "H"}
_LEVELS4 = {**_V4, "SI": _SUB4, "SA": _SUB4, "CR": _REQ4, "IR": _REQ4, "AR": _REQ4}

# MacroVector "<eq1..eq6>" -> the score of its highest severity vector (cvss_lookup.js).
_LOOKUP4 = {
    "000000": 10, "000001": 9.9, "000010": 9.8, "000011": 9.5, "000020": 9.5, "000021": 9.2,
    "000100": 10, "000101": 9.6, "000110": 9.3, "000111": 8.7, "000120": 9.1, "000121": 8.1,
    "000200": 9.3, "000201": 9, "000210": 8.9, "000211": 8, "000220": 8.1, "000221": 6.8,
    "001000": 9.8, "001001": 9.5, "001010": 9.5, "001011": 9.2, "001020": 9, "001021": 8.4,
    "001100": 9.3, "001101": 9.2, "001110": 8.9, "001111": 8.1, "001120": 8.1, "001121": 6.5,
    "001200": 8.8, "001201": 8, "001210": 7.8, "001211": 7, "001220": 6.9, "001221": 4.8,
    "002001": 9.2, "002011": 8.2, "002021": 7.2, "002101": 7.9, "002111": 6.9, "002121": 5,
    "002201": 6.9, "002211": 5.5, "002221": 2.7, "010000": 9.9, "010001": 9.7, "010010": 9.5,
    "010011": 9.2, "010020": 9.2, "010021": 8.5, "010100": 9.5, "010101": 9.1, "010110": 9,
    "010111": 8.3, "010120": 8.4, "010121": 7.1, "010200": 9.2, "010201": 8.1, "010210": 8.2,
    "010211": 7.1, "010220": 7.2, "010221": 5.3, "011000": 9.5, "011001": 9.3, "011010": 9.2,
    "011011": 8.5, "011020": 8.5, "011021": 7.3, "011100": 9.2, "011101": 8.2, "011110": 8,
    "011111": 7.2, "011120": 7, "011121": 5.9, "011200": 8.4, "011201": 7, "011210": 7.1,
    "011211": 5.2, "011220": 5, "011221": 3, "012001": 8.6, "012011": 7.5, "012021": 5.2,
    "012101": 7.1, "012111": 5.2, "012121": 2.9, "012201": 6.3, "012211": 2.9, "012221": 1.7,
    "100000": 9.8, "100001": 9.5, "100010": 9.4, "100011": 8.7, "100020": 9.1, "100021": 8.1,
    "100100": 9.4, "100101": 8.9, "100110": 8.6, "100111": 7.4, "100120": 7.7, "100121": 6.4,
    "100200": 8.7, "100201": 7.5, "100210": 7.4, "100211": 6.3, "100220": 6.3, "100221": 4.9,
    "101000": 9.4, "101001": 8.9, "101010": 8.8, "101011": 7.7, "101020": 7.6, "101021": 6.7,
    "101100": 8.6, "101101": 7.6, "101110": 7.4, "101111": 5.8, "101120": 5.9, "101121": 5,
    "101200": 7.2, "101201": 5.7, "101210": 5.7, "101211": 5.2, "101220": 5.2, "101221": 2.5,
    "102001": 8.3, "102011": 7, "102021": 5.4, "102101": 6.5, "102111": 5.8, "102121": 2.6,
    "102201": 5.3, "102211": 2.1, "102221": 1.3, "110000": 9.5, "110001": 9, "110010": 8.8,
    "110011": 7.6, "110020": 7.6, "110021": 7, "110100": 9, "110101": 7.7, "110110": 7.5,
    "110111": 6.2, "110120": 6.1, "110121": 5.3, "110200": 7.7, "110201": 6.6, "110210": 6.8,
    "110211": 5.9, "110220": 5.2, "110221": 3, "111000": 8.9, "111001": 7.8, "111010": 7.6,
    "111011": 6.7, "111020": 6.2, "111021": 5.8, "111100": 7.4, "111101": 5.9, "111110": 5.7,
    "111111": 5.7, "111120": 4.7, "111121": 2.3, "111200": 6.1, "111201": 5.2, "111210": 5.7,
    "111211": 2.9, "111220": 2.4, "111221": 1.6, "112001": 7.1, "112011": 5.9, "112021": 3,
    "112101": 5.8, "112111": 2.6, "112121": 1.5, "112201": 2.3, "112211": 1.3, "112221": 0.6,
    "200000": 9.3, "200001": 8.7, "200010": 8.6, "200011": 7.2, "200020": 7.5, "200021": 5.8,
    "200100": 8.6, "200101": 7.4, "200110": 7.4, "200111": 6.1, "200120": 5.6, "200121": 3.4,
    "200200": 7, "200201": 5.4, "200210": 5.2, "200211": 4, "200220": 4, "200221": 2.2,
    "201000": 8.5, "201001": 7.5, "201010": 7.4, "201011": 5.5, "201020": 6.2, "201021": 5.1,
    "201100": 7.2, "201101": 5.7, "201110": 5.5, "201111": 4.1, "201120": 4.6, "201121": 1.9,
    "201200": 5.3, "201201": 3.6, "201210": 3.4, "201211": 1.9, "201220": 1.9, "201221": 0.8,
    "202001": 6.4, "202011": 5.1, "202021": 2, "202101": 4.7, "202111": 2.1, "202121": 1.1,
    "202201": 2.4, "202211": 0.9, "202221": 0.4, "210000": 8.8, "210001": 7.5, "210010": 7.3,
    "210011": 5.3, "210020": 6, "210021": 5, "210100": 7.3, "210101": 5.5, "210110": 5.9,
    "210111": 4, "210120": 4.1, "210121": 2, "210200": 5.4, "210201": 4.3, "210210": 4.5,
    "210211": 2.2, "210220": 2, "210221": 1.1, "211000": 7.5, "211001": 5.5, "211010": 5.8,
    "211011": 4.5, "211020": 4, "211021": 2.1, "211100": 6.1, "211101": 5.1, "211110": 4.8,
    "211111": 1.8, "211120": 2, "211121": 0.9, "211200": 4.6, "211201": 1.8, "211210": 1.7,
    "211211": 0.7, "211220": 0.8, "211221": 0.2, "212001": 5.3, "212011": 2.4, "212021": 1.4,
    "212101": 2.4, "212111": 1.2, "212121": 0.5, "212201": 1, "212211": 0.3, "212221": 0.1,
}

# Each equivalence class's highest severity vectors (max_composed.js); eq3 is keyed by eq6 too.
_MAX4: dict[str, dict[int, list[str]]] = {
    "eq1": {
        0: ["AV:N/PR:N/UI:N"],
        1: ["AV:A/PR:N/UI:N", "AV:N/PR:L/UI:N", "AV:N/PR:N/UI:P"],
        2: ["AV:P/PR:N/UI:N", "AV:A/PR:L/UI:P"],
    },
    "eq2": {0: ["AC:L/AT:N"], 1: ["AC:H/AT:N", "AC:L/AT:P"]},
    "eq4": {0: ["SC:H/SI:S/SA:S"], 1: ["SC:H/SI:H/SA:H"], 2: ["SC:L/SI:L/SA:L"]},
    "eq5": {0: ["E:A"], 1: ["E:P"], 2: ["E:U"]},
}
_MAX4_EQ3: dict[tuple[int, int], list[str]] = {
    (0, 0): ["VC:H/VI:H/VA:H/CR:H/IR:H/AR:H"],
    (0, 1): ["VC:H/VI:H/VA:L/CR:M/IR:M/AR:H", "VC:H/VI:H/VA:H/CR:M/IR:M/AR:M"],
    (1, 0): ["VC:L/VI:H/VA:H/CR:H/IR:H/AR:H", "VC:H/VI:L/VA:H/CR:H/IR:H/AR:H"],
    (1, 1): [
        "VC:L/VI:H/VA:L/CR:H/IR:M/AR:H",
        "VC:L/VI:H/VA:H/CR:H/IR:M/AR:M",
        "VC:H/VI:L/VA:H/CR:M/IR:H/AR:M",
        "VC:H/VI:L/VA:L/CR:M/IR:H/AR:H",
        "VC:L/VI:L/VA:H/CR:H/IR:H/AR:M",
    ],
    (2, 1): ["VC:L/VI:L/VA:L/CR:H/IR:H/AR:H"],
}
# Depth of each MacroVector in severity steps (max_severity.js, there +1 each).
_DEPTH4 = {"eq1": {0: 1, 1: 4, 2: 5}, "eq2": {0: 1, 1: 2}, "eq4": {0: 6, 1: 5, 2: 4}}
_DEPTH4_EQ3 = {(0, 0): 7, (0, 1): 6, (1, 0): 8, (1, 1): 8, (2, 1): 10}
# The metrics each class's severity distance sums.
_GROUPS4 = {
    "eq1": ("AV", "PR", "UI"),
    "eq2": ("AC", "AT"),
    "eq3": ("VC", "VI", "VA", "CR", "IR", "AR"),
    "eq4": ("SC", "SI", "SA"),
}


def _effective(metrics: dict[str, str]) -> Callable[[str], str]:
    """The value a v4 metric scores with: a modified metric over its base, defaults for X."""
    def m(key: str) -> str:
        modified = metrics.get(f"M{key}", "X")
        if modified != "X":
            return modified
        value = metrics.get(key, "X")
        return _V4_DEFAULTS.get(key, value) if value == "X" else value
    return m


def _macrovector(m: Callable[[str], str]) -> tuple[int, int, int, int, int, int]:
    av, pr, ui = m("AV"), m("PR"), m("UI")
    eq1 = 0 if av == pr == ui == "N" else 1 if "N" in (av, pr, ui) and av != "P" else 2
    eq2 = 0 if m("AC") == "L" and m("AT") == "N" else 1
    vc, vi, va = m("VC"), m("VI"), m("VA")
    eq3 = 0 if vc == vi == "H" else 1 if "H" in (vc, vi, va) else 2
    eq4 = 0 if "S" in (m("MSI"), m("MSA")) else 1 if "H" in (m("SC"), m("SI"), m("SA")) else 2
    eq5 = {"A": 0, "P": 1, "U": 2}[m("E")]
    eq6 = 0 if ("H", "H") in ((m("CR"), vc), (m("IR"), vi), (m("AR"), va)) else 1
    return eq1, eq2, eq3, eq4, eq5, eq6


def _lookup(eqs: tuple[int, ...]) -> float | None:
    return _LOOKUP4.get("".join(map(str, eqs)))


def _next_lower(eqs: tuple[int, ...], group: str) -> float | None:
    """The score of the next lower MacroVector along one class (None when there is none). eq3
    and eq6 move together; from 00 both 01 and 10 are lower and the higher score is taken."""
    def bump(*idx: int) -> tuple[int, ...]:
        return tuple(e + (i in idx) for i, e in enumerate(eqs))
    if group != "eq3":
        return _lookup(bump(int(group[2]) - 1))
    # 01 -> 11 and 11 -> 21 lower eq3, 10 -> 11 lowers eq6; 21 is the lowest.
    step = {(0, 1): (2,), (1, 1): (2,), (1, 0): (5,)}.get((eqs[2], eqs[5]))
    if (eqs[2], eqs[5]) == (0, 0):
        scores = [s for s in (_lookup(bump(5)), _lookup(bump(2))) if s is not None]
        return max(scores, default=None)
    return _lookup(bump(*step)) if step else None


def _distances(m: Callable[[str], str], eqs: tuple[int, ...]) -> dict[str, float]:
    """Per metric, the vector's levels below the first of its MacroVector's highest vectors that
    it does not exceed anywhere."""
    eq1, eq2, eq3, eq4, eq5, eq6 = eqs
    tops = (_MAX4["eq1"][eq1], _MAX4["eq2"][eq2], _MAX4_EQ3[(eq3, eq6)])
    tops += (_MAX4["eq4"][eq4], _MAX4["eq5"][eq5])
    for combo in product(*tops):
        top = _metrics("/".join(combo))
        dist = {k: _LEVELS4[k][m(k)] - _LEVELS4[k][top[k]] for k in _LEVELS4}
        if min(dist.values()) >= 0:
            return dist
    # Never on the reference tables; unscorable rather than a crash if they ever change.
    raise ValueError(f"no highest vector of MacroVector {eqs} bounds the vector")


def _v4(metrics: dict[str, str]) -> float:
    _require(metrics, _V4)
    _require({k: metrics.get(k, "X") for k in _V4_ENV}, _V4_ENV)
    m = _effective(metrics)
    if all(m(k) == "N" for k in ("VC", "VI", "VA", "SC", "SI", "SA")):
        return 0.0
    eqs = _macrovector(m)
    value = _LOOKUP4["".join(map(str, eqs))]
    dist = _distances(m, eqs)
    depth = {g: _DEPTH4[g][eqs[int(g[2]) - 1]] for g in _DEPTH4}
    depth["eq3"] = _DEPTH4_EQ3[(eqs[2], eqs[5])]
    shifts = []
    for group in ("eq1", "eq2", "eq3", "eq4", "eq5"):
        lower = _next_lower(eqs, group)
        if lower is None:
            continue
        if group == "eq5":  # its proportion is 0 by the spec, but it still counts in the mean
            shifts.append(0.0)
            continue
        # Summed in _GROUPS4's order and divided before multiplying, as cvss_score.js does.
        distance = sum(dist[k] for k in _GROUPS4[group])
        shifts.append((value - lower) * (distance / (depth[group] * 0.1)))
    value -= sum(shifts) / len(shifts) if shifts else 0.0
    # JavaScript's Math.round (half up), as the reference calculator rounds; not Python's round.
    return math.floor(min(max(value, 0.0), 10.0) * 10 + 0.5) / 10
