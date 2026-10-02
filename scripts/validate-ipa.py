#!/usr/bin/env python3
"""Reject incomplete/simulator IPA packages before uploading an artifact."""

import plistlib
import struct
import sys
import zipfile
from pathlib import Path


def main(path: Path) -> None:
    if path.stat().st_size > 400_000_000:
        raise ValueError("IPA exceeds the 400 MB artifact budget.")
    with zipfile.ZipFile(path) as archive:
        members = set(archive.namelist())
        prefix = "Payload/Luma.app/"
        if prefix + "Info.plist" not in members:
            raise ValueError("IPA must contain Payload/Luma.app/Info.plist.")
        info = plistlib.loads(archive.read(prefix + "Info.plist"))
        if info.get("CFBundleIdentifier") != "app.luma.viewer":
            raise ValueError("Unexpected application bundle ID.")
        if info.get("CFBundleSupportedPlatforms") != ["iPhoneOS"]:
            raise ValueError("IPA does not contain an iPhone device build.")
        minimum_os = tuple(int(part) for part in info["MinimumOSVersion"].split("."))
        if minimum_os < (26, 0):
            raise ValueError("This app requires iOS 26 or later.")
        executable = archive.read(prefix + info["CFBundleExecutable"])
        magic, cpu_type, _, file_type = struct.unpack("<IIII", executable[:16])
        if (magic, cpu_type, file_type) != (0xFEEDFACF, 0x0100000C, 2):
            raise ValueError("App executable must be a thin arm64 Mach-O executable.")
        if prefix + "Assets.car" not in members:
            raise ValueError("Compiled asset catalog is missing.")
        for locale in ("en", "zh-Hans", "zh-Hant"):
            for table in ("Localizable.strings", "InfoPlist.strings"):
                if prefix + f"{locale}.lproj/{table}" not in members:
                    raise ValueError(f"Packaged localization is missing: {locale}/{table}.")
        if any(name.endswith(".xctest/") or ".xctest/" in name for name in members):
            raise ValueError("Test bundles must not be included in the release IPA.")
    print(f"Validated unsigned iPhone IPA: {path.name} ({path.stat().st_size / 1_000_000:.1f} MB)")


if __name__ == "__main__":
    try:
        main(Path(sys.argv[1]))
    except (IndexError, OSError, ValueError, KeyError, struct.error, zipfile.BadZipFile) as error:
        raise SystemExit(f"IPA validation failed: {error}") from error
