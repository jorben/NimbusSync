#!/usr/bin/env python3
"""Adds one NimbusSync build to the Sparkle appcast (publish-appcast.yml).

The appcast lists every published build once, keyed by its build number (CFBundleVersion,
Sparkle's `sparkle:version`). Prereleases are published to the `beta` channel; promoting a
prerelease republishes the same build without a channel, which replaces its beta item, so
beta testers are not offered the same version twice.

The script only rewrites the XML. The feed's EdDSA signature (SURequireSignedFeed) is added
afterwards by Sparkle's sign_update, so any existing signature comment is dropped here.

Usage:
  Scripts/update-appcast.py --appcast appcast.xml --channel beta --version 0.2.0-rc.1 \
      --build 42 --url https://.../NimbusSync-0.2.0-rc.1.zip --length 1234 \
      --ed-signature BASE64 --minimum-system-version 13.0 \
      --release-notes notes.md --release-page https://github.com/.../releases/tag/0.2.0-rc.1
"""

import argparse
import email.utils
import os
import re
import sys
import xml.etree.ElementTree as ET

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
DC_NS = "http://purl.org/dc/elements/1.1/"
ET.register_namespace("sparkle", SPARKLE_NS)
ET.register_namespace("dc", DC_NS)

CHANNELS = ("stable", "beta")
# Older builds beyond this many are dropped; nobody should still be updating from them, and
# Sparkle only needs the newest item a client may install.
MAX_ITEMS = 30
FEED_TITLE = "NimbusSync"
FEED_LINK = "https://github.com/jorben/NimbusSync"


def sparkle(tag):
    return f"{{{SPARKLE_NS}}}{tag}"


def fail(message):
    print(f"update-appcast: {message}", file=sys.stderr)
    sys.exit(1)


def parse_args(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--appcast", required=True, help="appcast.xml to update (created if missing)")
    parser.add_argument("--channel", required=True, choices=CHANNELS)
    parser.add_argument("--version", required=True, help="full version shown to users, e.g. 0.2.0-rc.1")
    parser.add_argument("--build", required=True, help="CFBundleVersion of the build")
    parser.add_argument("--url", required=True, help="HTTPS URL of the update ZIP")
    parser.add_argument("--length", required=True, type=int, help="ZIP size in bytes")
    parser.add_argument("--ed-signature", required=True, help="EdDSA signature of the ZIP (sign_update)")
    parser.add_argument("--minimum-system-version", required=True)
    parser.add_argument("--release-notes", help="Markdown release notes file")
    parser.add_argument("--release-page", help="Release page URL, linked from the item")
    parser.add_argument("--pub-date", help="RFC 2822 date (default: now)")
    return parser.parse_args(argv)


def validate(args):
    if not re.fullmatch(r"[0-9]+(\.[0-9]+){1,2}(-[0-9A-Za-z.-]+)?", args.version):
        fail(f"unsupported version: {args.version}")
    if not re.fullmatch(r"[0-9]+(\.[0-9]+){0,2}", args.build):
        fail(f"unsupported build number: {args.build}")
    if args.channel == "stable" and "-" in args.version:
        fail(f"{args.version} is a prerelease version; publish it to the beta channel")
    for name in ("url", "release_page"):
        value = getattr(args, name)
        if value is not None and not value.startswith("https://"):
            fail(f"--{name.replace('_', '-')} must be an https URL")
    if args.length <= 0:
        fail("--length must be positive")
    if not re.fullmatch(r"[A-Za-z0-9+/]+={0,2}", args.ed_signature):
        fail("--ed-signature is not base64")
    if not re.fullmatch(r"[0-9]+(\.[0-9]+){1,2}", args.minimum_system_version):
        fail(f"unsupported minimum system version: {args.minimum_system_version}")


def build_key(text):
    return tuple(int(part) for part in text.split("."))


def load_channel(path):
    if os.path.exists(path):
        try:
            tree = ET.parse(path)  # Comments, including a previous feed signature, are dropped.
        except ET.ParseError as error:
            fail(f"{path} is not valid XML: {error}")
        root = tree.getroot()
        channel = root.find("channel")
        if root.tag != "rss" or channel is None:
            fail(f"{path} is not an RSS appcast")
        return root, channel
    root = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(root, "channel")
    ET.SubElement(channel, "title").text = FEED_TITLE
    ET.SubElement(channel, "link").text = FEED_LINK
    ET.SubElement(channel, "description").text = "Updates for NimbusSync"
    ET.SubElement(channel, "language").text = "en"
    return root, channel


def make_item(args):
    item = ET.Element("item")
    ET.SubElement(item, "title").text = f"{FEED_TITLE} {args.version}"
    ET.SubElement(item, "pubDate").text = args.pub_date or email.utils.formatdate(usegmt=True)
    if args.release_page:
        ET.SubElement(item, "link").text = args.release_page
    ET.SubElement(item, sparkle("version")).text = args.build
    ET.SubElement(item, sparkle("shortVersionString")).text = args.version
    ET.SubElement(item, sparkle("minimumSystemVersion")).text = args.minimum_system_version
    if args.channel == "beta":
        ET.SubElement(item, sparkle("channel")).text = "beta"
    if args.release_page:
        ET.SubElement(item, sparkle("fullReleaseNotesLink")).text = args.release_page
    if args.release_notes:
        with open(args.release_notes, encoding="utf-8") as handle:
            notes = handle.read().strip()
        if notes:
            ET.SubElement(item, "description", {sparkle("format"): "markdown"}).text = notes
    ET.SubElement(item, "enclosure", {
        "url": args.url,
        "length": str(args.length),
        "type": "application/octet-stream",
        sparkle("edSignature"): args.ed_signature,
    })
    return item


def item_build(item):
    element = item.find(sparkle("version"))
    if element is None or not element.text:
        fail("an existing item has no sparkle:version")
    return element.text.strip()


def main(argv):
    args = parse_args(argv)
    validate(args)
    root, channel = load_channel(args.appcast)

    items = channel.findall("item")
    for item in items:
        channel.remove(item)
    replaced = [item for item in items if item_build(item) == args.build]
    items = [item for item in items if item_build(item) != args.build]
    for item in replaced:
        old = item.find(sparkle("shortVersionString"))
        if old is not None and old.text != args.version:
            fail(f"build {args.build} is already published as {old.text}, not {args.version}")
    items.append(make_item(args))
    items.sort(key=lambda item: build_key(item_build(item)), reverse=True)
    channel.extend(items[:MAX_ITEMS])

    ET.indent(root, space="  ")
    tree = ET.ElementTree(root)
    temporary = f"{args.appcast}.tmp"
    tree.write(temporary, encoding="utf-8", xml_declaration=True)
    with open(temporary, "a", encoding="utf-8") as handle:
        handle.write("\n")
    os.replace(temporary, args.appcast)
    action = "replaced" if replaced else "added"
    print(f"{action} {args.version} (build {args.build}) on the {args.channel} channel; {min(len(items), MAX_ITEMS)} items")


if __name__ == "__main__":
    main(sys.argv[1:])
