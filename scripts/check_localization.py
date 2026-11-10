#!/usr/bin/env python3
"""Checks that every user-visible English string in the Swift sources has a
translation in the Localizable fragments for all supported languages.

Usage: ./scripts/check_localization.py [--verbose]
Exits non-zero when strings are missing, so it can gate a build.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCES = os.path.join(ROOT, "Sources", "ProxyDog")
LOCALIZATION = os.path.join(ROOT, "Resources", "Localization")
LANGUAGES = ["en", "zh-Hans"]

# Files whose strings are not UI copy (dev-only sample data, analytics keys, ...).
SKIP_FILES = {
    "SampleData.swift",
    "HeadlessRunner.swift",
    "Analytics.swift",
    "HARExporter.swift",
}

# Call sites whose first literal argument is user-visible copy.
PATTERNS = [
    r'Text\("((?:[^"\\]|\\.)*)"',
    r'Button\("((?:[^"\\]|\\.)*)"',
    r'Label\("((?:[^"\\]|\\.)*)"',
    r'Toggle\("((?:[^"\\]|\\.)*)"',
    r'Picker\("((?:[^"\\]|\\.)*)"',
    r'Section\("((?:[^"\\]|\\.)*)"',
    r'\.help\("((?:[^"\\]|\\.)*)"',
    r'\.accessibilityLabel\("((?:[^"\\]|\\.)*)"',
    r'\.navigationTitle\("((?:[^"\\]|\\.)*)"',
    r'String\(localized: "((?:[^"\\]|\\.)*)"',
    r'NSLocalizedString\("((?:[^"\\]|\\.)*)"',
]

# Values that are never localized: SF Symbols, formats, versions, identifiers.
SKIP_PATTERNS = [
    r"^[a-z0-9]+(\.[a-z0-9]+)+$",      # doucment symbols / domains / keys
    r"^[A-Z][A-Za-z]*\.[a-z]",         # file names
    r"^%",                             # format only
    r"^\d",                            # numbers
    r"^v?\d+\.\d+",                    # version
    r"^HTTP/",                         # protocol tokens
    r"^[A-Z]+$",                       # short technical tokens (GET, JSON, ...)
]


def is_technical(value: str) -> bool:
    if not value.strip():
        return True
    for pattern in SKIP_PATTERNS:
        if re.search(pattern, value):
            return True
    # Strings without letters (symbols, punctuation) are not copy.
    return not re.search(r"[A-Za-z]", value)


def collect_keys() -> dict:
    """Returns {key: [files]} for every user-visible literal found in the sources."""
    keys = {}
    for dirpath, _, filenames in os.walk(SOURCES):
        for filename in filenames:
            if not filename.endswith(".swift") or filename in SKIP_FILES:
                continue
            path = os.path.join(dirpath, filename)
            relative = os.path.relpath(path, ROOT)
            text = open(path, encoding="utf-8").read()
            for pattern in PATTERNS:
                for match in re.finditer(pattern, text):
                    value = match.group(1)
                    if is_technical(value):
                        continue
                    keys.setdefault(value, set()).add(relative)
    return keys


def parse_strings(path: str) -> dict:
    entries = {}
    if not os.path.exists(path):
        return entries
    text = open(path, encoding="utf-8").read()
    for match in re.finditer(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;', text, re.M):
        entries[match.group(1)] = match.group(2)
    return entries


def main() -> int:
    verbose = "--verbose" in sys.argv
    keys = collect_keys()

    translations = {}
    for language in LANGUAGES:
        entries = {}
        for filename in sorted(os.listdir(LOCALIZATION)):
            if filename.endswith(f".{language}.strings"):
                entries.update(parse_strings(os.path.join(LOCALIZATION, filename)))
        translations[language] = entries

    interpolated = sorted(key for key in keys if "\\(" in key)
    if interpolated:
        print("Interpolated literals that must be refactored to explicit formats "
              "(String(format: String(localized: \"… %@\"), value)):")
        for key in interpolated:
            files = ", ".join(sorted(keys[key]))
            print(f'  "{key}"  ->  {files}')
        print()

    all_keys = set(key for key in keys if "\\(" not in key) | set(translations["en"].keys())
    missing = []
    for key in sorted(all_keys):
        problems = []
        for language in LANGUAGES:
            table = translations[language]
            if key not in table:
                problems.append(language)
            elif (
                language == "zh-Hans"
                and table[key].strip() == key.strip()
                and " " in key
                and re.search(r"[A-Za-z]{3,}", key)
            ):
                problems.append("zh-Hans (untranslated)")
        if problems:
            missing.append((key, ", ".join(problems), sorted(keys.get(key, []))))

    if missing:
        print(f"Missing localization entries ({len(missing)}):")
        for key, languages, files in missing:
            print(f'  "{key}"  ->  missing: {languages}')
            if verbose:
                for file in files:
                    print(f"        used in {file}")
        print("\nAdd them to Resources/Localization/*.en.strings and *.zh-Hans.strings")
        return 1

    unused = sorted(
        key for key in translations["en"]
        if key not in keys and not is_technical(key)
    )
    if unused and verbose:
        print(f"Entries not detected in sources ({len(unused)}), check for typos:")
        for key in unused:
            print(f'  "{key}"')

    print(f"Localization OK: {len(all_keys)} keys across {', '.join(LANGUAGES)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
