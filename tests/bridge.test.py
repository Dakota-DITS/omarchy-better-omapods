#!/usr/bin/env python3
import importlib.util
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("bridge", ROOT / "bridge.py")
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)

MODELS_TEXT = """Model               Name
SoundcoreA3028      Soundcore Q30 / Life Q30
SoundcoreA3949      Soundcore P20i / P25i / R50i
SoundcoreA3955      Soundcore P40i
SoundcoreA3957      Soundcore Liberty 5
SoundcoreDevelopmentSoundcore Development Information
"""


class MatchTests(unittest.TestCase):
    def test_parse_skips_development_row(self):
        models = bridge.parse_models(MODELS_TEXT)
        ids = [m["id"] for m in models]
        self.assertIn("SoundcoreA3955", ids)
        self.assertNotIn("SoundcoreDevelopment", ids)

    def test_p40i_wins_over_shorter_p_models(self):
        models = bridge.parse_models(MODELS_TEXT)
        devices = [{"mac": "AA:BB:CC:11:22:33", "name": "soundcore P40i"}]
        scored = sorted(
            ((bridge.match_score(devices[0]["name"], m["name"]), m["id"]) for m in models),
            reverse=True,
        )
        self.assertEqual(scored[0][1], "SoundcoreA3955")

    def test_life_q30_matches_q30_family(self):
        self.assertGreater(
            bridge.match_score("Soundcore Life Q30", "Soundcore Q30 / Life Q30"),
            0,
        )

    def test_airpods_do_not_match(self):
        self.assertEqual(bridge.match_score("Alex's AirPods Pro", "Soundcore P40i"), 0)

    def test_capabilities_from_p40i_settings(self):
        setting_ids = {
            "ambientSoundMode": {
                "type": "select",
                "setting": {"options": ["NoiseCanceling", "Transparency", "Normal"]},
            },
            "noiseCancelingMode": {
                "type": "select",
                "setting": {"options": ["Manual", "Adaptive", "MultiScene"]},
            },
            "batteryLevelLeft": {"type": "information"},
            "batteryLevelRight": {"type": "information"},
            "caseBatteryLevel": {"type": "information"},
            "twsStatus": {"type": "information"},
            "manualNoiseCanceling": {
                "type": "i32Range",
                "setting": {"start": 1, "end": 5, "step": 1},
            },
        }
        caps = bridge.capabilities(setting_ids)
        self.assertTrue(caps["supports_noise_off"])
        self.assertTrue(caps["supports_adaptive"])
        self.assertTrue(caps["supports_manual_anc"])
        self.assertEqual(caps["manual_anc_min"], 1)
        self.assertEqual(caps["manual_anc_max"], 5)
        self.assertFalse(caps["supports_touch"])

    def test_touch_options_include_off(self):
        setting_ids = {
            "leftDoublePress": {
                "type": "optionalSelect",
                "setting": {
                    "options": ["NextSong", "PlayPause"],
                    "localizedOptions": ["Next Song", "Play Pause"],
                },
            }
        }
        rows = bridge.touch_options(setting_ids, "leftDoublePress")
        self.assertEqual(rows[0], {"id": "", "label": "Off"})
        self.assertEqual(rows[1]["label"], "Next Song")
        caps = bridge.capabilities(setting_ids)
        self.assertTrue(caps["supports_touch"])

    def test_apple_and_headset_names(self):
        self.assertTrue(bridge.looks_apple("Alex's AirPods Pro"))
        self.assertTrue(bridge.looks_apple("Beats Studio Buds"))
        self.assertFalse(bridge.looks_apple("soundcore P40i"))
        self.assertTrue(bridge.looks_headset("WH-1000XM5"))
        self.assertTrue(bridge.looks_headset("Bose QC Ultra"))
        self.assertFalse(bridge.looks_headset("soundcore P40i"))


class FindTests(unittest.TestCase):
    def test_usage_without_side(self):
        proc = subprocess.run(
            ["bash", str(ROOT / "find.sh")],
            capture_output=True,
            text=True,
        )
        self.assertEqual(proc.returncode, 2)
        self.assertIn("usage:", proc.stderr)

    def test_stop_when_idle(self):
        proc = subprocess.run(
            ["bash", str(ROOT / "find.sh"), "stop"],
            capture_output=True,
            text=True,
        )
        self.assertEqual(proc.returncode, 0)

    def test_refuses_shared_tmp(self):
        env = dict(**{k: v for k, v in __import__("os").environ.items() if k != "XDG_RUNTIME_DIR"})
        env["XDG_RUNTIME_DIR"] = "/tmp"
        proc = subprocess.run(
            ["bash", str(ROOT / "find.sh"), "stop"],
            capture_output=True,
            text=True,
            env=env,
        )
        self.assertNotEqual(proc.returncode, 0)
        err = (proc.stderr + proc.stdout).lower()
        self.assertTrue("private" in err or "symlink" in err or "owner" in err)


class StatusReadTests(unittest.TestCase):
    def test_read_status_missing(self):
        proc = subprocess.run(
            ["python3", str(ROOT / "bridge.py"), "read-status"],
            capture_output=True,
            text=True,
            env={**__import__("os").environ, "XDG_STATE_HOME": "/tmp/better-omapods-missing-state"},
        )
        self.assertNotEqual(proc.returncode, 0)

    def test_run_bounds_timeout_output(self):
        proc = bridge.run(["python3", "-c", "print('ok')"], timeout=5)
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout.strip(), "ok")


if __name__ == "__main__":
    unittest.main()
