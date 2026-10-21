"""Cross-component installer/COM identity invariant; does not run or install code."""
import pathlib
import re
import unittest
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[2]


def declared_clsid():
    source = (ROOT / "windows/src/PrivateInputTSF.h").read_text()
    match = re.search(r"CLSID_PrivateInput\s*=\s*\{([^;]+)\};", source)
    if not match:
        raise ValueError("Missing COM identity declaration")
    parts = [int(value, 16) for value in re.findall(r"0x([0-9a-fA-F]+)", match[1])]
    if len(parts) != 11:
        raise ValueError("Unexpected GUID initializer")
    tail = bytes(parts[3:])
    return uuid.UUID(fields=(parts[0], parts[1], parts[2], tail[0], tail[1], int.from_bytes(tail[2:], "big")))


class RegistrationIdentityTests(unittest.TestCase):
    def test_installer_uses_the_dll_identity(self):
        source = (ROOT / "windows/installer/Setup.cpp").read_text()
        self.assertEqual(str(declared_clsid()), "46a94bf1-285e-41d7-93f2-8b45e770c172")
        self.assertIn('#include "../src/PrivateInputTSF.h"', source)
        self.assertIn('StringFromGUID2(CLSID_PrivateInput,value,39)', source,
                      "Installer must derive identity from the DLL declaration")
        self.assertNotRegex(source, r'OwnClass\[\]\s*=\s*L"\{',
                            "Do not introduce another manually duplicated CLSID")

    def test_no_retired_mistyped_identity_in_operational_sources(self):
        retired = "46a94bf1-285e-41d7-930f-8b45e770c172"
        files = list((ROOT / "tools").glob("pc-*.ps1"))
        files += list((ROOT / "windows/src").glob("*.cpp"))
        for path in files:
            with self.subTest(path=str(path.relative_to(ROOT))):
                self.assertFalse(retired in path.read_text().lower(),
                                 "Readback must not misreport another GUID as the actual installation")

    def test_native_dll_paths_have_consistent_separators(self):
        source = (ROOT / "windows/installer/Setup.cpp").read_text()
        self.assertNotIn('L"AMD64/PrivateInputTSF.dll"', source,
                         "The Win32 module loader returns backslashes; construct path components separately")
        registration = (ROOT / "windows/src/Registration.cpp").read_text()
        self.assertIn('lexically_normal().make_preferred()', registration,
                      "Existing-server validation must accept equivalent Windows path separators")

    def test_all_installer_path_identity_checks_use_normalization(self):
        source = (ROOT / "windows/installer/Setup.cpp").read_text()
        self.assertNotIn('_wcsicmp(', source,
                         "Do not compare unnormalized paths in registry/ARP/uninstall checks")
        self.assertIn('samePath(registered(),dll)', source)
        self.assertIn('samePath(registryString(key,L"InstallLocation"),root)', source)
        self.assertIn('auto preferred=normalizedPath(path).wstring()', source)


if __name__ == "__main__":
    unittest.main()
