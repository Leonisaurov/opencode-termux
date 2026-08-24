#!/usr/bin/env python3
"""Fast local acceptance tests for installer invariants (no network/builds)."""
import hashlib, json, os, pathlib, subprocess, tarfile, tempfile, unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
INSTALL = ROOT / "install.sh"

class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp(prefix="installer-tests.", dir=os.environ.get("TMPDIR", "/data/data/com.termux/files/usr/tmp")))
        self.assets = self.tmp / "assets"; self.assets.mkdir()
        self.prefix = self.tmp / "prefix"; self.prefix.mkdir()
        self.manifest = self.tmp / "manifest.json"
        components = {}
        specs = {"bun": "bun", "opentui": "libopentui.so", "opencode": "opencode", "kilo": "kilo", "codex": "codex-android"}
        for component, filename in specs.items():
            payload = self.assets / filename; payload.write_text("#!/bin/sh\nprintf '%s\\n' version\n" % component); payload.chmod(0o755)
            if component == "codex":
                extra = self.assets / "codex-code-mode-host"; extra.write_text("#!/bin/sh\nexit 0\n"); extra.chmod(0o755)
                sandbox = self.assets / "codex-linux-sandbox"; sandbox.write_text("#!/usr/bin/env bash\nexit 78\n"); sandbox.chmod(0o755)
                files = [filename, extra.name, sandbox.name]
            else: files = [filename]
            archive = self.assets / (component + ".tar.gz")
            with tarfile.open(archive, "w:gz") as tar:
                for name in files: tar.add(self.assets / name, arcname=name)
            components[component] = {"version":"1.0.0", "tag":"test", "asset":"assets/" + archive.name, "sha256":hashlib.sha256(archive.read_bytes()).hexdigest(), "size":archive.stat().st_size, "archive":"tar.gz", "depends": {"opencode":["bun","opentui"],"kilo":["bun"]}.get(component,[]), "files":files}
        self.manifest.write_text(json.dumps({"schema":"opencode-termux.stack/v1", "stack_version":"1", "release":"v1.18.11", "stability":"stable", "android":{"arch":"aarch64","abi":"arm64-v8a","api":24}, "components":components}))
    def tearDown(self):
        import shutil; shutil.rmtree(self.tmp, ignore_errors=True)
    def run_installer(self, *args):
        env = os.environ | {"CODEX_INSTALL_TEST_MODE":"1", "TMPDIR":str(self.tmp)}
        return subprocess.run(["bash", str(INSTALL), "--manifest", str(self.manifest), "--prefix", str(self.prefix), "--yes", *args], env=env, text=True, capture_output=True)
    def test_dry_run_does_not_touch_prefix(self):
        r = self.run_installer("--dry-run"); self.assertEqual(r.returncode, 0, r.stderr); self.assertFalse((self.prefix / "bin").exists())
    def test_full_install_and_dependencies(self):
        r = self.run_installer(); self.assertEqual(r.returncode, 0, r.stderr)
        for name in ("bun", "opencode", "kilo", "codex-android", "codex-code-mode-host", "codex-linux-sandbox"):
            self.assertTrue((self.prefix / "bin" / name).is_file(), name)
    def test_just_rejects_missing_dependency(self):
        r = self.run_installer("--just", "opencode"); self.assertNotEqual(r.returncode, 0); self.assertIn("requiere", r.stderr)
    def test_bad_checksum_keeps_prefix_untouched(self):
        data=json.loads(self.manifest.read_text()); data["components"]["bun"]["sha256"]="0"*64; self.manifest.write_text(json.dumps(data))
        r=self.run_installer("--just", "bun"); self.assertNotEqual(r.returncode, 0); self.assertFalse((self.prefix / "bin").exists())
    def test_tar_traversal_is_rejected(self):
        bad=self.assets / "bad.tar.gz"
        with tarfile.open(bad, "w:gz") as tar:
            tar.add(self.assets / "bun", arcname="../escaped")
        data=json.loads(self.manifest.read_text()); c=data["components"]["bun"]
        c.update(asset="assets/bad.tar.gz", sha256=hashlib.sha256(bad.read_bytes()).hexdigest(), size=bad.stat().st_size); self.manifest.write_text(json.dumps(data))
        r=self.run_installer("--just", "bun"); self.assertNotEqual(r.returncode, 0); self.assertFalse((self.tmp / "escaped").exists())
    def test_corrupt_archive_is_rejected(self):
        bad=self.assets / "corrupt.tar.gz"; bad.write_bytes(b"not-an-archive")
        data=json.loads(self.manifest.read_text()); c=data["components"]["bun"]
        c.update(asset="assets/corrupt.tar.gz", sha256=hashlib.sha256(bad.read_bytes()).hexdigest(), size=bad.stat().st_size); self.manifest.write_text(json.dumps(data))
        r=self.run_installer("--just", "bun"); self.assertNotEqual(r.returncode, 0); self.assertFalse((self.prefix / "bin").exists())

if __name__ == "__main__": unittest.main()
