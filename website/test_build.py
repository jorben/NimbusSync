"""Deployment invariants: preserve signatures and keep source files out of Pages."""

from html.parser import HTMLParser
from pathlib import Path
import tempfile
import unittest
from urllib.parse import urlsplit
import xml.etree.ElementTree as ET

from build import SOURCE, build


class LocalReferences(HTMLParser):
    def __init__(self):
        super().__init__()
        self.references = []
        self.ids = set()

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if "id" in attrs:
            self.ids.add(attrs["id"])
        for key in ("href", "src", "data-zh-src", "data-en-src"):
            value = attrs.get(key)
            if value and not urlsplit(value).scheme:
                self.references.append(value)


class WebsiteBuildTests(unittest.TestCase):
    def test_signed_feed_and_detached_signature_are_preserved_byte_for_byte(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            feed = root / "feed"
            feed.mkdir()
            xml = b'<?xml version="1.0"?>\r\n<!-- signed bytes -->\r\n<rss version="2.0"><channel/></rss>\r\n'
            signature = b"example-detached-signature\n"
            (feed / "appcast.xml").write_bytes(xml)
            (feed / "appcast.xml.sig").write_bytes(signature)
            (feed / "unrelated-secret.txt").write_text("must not be published")
            output = root / "site"
            build(output, feed)
            self.assertEqual((output / "appcast.xml").read_bytes(), xml)
            self.assertEqual((output / "appcast.xml.sig").read_bytes(), signature)
            self.assertFalse((output / "unrelated-secret.txt").exists())
            self.assertFalse((output / "build.py").exists())
            self.assertFalse((output / "test_build.py").exists())
            self.assertTrue((output / ".nojekyll").exists())

    def test_missing_or_invalid_feed_cannot_produce_a_deployment(self):
        for content in (None, "<rss>", "<html/>"):
            with self.subTest(content=content), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                feed = root / "feed"
                feed.mkdir()
                if content is not None:
                    (feed / "appcast.xml").write_text(content)
                output = root / "site"
                with self.assertRaises((FileNotFoundError, ET.ParseError, ValueError)):
                    build(output, feed)
                self.assertFalse(output.exists())

    def test_build_does_not_overwrite_existing_files_or_sources(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            sentinel = output / "keep.txt"
            sentinel.write_text("keep")
            with self.assertRaises(ValueError):
                build(output)
            self.assertEqual(sentinel.read_text(), "keep")
        for output in (SOURCE, SOURCE.parent, SOURCE / "dist"):
            with self.subTest(output=output), self.assertRaises(ValueError):
                build(output)

    def test_every_local_link_and_bilingual_asset_exists_in_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "site"
            build(output)
            parser = LocalReferences()
            parser.feed((output / "index.html").read_text())
            for reference in parser.references:
                with self.subTest(reference=reference):
                    url = urlsplit(reference)
                    self.assertTrue((output / url.path).exists())
                    if url.fragment:
                        self.assertIn(url.fragment, parser.ids)


if __name__ == "__main__":
    unittest.main()
