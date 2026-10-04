#!/usr/bin/env python3
"""Lint the project wiki (an OKF v0.2 bundle in wiki/).

    python3 scripts/wiki-lint.py           report problems
    python3 scripts/wiki-lint.py --fix     also rewrite the per-directory index.md files
    python3 scripts/wiki-lint.py --strict  exit non-zero on warnings too

Errors are OKF conformance failures (unparseable frontmatter, missing `type`,
malformed index.md / log.md). Everything else is a warning against the
conventions in wiki/meta/conventions.md. Needs PyYAML.
"""

import argparse
import datetime
import re
import subprocess
import sys
import urllib.parse
from collections import Counter
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parent.parent
WIKI = REPO / "wiki"
RESERVED = {"index.md", "log.md"}

# Order here is the section order in generated directory indexes.
TYPES = {
    "Overview": "Overviews",
    "Concept": "Concepts",
    "Component": "Components",
    "Feature": "Features",
    "Decision": "Decisions",
    "Investigation": "Investigations",
    "Platform Quirk": "Platform quirks",
    "Playbook": "Playbooks",
    "Reference": "References",
    "Guide": "Guides",
}
STATUSES = {"draft", "stable", "deprecated"}
DATETIME = re.compile(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?(Z|[+-]\d\d:\d\d)$")
SLUG = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*\.md$")
TASK = re.compile(r"^backlog:TASK-(\d+(?:\.\d+)?)$", re.IGNORECASE)
LINK = re.compile(r"(?<!\!)\[[^\]]*\]\(\s*<?([^)\s>]+)>?(?:\s+\"[^\"]*\")?\s*\)")
FOOTNOTE_REF = re.compile(r"\[\^([^\]\s]+)\](?!:)")
FOOTNOTE_DEF = re.compile(r"^\[\^([^\]\s]+)\]:", re.MULTILINE)
INDEX_ENTRY = re.compile(r"^\* \[[^\]]+\]\([^)]+\)( - .+)?$")
LOG_DATE = re.compile(r"^## (\d{4}-\d\d-\d\d)$")

errors, warnings = [], []


def rel(path):
    return path.relative_to(REPO).as_posix()


def error(path, message):
    errors.append(f"{rel(path)}: {message}")


def warn(path, message):
    warnings.append(f"{rel(path)}: {message}")


def split_frontmatter(text):
    """Returns (frontmatter text or None, body)."""
    if not text.startswith("---\n"):
        return None, text
    end = text.find("\n---\n", 3)
    if end == -1:
        return None, text
    return text[4:end + 1], text[end + 5:]


def strip_code(body):
    body = re.sub(r"^(```|~~~).*?^\1[^\n]*$", "", body, flags=re.MULTILINE | re.DOTALL)
    body = re.sub(r"^(?: {4}|\t).*$", "", body, flags=re.MULTILINE)
    return re.sub(r"`[^`\n]*`", "", body)


def parse_datetime(value):
    return datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))


def task_ids():
    ids = set()
    for directory in ("backlog/tasks", "backlog/completed", "backlog/archive/tasks"):
        for path in (REPO / directory).glob("task-* - *.md"):
            ids.add(path.name.split(" - ", 1)[0][len("task-"):].lower())
    return ids


def commit_exists(sha):
    result = subprocess.run(["git", "-C", str(REPO), "cat-file", "-e", f"{sha}^{{commit}}"],
                            capture_output=True)
    return result.returncode == 0


def resolve(page, target):
    """A path-valued field or link target → absolute path, or None if it is not a path."""
    target = urllib.parse.unquote(target.split("#", 1)[0])
    if not target:
        return None
    if target.startswith("/"):
        return (WIKI / target.lstrip("/")).resolve()
    return (page.parent / target).resolve()


def check_path_field(page, field, value, tasks):
    if re.match(r"^[a-z][a-z0-9+.-]*://", value):
        return
    task = TASK.match(value)
    if task:
        if task.group(1).lower() not in tasks:
            warn(page, f"{field}: no Backlog task {value[len('backlog:'):]}")
        return
    if value.startswith("commit:"):
        if not commit_exists(value[len("commit:"):]):
            warn(page, f"{field}: unknown commit {value}")
        return
    if value.startswith(("./", "../", "/")):
        if not resolve(page, value).exists():
            warn(page, f"{field}: path does not exist: {value}")
        return
    # Anything else is a free-text scope descriptor (OKF §5.1); a bare repo
    # path is the likely mistake.
    if re.match(r"^[\w.-]+(/[\w.+-]+)+$", value):
        warn(page, f"{field}: looks like a path but is not relative to the page: {value}")


def check_concept(page, tasks):
    """Returns the page's metadata dict, or None when it does not conform."""
    text = page.read_text(encoding="utf-8")
    front, body = split_frontmatter(text)
    if front is None:
        error(page, "no YAML frontmatter block")
        return None
    try:
        # BaseLoader keeps every scalar a string, so timestamps are checked as written.
        meta = yaml.load(front, Loader=yaml.BaseLoader)
    except yaml.YAMLError as exc:
        error(page, f"frontmatter does not parse: {str(exc).splitlines()[0]}")
        return None
    if not isinstance(meta, dict) or not str(meta.get("type") or "").strip():
        error(page, "frontmatter has no `type`")
        return None

    if page.parent.parent != WIKI:
        warn(page, "concepts live exactly one directory below wiki/")
    if not SLUG.match(page.name):
        warn(page, "filename is not lowercase kebab-case")
    if meta["type"] not in TYPES:
        warn(page, f"type `{meta['type']}` is not in the conventions")
    for key in ("title", "description"):
        if not str(meta.get(key) or "").strip():
            warn(page, f"missing `{key}`")
    if "\n" in str(meta.get("description") or "").strip():
        warn(page, "`description` spans several lines")
    if "status" in meta and meta["status"] not in STATUSES:
        warn(page, f"status `{meta['status']}` is not draft | stable | deprecated")

    generated = meta.get("generated")
    if not isinstance(generated, dict) or not generated.get("by"):
        warn(page, "missing `generated: { by, at }`")
    elif not DATETIME.match(str(generated.get("at") or "")):
        warn(page, "`generated.at` is not an ISO 8601 datetime with a UTC offset")

    verified = meta.get("verified")
    if isinstance(verified, dict):
        verified = [verified]
    for entry in verified or []:
        if not isinstance(entry, dict) or not entry.get("by") or not DATETIME.match(str(entry.get("at") or "")):
            warn(page, "`verified` entries need `by` and an ISO 8601 `at`")
    actors = [entry.get("by", "") for entry in verified or [] if isinstance(entry, dict)]
    meta["_tier"] = ("human-reviewed" if any(a.startswith("human:") for a in actors)
                     else "machine-confirmed" if actors else "unverified")

    if "stale_after" in meta:
        if not DATETIME.match(str(meta["stale_after"])):
            warn(page, "`stale_after` is not an ISO 8601 datetime with a UTC offset")
        elif parse_datetime(meta["stale_after"]) <= datetime.datetime.now(datetime.timezone.utc):
            warn(page, f"stale since {meta['stale_after']}; re-check it against its sources")

    if "resource" in meta:
        check_path_field(page, "resource", str(meta["resource"]), tasks)
    source_ids = set()
    sources = meta.get("sources")
    if not sources:
        warn(page, "no `sources`")
    for source in sources or []:
        if not isinstance(source, dict) or not source.get("resource"):
            warn(page, "a `sources` entry has no `resource`")
            continue
        if source.get("id") in source_ids:
            warn(page, f"duplicate source id `{source['id']}`")
        if source.get("id"):
            source_ids.add(source["id"])
        check_path_field(page, "sources[].resource", str(source["resource"]), tasks)

    prose = strip_code(body)
    if re.search(r"^# ", prose, re.MULTILINE) is None:
        warn(page, "body has no `#` section heading")
    definitions = set(FOOTNOTE_DEF.findall(prose))
    for label in sorted(set(FOOTNOTE_REF.findall(prose))):
        if label not in source_ids:
            warn(page, f"footnote [^{label}] does not match a `sources[].id`")
        if label not in definitions:
            warn(page, f"footnote [^{label}] has no definition")

    meta["_links"] = links_in(page, prose)
    return meta


def links_in(page, prose):
    """Checks a page's markdown links; returns the set of wiki pages it links to."""
    targets = set()
    for target in LINK.findall(prose):
        if re.match(r"^[a-z][a-z0-9+.-]*:", target) or target.startswith("#"):
            continue
        if target.startswith("/"):
            warn(page, f"bundle-absolute link {target}; use a relative link")
        path = resolve(page, target)
        if path is None:
            continue
        inside = WIKI in path.parents
        if not path.exists():
            warn(page, f"link to a page that is not written yet: {target}" if inside
                 else f"broken link: {target}")
        elif inside and path.is_file():
            targets.add(path)
    return targets


def directory_index(directory, pages):
    sections = []
    for type_name, heading in list(TYPES.items()) + [(None, "Other")]:
        members = [(meta, page) for page, meta in pages.items()
                   if page.parent == directory
                   and (meta["type"] == type_name or (type_name is None and meta["type"] not in TYPES))]
        if not members:
            continue
        lines = [f"# {heading}", ""]
        for meta, page in sorted(members, key=lambda item: str(item[0].get("title") or item[1].stem).lower()):
            title = str(meta.get("title") or page.stem)
            description = " ".join(str(meta.get("description") or "").split())
            marker = {"draft": " *(draft)*", "deprecated": " *(deprecated)*"}.get(meta.get("status"), "")
            lines.append(f"* [{title}]({page.name}) - {description}{marker}" if description
                         else f"* [{title}]({page.name}){marker}")
        sections.append("\n".join(lines))
    return "\n\n".join(sections) + "\n"


def check_index_structure(path, text):
    front, body = split_frontmatter(text)
    if front is not None:
        keys = set((yaml.load(front, Loader=yaml.BaseLoader) or {}).keys())
        if path.parent != WIKI or keys - {"okf_version"}:
            error(path, "index.md frontmatter may only be `okf_version`, and only in the root index")
    for line in strip_code(body).splitlines():
        if line.startswith("* ") and not INDEX_ENTRY.match(line):
            error(path, f"index entry is not `* [Title](url) - description`: {line[:60]}")


def check_root(pages):
    index = WIKI / "index.md"
    linked = set()
    if not index.exists():
        error(index, "missing root index.md")
    else:
        text = index.read_text(encoding="utf-8")
        check_index_structure(index, text)
        front, body = split_frontmatter(text)
        if front is None or "okf_version" not in front:
            warn(index, "root index does not declare `okf_version`")
        linked = links_in(index, strip_code(body))
        for directory in sorted({page.parent for page in pages}):
            if f"({directory.name}/" not in body:
                warn(index, f"directory {directory.name}/ is not listed")

    log = WIKI / "log.md"
    if not log.exists():
        error(log, "missing log.md")
    else:
        text = log.read_text(encoding="utf-8")
        dates = []
        for line in text.splitlines():
            if line.startswith("## "):
                match = LOG_DATE.match(line)
                if not match:
                    error(log, f"date heading is not `## YYYY-MM-DD`: {line}")
                else:
                    dates.append(match.group(1))
        if dates != sorted(dates, reverse=True):
            warn(log, "date headings are not newest first")
        links_in(log, strip_code(text))
    return linked


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--fix", action="store_true", help="rewrite the per-directory index.md files")
    parser.add_argument("--strict", action="store_true", help="exit non-zero on warnings")
    args = parser.parse_args()

    tasks = task_ids()
    pages = {}
    for path in sorted(WIKI.rglob("*.md")):
        if path.name in RESERVED:
            continue
        meta = check_concept(path, tasks)
        if meta is not None:
            pages[path] = meta

    for directory in sorted({page.parent for page in pages}):
        index = directory / "index.md"
        expected = directory_index(directory, pages)
        current = index.read_text(encoding="utf-8") if index.exists() else None
        if current != expected:
            if args.fix:
                index.write_text(expected, encoding="utf-8")
                print(f"wrote {rel(index)}")
            else:
                warn(index, "out of date; run with --fix")
        if index.exists():
            check_index_structure(index, index.read_text(encoding="utf-8"))

    root_links = check_root(pages)
    for page in pages:
        linked_from_others = any(page in meta["_links"] for other, meta in pages.items() if other != page)
        if page not in root_links and not linked_from_others:
            warn(page, "orphan: no other page links here")

    for message in errors:
        print(f"error: {message}")
    for message in warnings:
        print(f"warning: {message}")
    types = Counter(meta["type"] for meta in pages.values())
    tiers = Counter(meta["_tier"] for meta in pages.values())
    print(f"\n{len(pages)} pages: " + ", ".join(f"{count} {name}" for name, count in types.most_common()))
    print("trust: " + ", ".join(f"{count} {name}" for name, count in tiers.most_common()))
    print(f"{len(errors)} errors, {len(warnings)} warnings")
    return 1 if errors or (args.strict and warnings) else 0


if __name__ == "__main__":
    sys.exit(main())
