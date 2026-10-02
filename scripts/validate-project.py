#!/usr/bin/env python3
"""Check package resources and translation parity without an Apple SDK."""

from __future__ import annotations

import argparse
import json
import plistlib
import re
import struct
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LOCALES = ("en", "zh-Hans", "zh-Hant")
ERRORS: list[str] = []


def require(condition: bool, message: str) -> None:
    if not condition:
        ERRORS.append(message)


def read_strings(path: Path) -> dict[str, str]:
    if not path.is_file():
        ERRORS.append(f"Missing localization: {path.relative_to(ROOT)}")
        return {}
    text = path.read_text(encoding="utf-8-sig")
    # Comments are only accepted between complete string entries.
    entry = re.compile(r'"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;', re.S)
    skip = re.compile(r'(?:\s+|/\*.*?\*/|//[^\n]*(?:\n|$))*', re.S)
    output: dict[str, str] = {}
    offset = 0
    while offset < len(text):
        offset = skip.match(text, offset).end()
        if offset == len(text):
            break
        match = entry.match(text, offset)
        if match is None:
            ERRORS.append(f"Malformed .strings syntax: {path.relative_to(ROOT)} near character {offset}")
            break
        key, value = match.groups()
        require(key not in output, f"Duplicate translation key {key!r} in {path.relative_to(ROOT)}")
        require(bool(value.strip()), f"Empty translation {key!r} in {path.relative_to(ROOT)}")
        output[key] = value
        offset = match.end()
    require(bool(output), f"Empty localization table: {path.relative_to(ROOT)}")
    return output


def png_size(path: Path) -> tuple[int, int]:
    with path.open("rb") as file:
        header = file.read(24)
    if len(header) != 24 or header[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError(f"Not a PNG: {path.relative_to(ROOT)}")
    return struct.unpack(">II", header[16:24])


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prepared-assets", action="store_true")
    args = parser.parse_args()
    info_path = ROOT / "Luma/Info.plist"
    try:
        info = plistlib.loads(info_path.read_bytes())
    except (OSError, plistlib.InvalidFileException, ValueError) as error:
        ERRORS.append(f"Cannot read Luma/Info.plist: {error}")
        info = {}
    require(bool(info.get("NSLocalNetworkUsageDescription")), "Local-network permission explanation is required.")
    require(not info.get("UIRequiresPersistentWiFi", False), "Do not require persistent Wi-Fi solely for a local viewer.")
    require(not info.get("UIBackgroundModes"), "The initial viewer should not request background audio or other persistent modes.")

    for table in ("Localizable.strings", "InfoPlist.strings"):
        translations = {
            locale: read_strings(ROOT / f"Luma/Resources/{locale}.lproj/{table}")
            for locale in LOCALES
        }
        english = translations["en"]
        for locale, values in translations.items():
            missing = set(english) - set(values)
            extra = set(values) - set(english)
            require(not missing, f"{locale}/{table} missing keys: {', '.join(sorted(missing))}")
            require(not extra, f"{locale}/{table} has extra keys: {', '.join(sorted(extra))}")
            for key in english.keys() & values.keys():
                # Preserve NSString formatter type/count across translations.
                placeholder = r'%(?:\d+\$)?(?:[-+0 #]*\d*(?:\.\d+)?)?(?:ll|l|z)?[@diuoxXfFeEgGcCsSp]'
                expected = sorted(re.findall(placeholder, english[key]))
                actual = sorted(re.findall(placeholder, values[key]))
                require(expected == actual, f"Format placeholders differ for {locale}/{key}")
            if table == "InfoPlist.strings":
                for key in info:
                    if key.startswith("NS") and key.endswith("UsageDescription"):
                        require(key in values, f"{locale} must localize permission text {key}")

    source_icon = ROOT / "design/Luma-icon-source.png"
    try:
        width, height = png_size(source_icon)
        require(width == height and width >= 1024, "Original icon must be a square PNG at least 1024px.")
    except (OSError, ValueError) as error:
        ERRORS.append(f"Cannot validate original icon: {error}")

    asset_root = ROOT / "Luma/Assets.xcassets"
    require(asset_root.is_dir(), "Missing Luma/Assets.xcassets.")
    for manifest in asset_root.rglob("Contents.json"):
        try:
            contents = json.loads(manifest.read_text(encoding="utf-8-sig"))
        except (OSError, ValueError) as error:
            ERRORS.append(f"Invalid asset manifest {manifest.relative_to(ROOT)}: {error}")
            continue
        for entry in contents.get("images", []):
            filename = entry.get("filename")
            if not filename:
                continue
            asset_file = manifest.parent / filename
            generated_icon = manifest.parent.name == "AppIcon.appiconset" and filename == "AppIcon.png"
            if generated_icon and not args.prepared_assets:
                continue
            require(asset_file.is_file(), f"Missing referenced asset: {asset_file.relative_to(ROOT)}")
            if generated_icon and asset_file.is_file():
                require(png_size(asset_file) == (1024, 1024), "Prepared AppIcon must be exactly 1024 x 1024 pixels.")

    if ERRORS:
        print("Project validation failed:")
        for error in ERRORS:
            print(f"  - {error}")
        return 1
    print("Project metadata, three localization tables, permission text, and asset references are valid.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
