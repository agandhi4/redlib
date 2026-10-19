"""Docker Compose files read without a YAML library: the services guard_check.py's compose rules
judge and the image references metrics/vuln.py --compose counts. Loaded by path (bin/
_source_tree.py `load`, vuln.py's loader); stdlib only, so the guard runs in pre-commit with
`python3 -I` and nothing installed.

The YAML reader is the subset compose files are written in, and it refuses the rest rather than
guessing (YamlError, exit 2 at the caller, naming <file>:<line>):
  read     block mappings and sequences (a sequence may sit at its key's indent), flow `[...]`
           and `{...}` (across lines too), plain, 'single' and "double" quoted scalars, `|`/`>`
           block scalars with chomping and indent indicators, `#` comments, anchors `&a`,
           aliases `*a`, merge keys `<<: *a` / `<<: [*a, *b]` (explicit keys win), one leading
           `---`; scalars typed by YAML 1.2's core schema (true/false, null/~, ints, floats).
  refused  tags (`!reset`, `!!str`), more than one document, complex keys (`? `), a plain
           scalar continued on the next line, a quoted scalar spanning lines, tabs as indent.
Checked against PyYAML's safe_load on every YAML file in homelab on 2026-10-18
(tests/fixtures/guards/compose/ holds their shapes, anonymised).

Compose semantics: `services` per file; a service's `extends` (`{file, service}` or a name in
the same file) is resolved recursively, the base's keys under the service's own (a shallow merge:
enough for the keys the rules read, which compose merges the same way except for sequences,
which no rule here reads). An `extends` file that does not exist is a ComposeError.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

# A project file: `compose.yaml`, `docker-compose.yml`, or an environment variant run with `-f`
# (`docker-compose.prod.yml`). Not `*.override.*`: compose merges an override onto its base at
# run time, so its partial services (a port added to caddy) are not services to judge alone, and
# a service defined only in an override is not seen.
COMPOSE_NAMES = re.compile(r"(docker-)?compose(\.(?!override\.)[\w-]+)?\.ya?ml")
_DECIMAL = re.compile(r"[-+]?[0-9]+")
_OCTAL_HEX = re.compile(r"0o[0-7]+|0x[0-9a-fA-F]+")
_FLOAT = re.compile(r"[-+]?(\.[0-9]+|[0-9]+(\.[0-9]*)?)([eE][-+]?[0-9]+)?|[-+]?\.(inf|Inf|INF)|\.(nan|NaN|NAN)")
_ESCAPES = {"0": "\0", "a": "\a", "b": "\b", "t": "\t", "n": "\n", "v": "\v", "f": "\f",
            "r": "\r", "e": "\x1b", " ": " ", '"': '"', "/": "/", "\\": "\\", "N": "\x85",
            "_": "\xa0"}  # fmt: skip
_HEX = {"x": 2, "u": 4, "U": 8}
_KEY = re.compile(r"""(?P<key>"(?:[^"\\]|\\.)*"|'(?:[^']|'')*'|[^\s#'"\[\]{},&*!|>%@`-][^#]*?|-[^\s#][^#]*?)\s*:(?:\s|$)""")
_ANCHOR = re.compile(r"&([^\s\[\]{},]+)\s*")


class YamlError(Exception):
    """YAML outside the subset, or malformed: `<file>:<line>: <what>`."""


class ComposeError(Exception):
    """A compose file whose shape the rules cannot read (a missing extends file, ...)."""


class Mapping(dict):
    """A YAML mapping that remembers each key's line, for the violation lines."""

    def __init__(self) -> None:
        super().__init__()
        self.lines: dict[object, int] = {}


@dataclass
class _Line:
    number: int
    indent: int
    text: str  # comment and trailing blanks stripped; "" for a blank or comment-only line
    raw: str


def _strip_comment(raw: str) -> str:
    """The line without its `#` comment: a `#` after a blank, outside quotes; a quote opens only
    where a scalar can start (after a blank or one of `[{,:-`), so `don't` stays one word."""
    quote = ""
    prev = " "
    for i, c in enumerate(raw):
        if quote:
            if c == quote:
                if quote == "'" and raw[i + 1 : i + 2] == "'":
                    continue
                if quote == '"' and _escaped(raw, i):
                    continue
                quote = ""
        elif c in "'\"" and (prev in " \t[{,:-"):
            quote = c
        elif c == "#" and prev in " \t":
            return raw[:i].rstrip()
        prev = c
    return raw.rstrip()


def _escaped(text: str, i: int) -> bool:
    n = 0
    while i - n - 1 >= 0 and text[i - n - 1] == "\\":
        n += 1
    return n % 2 == 1


class _Reader:
    def __init__(self, text: str, where: str) -> None:
        self.where = where
        self.anchors: dict[str, object] = {}
        self.lines: list[_Line] = []
        started = False
        for number, raw in enumerate(text.splitlines(), start=1):
            body = raw.lstrip(" ")
            if body.startswith("\t"):
                raise self.fail(number, "a tab in the indentation")
            text_ = _strip_comment(body)
            if text_ in ("---", "...") or text_.startswith("--- "):
                if started or text_ == "...":
                    raise self.fail(number, "more than one document")
                started = True
                if text_ == "---":
                    continue
                text_ = text_[4:].strip()
            if text_.startswith("%"):
                raise self.fail(number, "a directive (%YAML/%TAG)")
            if text_:
                started = True
            self.lines.append(_Line(number, len(raw) - len(body), text_, raw))
        self.i = 0

    def fail(self, line: int, what: str) -> YamlError:
        return YamlError(f"{self.where}:{line}: {what}")

    # -- block structure ----------------------------------------------------------------

    def skip_blank(self) -> None:
        while self.i < len(self.lines) and not self.lines[self.i].text:
            self.i += 1

    def document(self) -> object:
        self.skip_blank()
        if self.i >= len(self.lines):
            return None
        node = self.node(self.lines[self.i].indent)
        self.skip_blank()
        if self.i < len(self.lines):
            line = self.lines[self.i]
            raise self.fail(line.number, f"unexpected text at indent {line.indent}: {line.text!r}")
        return node

    def node(self, indent: int) -> object:
        """The block node whose first line is the current one, at exactly `indent`."""
        line = self.lines[self.i]
        if line.text == "-" or line.text.startswith("- "):
            return self.sequence(line.indent)
        if line.text.startswith("? "):
            raise self.fail(line.number, "a complex mapping key (`? `)")
        if _KEY.match(line.text):
            return self.mapping(line.indent)
        self.i += 1
        return self.inline(line.text, line, indent)

    def sequence(self, indent: int) -> list:
        items: list = []
        while self.i < len(self.lines):
            self.skip_blank()
            if self.i >= len(self.lines):
                break
            line = self.lines[self.i]
            if line.indent != indent or not (line.text == "-" or line.text.startswith("- ")):
                break
            rest = line.text[1:].lstrip(" ")
            if not rest:
                self.i += 1
                items.append(self.nested(indent, line, allow_same=False))
                continue
            # `- key: v` or `- - x`: the rest is a node at the column it starts in.
            offset = len(line.text) - len(rest)
            self.lines[self.i] = _Line(line.number, indent + offset, rest, line.raw)
            items.append(self.node(indent + offset))
        return items

    def mapping(self, indent: int) -> Mapping:
        out = Mapping()
        merges: list[tuple[int, object]] = []
        while self.i < len(self.lines):
            self.skip_blank()
            if self.i >= len(self.lines):
                break
            line = self.lines[self.i]
            if line.indent != indent:
                if line.indent > indent:
                    raise self.fail(line.number, f"unexpected indent: {line.text!r}")
                break
            match = _KEY.match(line.text)
            if match is None:
                if line.text.startswith("- "):
                    break
                raise self.fail(line.number, f"expected `key: value`, got {line.text!r}")
            key = self.key(match["key"], line)
            rest = line.text[match.end() :].strip()
            self.i += 1
            value = self.value(rest, line, indent)
            if key == "<<":
                merges.append((line.number, value))
                continue
            if key in out:
                raise self.fail(line.number, f"duplicate key {key!r}")
            out[key] = value
            out.lines[key] = line.number
        for number, value in merges:
            for base in value if isinstance(value, list) else [value]:
                if not isinstance(base, Mapping):
                    raise self.fail(number, "a merge key `<<` takes a mapping alias or a list of them")
                for k, v in base.items():
                    if k not in out:
                        out[k] = v
                        out.lines[k] = number
        return out

    def key(self, text: str, line: _Line) -> object:
        text = text.strip()
        if text[:1] in "'\"":
            return self.quoted(text, line)
        return text

    def value(self, rest: str, line: _Line, indent: int) -> object:
        """A mapping value: inline on the key's line, or the block below it."""
        anchor = None
        match = _ANCHOR.match(rest)
        if match:
            anchor, rest = match.group(1), rest[match.end() :]
        if rest[:1] == "!":
            raise self.fail(line.number, f"a tag ({rest.split()[0]})")
        if rest[:1] in ("|", ">"):
            value: object = self.block_scalar(rest, line, indent)
        elif rest:
            value = self.inline(rest, line, indent)
        else:
            value = self.nested(indent, line, allow_same=True)
        if anchor is not None:
            self.anchors[anchor] = value
        return value

    def nested(self, indent: int, line: _Line, *, allow_same: bool) -> object:
        """The block under a key or a bare `-`: deeper lines, or (for a key) a sequence at the
        key's own indent; nothing there is null."""
        self.skip_blank()
        if self.i >= len(self.lines):
            return None
        nxt = self.lines[self.i]
        if nxt.indent > indent:
            return self.node(nxt.indent)
        if allow_same and nxt.indent == indent and (nxt.text == "-" or nxt.text.startswith("- ")):
            return self.sequence(indent)
        return None

    def inline(self, text: str, line: _Line, indent: int) -> object:
        """A value written on one line (a flow collection may continue below)."""
        if text[:1] in "[{":
            while _depth(text) > 0:
                if self.i >= len(self.lines):
                    raise self.fail(line.number, "a flow collection never closes")
                text += " " + self.lines[self.i].text
                self.i += 1
            parser = _Flow(text, self, line.number)
            value = parser.value()
            parser.end()
            return value
        if text[:1] == "*":
            return self.alias(text, line.number)
        if text[:1] == "!":
            raise self.fail(line.number, f"a tag ({text.split()[0]})")
        self.skip_blank()
        if self.i < len(self.lines) and self.lines[self.i].indent > indent and text[:1] not in "'\"":
            raise self.fail(self.lines[self.i].number, "a plain scalar continued on the next line")
        if text[:1] in "'\"":
            return self.quoted(text, line)
        return scalar(text)

    def alias(self, text: str, number: int) -> object:
        name = text[1:].strip()
        if name not in self.anchors:
            raise self.fail(number, f"alias *{name} names no anchor above it")
        return self.anchors[name]

    def quoted(self, text: str, line: _Line) -> str:
        value, end = _quoted(text, 0, self, line.number)
        if text[end:].strip():
            raise self.fail(line.number, f"text after a quoted scalar: {text[end:].strip()!r}")
        return value

    def block_scalar(self, header: str, line: _Line, indent: int) -> str:
        match = re.fullmatch(r"([|>])([-+]?)([1-9]?)([-+]?)", header.strip())
        if match is None:
            raise self.fail(line.number, f"a block scalar header {header!r}")
        style, chomp = match.group(1), match.group(2) or match.group(4)
        explicit = int(match.group(3)) if match.group(3) else 0
        body: list[_Line] = []
        while self.i < len(self.lines):
            nxt = self.lines[self.i]
            if nxt.raw.strip() and nxt.indent <= indent:
                break
            body.append(nxt)
            self.i += 1
        content = [b for b in body if b.raw.strip()]
        width = indent + explicit if explicit else (min(b.indent for b in content) if content else 0)
        texts = [b.raw[width:] if b.raw.strip() else "" for b in body]
        while texts and not texts[-1] and chomp != "+":
            texts.pop()
        if style == "|":
            joined = "\n".join(texts)
        else:
            joined = _fold(texts)
        if not texts:
            return ""
        return joined if chomp == "-" else joined + "\n"


def _fold(texts: list[str]) -> str:
    """A `>` scalar's lines: neighbours join with a space; a blank line, or a more-indented
    line on either side, keeps the line break."""
    out, prev = "", None
    for text in texts:
        if prev is None:
            out = text
        elif not text:
            out += "\n"
        elif not prev:
            out += text
        elif text.startswith(" ") or prev.startswith(" "):
            out += "\n" + text
        else:
            out += " " + text
        prev = text
    return out


def _depth(text: str) -> int:
    depth, quote = 0, ""
    for i, c in enumerate(text):
        if quote:
            if c == quote and not (quote == '"' and _escaped(text, i)):
                quote = ""
        elif c in "'\"":
            quote = c
        elif c in "[{":
            depth += 1
        elif c in "]}":
            depth -= 1
    return depth


def _quoted(text: str, start: int, reader: _Reader, number: int) -> tuple[str, int]:
    """The quoted scalar at text[start]: its value and the index after the closing quote."""
    quote = text[start]
    out: list[str] = []
    i = start + 1
    while i < len(text):
        c = text[i]
        if quote == "'" and c == "'":
            if text[i + 1 : i + 2] == "'":
                out.append("'")
                i += 2
                continue
            return "".join(out), i + 1
        if quote == '"' and c == '"':
            return "".join(out), i + 1
        if quote == '"' and c == "\\":
            esc = text[i + 1 : i + 2]
            if esc in _HEX:
                digits = text[i + 2 : i + 2 + _HEX[esc]]
                out.append(chr(int(digits, 16)))
                i += 2 + _HEX[esc]
                continue
            if esc not in _ESCAPES:
                raise reader.fail(number, f"unknown escape \\{esc}")
            out.append(_ESCAPES[esc])
            i += 2
            continue
        out.append(c)
        i += 1
    raise reader.fail(number, "a quoted scalar spanning lines")


def scalar(text: str) -> object:
    """A plain scalar typed by YAML 1.2's core schema (so `08:00` stays a string, as compose
    reads it, where YAML 1.1 would make it a sexagesimal int)."""
    text = text.strip()
    if text in ("", "~", "null", "Null", "NULL"):
        return None
    if text in ("true", "True", "TRUE"):
        return True
    if text in ("false", "False", "FALSE"):
        return False
    if _DECIMAL.fullmatch(text):
        return int(text, 10)
    if _OCTAL_HEX.fullmatch(text):
        return int(text[2:], 8 if text[1] == "o" else 16)
    if _FLOAT.fullmatch(text):
        return float(text.lower().replace(".inf", "inf").replace(".nan", "nan"))
    return text


class _Flow:
    """A flow collection on one (joined) line."""

    def __init__(self, text: str, reader: _Reader, number: int) -> None:
        self.s, self.i, self.reader, self.number = text, 0, reader, number

    def fail(self, what: str) -> YamlError:
        return self.reader.fail(self.number, what)

    def blanks(self) -> None:
        while self.i < len(self.s) and self.s[self.i] in " \t":
            self.i += 1

    def end(self) -> None:
        self.blanks()
        if self.i != len(self.s):
            raise self.fail(f"text after a flow collection: {self.s[self.i:]!r}")

    def value(self) -> object:
        self.blanks()
        c = self.s[self.i : self.i + 1]
        if c == "[":
            return self.collection("]")
        if c == "{":
            return self.collection("}")
        if c in ("'", '"'):
            value, self.i = _quoted(self.s, self.i, self.reader, self.number)
            return value
        if c == "*":
            start = self.i
            while self.i < len(self.s) and self.s[self.i] not in ",]} \t":
                self.i += 1
            return self.reader.alias(self.s[start : self.i], self.number)
        if c == "!":
            raise self.fail("a tag in a flow collection")
        start = self.i
        while self.i < len(self.s) and self.s[self.i] not in ",]}" and not self.s.startswith(": ", self.i) and not self.s.startswith(":,", self.i):
            if self.s[self.i] == ":" and self.i + 1 == len(self.s):
                break
            self.i += 1
        return scalar(self.s[start : self.i])

    def collection(self, close: str) -> object:
        self.i += 1
        out: object = [] if close == "]" else Mapping()
        while True:
            self.blanks()
            if self.s[self.i : self.i + 1] == close:
                self.i += 1
                return out
            item = self.value()
            self.blanks()
            if self.s[self.i : self.i + 1] == ":":
                self.i += 1
                key, item = item, self.value()
                if isinstance(out, list):
                    single = Mapping()
                    single[key] = item
                    single.lines[key] = self.number
                    out.append(single)
                else:
                    out[key] = item
                    out.lines[key] = self.number
            elif isinstance(out, list):
                out.append(item)
            else:
                out[item] = None
                out.lines[item] = self.number
            self.blanks()
            c = self.s[self.i : self.i + 1]
            if c == ",":
                self.i += 1
            elif c != close:
                raise self.fail(f"expected `,` or `{close}` in a flow collection")


def load(text: str, where: str) -> object:
    """One YAML document of the subset (module docstring) as dicts, lists and scalars."""
    return _Reader(text, where).document()


# ---------------------------------------------------------------------------------- compose


@dataclass(frozen=True)
class Service:
    name: str
    line: int  # the service's key line in its file
    spec: dict  # its keys, `extends` resolved

    @property
    def image(self) -> Image | None:
        ref = self.spec.get("image")
        return None if ref is None else image(str(ref))


def is_compose_file(name: str) -> bool:
    return COMPOSE_NAMES.fullmatch(name) is not None


def services(path: Path, shown: str) -> list[Service]:
    """Every service of one compose file, in file order, extends resolved."""
    doc = _load_file(path, shown)
    block = doc.get("services") if isinstance(doc, dict) else None
    if block is None:
        return []
    if not isinstance(block, Mapping):
        raise ComposeError(f"{shown}: `services` is not a mapping")
    out = []
    for name, spec in block.items():
        resolved = _resolve(path, shown, str(name), spec, block, ())
        out.append(Service(str(name), block.lines[name], resolved))
    return out


def _load_file(path: Path, shown: str) -> object:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise ComposeError(f"cannot read {shown}: {exc.strerror}") from exc
    return load(text, shown)


def _resolve(path: Path, shown: str, name: str, spec: object, block: Mapping, seen: tuple) -> dict:
    if spec is None:
        return {}
    if not isinstance(spec, dict):
        raise ComposeError(f"{shown}: service {name} is not a mapping")
    ext = spec.get("extends")
    if ext is None:
        return dict(spec)
    if (str(path), name) in seen:
        raise ComposeError(f"{shown}: service {name} extends itself")
    if isinstance(ext, str):
        base_path, base_shown, base_name, base_block = path, shown, ext, block
    elif isinstance(ext, dict) and "service" in ext:
        base_name = str(ext["service"])
        if "file" in ext:
            base_path = path.parent / str(ext["file"])
            base_shown = f"{shown.rsplit('/', 1)[0]}/{ext['file']}" if "/" in shown else str(ext["file"])
            if not base_path.is_file():
                raise ComposeError(f"{shown}: service {name} extends {ext['file']}, which does not exist")
            doc = _load_file(base_path, base_shown)
            base_block = doc.get("services") if isinstance(doc, dict) else None
        else:
            base_path, base_shown, base_block = path, shown, block
    else:
        raise ComposeError(f"{shown}: service {name}: `extends` is a service name or {{service, file}}")
    if not isinstance(base_block, dict) or base_name not in base_block:
        raise ComposeError(f"{shown}: service {name} extends {base_name}, which {base_shown} does not define")
    base = _resolve(base_path, base_shown, base_name, base_block[base_name], base_block, (*seen, (str(path), name)))
    merged = {**base, **{k: v for k, v in spec.items() if k != "extends"}}
    return merged


@dataclass(frozen=True)
class Image:
    ref: str  # as written, with `${VAR:-default}` resolved to its default
    tag: str  # "" when none
    digest: str  # "" when none
    interpolated: bool  # the tag comes from a variable with no default: the operator's pin

    @property
    def unpinned(self) -> bool:
        """Neither a digest nor a tag other than `latest`: a pull may bring anything."""
        return not self.digest and not self.interpolated and self.tag in ("", "latest")


_VAR = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)(?:(:?[-?+])([^}]*))?\}|\$([A-Za-z_][A-Za-z0-9_]*)")
_UNSET = "\0"  # brackets a variable with no default while the reference is split


def image(ref: str) -> Image:
    """The tag and digest of an image reference. `${VAR:-default}` reads as its default; a
    variable with no default in the tag or digest is the operator's pin (interpolated)."""

    def substitute(m: re.Match) -> str:
        return m.group(3) if m.group(2) in (":-", "-") else f"{_UNSET}{m.group(0)}{_UNSET}"

    resolved = _VAR.sub(substitute, ref.strip())
    name, at, digest = resolved.partition("@")
    tag = name.rsplit("/", 1)[-1].partition(":")[2]
    interpolated = _UNSET in tag or _UNSET in digest
    return Image(*(t.replace(_UNSET, "") for t in (resolved, tag, digest if at else "")), interpolated)
