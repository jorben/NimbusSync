#!/usr/bin/env python3
"""Assemble the static site and preserve the signed Sparkle feed byte for byte."""

from __future__ import annotations

import argparse
from pathlib import Path
import shutil
import xml.etree.ElementTree as ET


SOURCE = Path(__file__).resolve().parent
SITE_FILES = ("index.html", "styles.css", "script.js")


def build(output: Path, appcast_dir: Path | None = None) -> None:
    output = output.resolve()
    # Never clear or overwrite the source tree (or one of its ancestors).
    if output == SOURCE or output in SOURCE.parents or SOURCE in output.parents:
        raise ValueError("Output must be outside website/ and its ancestors")
    if output.exists():
        raise ValueError(f"Output already exists; choose a fresh directory: {output}")

    feed_files = []
    if appcast_dir is not None:
        feed = appcast_dir / "appcast.xml"
        # Missing or malformed feeds must fail before assembling a deployable site.
        # Parsing checks the input; copying the original bytes preserves its signature.
        if ET.parse(feed).getroot().tag != "rss":
            raise ValueError("Expected a Sparkle RSS appcast")
        feed_files.append(feed)
        signature = appcast_dir / "appcast.xml.sig"
        if signature.exists():
            feed_files.append(signature)
        if output == appcast_dir.resolve() or output in appcast_dir.resolve().parents:
            raise ValueError("Output must not contain the appcast source")

    output.mkdir(parents=True)
    for filename in SITE_FILES:
        shutil.copyfile(SOURCE / filename, output / filename)
    shutil.copytree(SOURCE / "assets", output / "assets")
    (output / ".nojekyll").touch()
    for source in feed_files:
        shutil.copyfile(source, output / source.name)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--appcast-dir", type=Path, help="gh-pages checkout; required for deployment")
    args = parser.parse_args()
    build(args.output, args.appcast_dir)
    print(f"Static site assembled at {args.output}")
