#!/usr/bin/env python3
"""Portable boundary tests; these do not claim native Sparkle execution."""
import importlib.util
from pathlib import Path
import sys
import unittest
import urllib.error
import urllib.request

SCRIPT = Path(__file__).resolve().parents[2] / "run-sparkle-fixture.py"
spec = importlib.util.spec_from_file_location("sparkle_fixture", SCRIPT)
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)

class HarnessBoundaryTests(unittest.TestCase):
    def test_owner_marker_change_refuses(self):
        root = fixture.OwnedRoot()
        try:
            (root.path / "owner-marker").write_text("changed")
            with self.assertRaisesRegex(RuntimeError, "marker"):
                root.verify()
        finally:
            fixture.os.close(root.fd)

    def test_unknown_path_components_refused(self):
        root = fixture.OwnedRoot()
        try:
            for part in ("..", ".", "x/y", "/tmp", "x\\y"):
                with self.assertRaises(RuntimeError): root.directory(part)
        finally:
            fixture.os.close(root.fd)

    def test_create_never_overwrites_existing_file(self):
        root = fixture.OwnedRoot()
        try:
            path = root.path / "known"
            fixture.write_new(path, b"original")
            with self.assertRaises(FileExistsError): fixture.write_new(path, b"replacement")
            self.assertEqual(path.read_bytes(), b"original")
        finally:
            fixture.os.close(root.fd)

    def test_loopback_uses_exact_payload_map(self):
        server = fixture.FixtureServer()
        try:
            route = "/" + "a" * 32 + "/valid/appcast.xml"
            server.add(route, b"synthetic feed")
            self.assertEqual(urllib.request.urlopen(server.base + route).read(), b"synthetic feed")
            for path in ("/etc/passwd", route + "?path=/etc/passwd", "/../appcast.xml"):
                with self.assertRaises(urllib.error.HTTPError): urllib.request.urlopen(server.base + path)
            with self.assertRaises(RuntimeError): server.add("/../unowned", b"no")
        finally:
            server.close()

    def test_tree_proof_detects_payload_changes(self):
        root = fixture.OwnedRoot()
        try:
            folder = root.directory("tree")
            fixture.write_new(folder / "file", b"first")
            first = fixture.tree_digest(folder)
            (folder / "file").write_bytes(b"other")
            self.assertNotEqual(first, fixture.tree_digest(folder))
        finally:
            fixture.os.close(root.fd)

    def test_non_hosted_entrypoint_refuses_before_creating_output(self):
        if sys.platform == "darwin" and fixture.os.environ.get("GITHUB_ACTIONS") == "true":
            self.skipTest("Native CI entrypoint is tested by the workflow")
        with self.assertRaisesRegex(RuntimeError, "GitHub-hosted"):
            fixture.main()

if __name__ == "__main__": unittest.main()
