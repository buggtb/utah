"""Utah's Secure Boot chain must stay complete: key, signing, cert, enrollment.

The model mirrors ublue-os/akmods: one long-lived Utah MOK signs everything
Fedora's key does not (the source-built OGC kernel, the NVIDIA modules), the
public certificate ships in the image, and the user enrolls it once. Any link
missing silently produces flavors that cannot boot under Secure Boot, so each
link is asserted here.
"""
import re
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
KEYDIR = ROOT / "packages/secureboot"
PRIV = KEYDIR / "utah-mok.priv"
DER = KEYDIR / "utah-mok.der"


class MokKeyTests(unittest.TestCase):
    def test_keypair_exists(self):
        self.assertTrue(PRIV.is_file(), "Utah MOK private key is missing")
        self.assertTrue(DER.is_file(), "Utah MOK public certificate is missing")

    def test_keypair_matches(self):
        """The committed .priv must be the key for the committed .der."""
        modulus = ["openssl", "rsa", "-modulus", "-noout", "-in", str(PRIV)]
        pubkey_der = subprocess.run(
            ["openssl", "rsa", "-in", str(PRIV), "-pubout", "-outform", "DER"],
            capture_output=True, check=True,
        ).stdout
        cert_pubkey = subprocess.run(
            ["openssl", "x509", "-inform", "DER", "-in", str(DER),
             "-pubkey", "-noout"],
            capture_output=True, check=True,
        ).stdout
        cert_pubkey_der = subprocess.run(
            ["openssl", "pkey", "-pubin", "-outform", "DER"],
            input=cert_pubkey, capture_output=True, check=True,
        ).stdout
        self.assertEqual(pubkey_der, cert_pubkey_der)
        result = subprocess.run(modulus, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_private_key_is_not_executable(self):
        # Git only preserves the exec bit, so a 600 mode cannot survive a
        # fresh clone; what the tree CAN guarantee is that the key never
        # gains +x. (Local checkouts should still chmod 600.)
        self.assertEqual(PRIV.stat().st_mode & 0o111, 0)


class SigningWiringTests(unittest.TestCase):
    def test_ogc_kernel_is_signed_after_install(self):
        script = (ROOT / "scripts/install-ogc-kernel.sh").read_text()
        self.assertIn('"$(dirname "$0")/utah-sign-secureboot" kernel "$release"', script)
        self.assertIn('"$(dirname "$0")/utah-sign-secureboot" modules "$release"', script)
        self.assertIn("sbsigntools", script)

    def test_nvidia_modules_are_signed_after_install(self):
        script = (ROOT / "scripts/install-nvidia.sh").read_text()
        self.assertIn('"$(dirname "$0")/utah-sign-secureboot" modules "$release"', script)

    def test_nvidia_ensures_openssl_for_signing(self):
        """The signer shells out to `openssl`, which may be gone.

        install-ogc-kernel.sh removes its toolchain before this script runs
        in the same layer, and flavor images never carried the CLI -- without
        an ensure step the module signing dies with 'openssl: command not
        found' after the whole module compile.
        """
        script = (ROOT / "scripts/install-nvidia.sh").read_text()
        self.assertIn("command -v openssl", script)
        self.assertIn('nvidia_absent+=("openssl")', script)
        # The ensure must precede the signing call, not follow it.
        self.assertLess(
            script.index("command -v openssl"),
            script.index('"$(dirname "$0")/utah-sign-secureboot" modules'),
        )

    def test_sign_helper_verifies_what_it_signs(self):
        script = (ROOT / "scripts/sign-utah-secureboot.sh").read_text()
        self.assertIn("sbsign --cert", script)
        self.assertIn("sbverify --cert", script)
        self.assertIn("sign-file", script)
        # A local build without key material warns instead of failing.
        self.assertIn("leaving", script)

    def test_ogc_tree_ships_an_executable_sign_file(self):
        """The external-module tree must carry a built sign-file binary.

        Newer trees ship scripts/sign-file.c instead of the old Perl
        scripts/sign-file, which kbuild never compiles when signing is
        external. Without an explicit gcc build the NVIDIA module step dies
        on 'no sign-file for <release>' after a full kernel compile.
        """
        installer = (ROOT / "scripts/install-ogc-kernel.sh").read_text()
        self.assertIn("scripts/sign-file.c", installer)
        self.assertIn('-o scripts/sign-file scripts/sign-file.c -lcrypto', installer)
        self.assertIn('test -x "$kernel_build/scripts/sign-file"', installer)

    def test_signer_vmlinuz_path_matches_installer(self):
        """The signer must sign where the installer lays vmlinuz down.

        install-ogc-kernel.sh writes /boot/vmlinuz-<release> (a source build
        has no kernel-core package for the Fedora-layout modules-dir copy);
        a signer that only checks /usr/lib/modules/<release>/vmlinuz fails
        the kernel-cache build with 'no vmlinuz for <release>'.
        """
        installer = (ROOT / "scripts/install-ogc-kernel.sh").read_text()
        self.assertIn('arch/x86/boot/bzImage "/boot/vmlinuz-${release}"', installer)
        signer = (ROOT / "scripts/sign-utah-secureboot.sh").read_text()
        self.assertIn('/boot/vmlinuz-${release}', signer)

    def test_private_key_reaches_only_the_kernel_cache_builder(self):
        main = (ROOT / "Containerfile").read_text()
        self.assertNotIn("utah-mok.priv", main)
        cache = (ROOT / "Containerfile.kernel").read_text()
        self.assertIn("packages/secureboot/utah-mok.priv", cache)
        self.assertIn("UTAH_SECUREBOOT_KEYDIR", cache)

    def test_public_cert_ships_in_the_image(self):
        main = (ROOT / "Containerfile").read_text()
        self.assertIn("packages/secureboot/utah-mok.der /etc/pki/utah/certs/utah-mok.der", main)

    def test_enrollment_tooling_is_installed(self):
        main = (ROOT / "Containerfile").read_text()
        self.assertIn("enroll-secure-boot-key.sh:utah-enroll-secure-boot-key", main)
        enroll = (ROOT / "scripts/enroll-secure-boot-key.sh").read_text()
        self.assertIn("mokutil --import", enroll)
        self.assertIn("/etc/pki/utah/certs/utah-mok.der", enroll)
        contract = (ROOT / "packages/utah.toml").read_text()
        self.assertIn('"mokutil"', contract)

    def test_cache_key_moves_with_the_key(self):
        tag = (ROOT / "scripts/kernel-cache-tag.sh").read_text()
        self.assertIn("scripts/sign-utah-secureboot.sh", tag)
        self.assertIn("packages/secureboot/utah-mok.priv", tag)
        self.assertIn("packages/secureboot/utah-mok.der", tag)

    def test_live_layer_requires_signed_bootloaders(self):
        live = (ROOT / "iso/live/Containerfile").read_text()
        self.assertIn("rpm -q shim-x64 grub2-efi-x64", live)
        self.assertNotIn("systemd-boot-unsigned", live)


if __name__ == "__main__":
    unittest.main()
