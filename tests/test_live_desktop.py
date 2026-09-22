"""Users reported no Wi-Fi and no terminal on utah:testing.

Ground truth, verified against the image and both repodata sets: the base
image carries no linux-firmware, no NetworkManager-wifi, and no terminal
emulator at all. These tests pin the installable half of the fix (firmware
in the contract, Ghostty as the live session's default terminal) and the
documented blockers (supplicant via utah-packages#136, ptyxis via
utah-packages#224) so neither regresses silently.
"""
import tomllib
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OVERLAY = ROOT / "packages/utah.toml"


def overlay():
    with OVERLAY.open("rb") as handle:
        return tomllib.load(handle)


class WifiTests(unittest.TestCase):
    def test_firmware_is_in_the_contract(self):
        """iwlwifi and friends need their blobs; the factory image carries
        linux-firmware, so there is no reason to leave it out. It lives in
        [parity] like the rest of what Bluefin gets unnamed from Fedora's
        base: Bluefin never names it, Utah must. And linux-firmware alone
        does not cover Intel wireless (split package), so the iwlwifi
        generations and iwlegacy ride explicitly -- otherwise the X230 from
        #97 stays dead while the issue looks closed."""
        data = overlay()
        parity = data["parity"]["packages"]
        for name in ("linux-firmware", "iwlwifi-dvm-firmware",
                     "iwlwifi-mvm-firmware", "iwlwifi-mld-firmware",
                     "iwlegacy-firmware"):
            self.assertIn(name, parity)

    def test_wifi_plugin_waits_on_the_supplicant_issue(self):
        """NetworkManager-wifi is uninstallable until the factory builds
        wpa_supplicant/iwd + wireless-regdb (utah-packages#136). It must
        stay out of the contract, and the comment must point at the real
        issue instead of the stale #133 number."""
        data = overlay()
        installed = (data["gnome"]["packages"] + data["parity"]["packages"]
                     + data["services"]["packages"] + data["build"]["packages"])
        self.assertNotIn("NetworkManager-wifi", installed)
        text = OVERLAY.read_text()
        self.assertIn("utah-packages#136", text)
        self.assertNotIn("utah-packages#133", text)


class TerminalTests(unittest.TestCase):
    def test_ptyxis_gap_is_tracked(self):
        """No enabled repository packages a terminal; the gap is recorded
        under [unavailable] with its factory issue, not left as a comment
        in the flatpak installer."""
        data = overlay()
        self.assertIn("ptyxis", data["unavailable"]["packages"])
        text = OVERLAY.read_text()
        self.assertIn("utah-packages#224", text)

    def test_live_session_defaults_to_ghostty(self):
        """The live ISO's only terminal is the Ghostty Flatpak: it must be
        on the dash and set as the default terminal handler."""
        script = (ROOT / "iso/live/src/configure-live.sh").read_text()
        self.assertIn("com.mitchellh.ghostty.desktop", script)
        self.assertIn("[org/gnome/desktop/default-applications/terminal]", script)
        self.assertIn(
            "exec='/var/lib/flatpak/exports/bin/com.mitchellh.ghostty'", script)


if __name__ == "__main__":
    unittest.main()
