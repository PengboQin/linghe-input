"""Local source/PE resource checks only. Never loads or executes a Windows DLL."""
import importlib.util, pathlib, re, struct, unittest
ROOT=pathlib.Path(__file__).resolve().parents[2]
SPEC=importlib.util.spec_from_file_location('offline_pack', ROOT/'tools/build_offline_installer.py')
PACK=importlib.util.module_from_spec(SPEC);SPEC.loader.exec_module(PACK)

class BrandingTests(unittest.TestCase):
    def test_explicit_negative_resource_id_and_actual_bytes(self):
        resource=(ROOT/'windows/resources/BrandingResource.h').read_text()
        identifier=int(re.search(r'LINGHE_BRANDING_ICON\s+(\d+)',resource).group(1))
        self.assertEqual(identifier,101)
        self.assertIn('LINGHE_BRANDING_ICON ICON "AppIcon.ico"',(ROOT/'windows/resources/PrivateInput.rc').read_text())
        declaration=(ROOT/'windows/src/TsfBranding.h').read_text()
        self.assertIn('static_cast<ULONG>(-static_cast<LONG>(BrandingIconResource))',declaration)
        dll=ROOT/'build/windows-tsf/x64/PrivateInputTSF.dll'
        groups,_=PACK.pe_resources(dll,14)
        self.assertIn(identifier,groups)
        # Negative -101 denotes embedded group resource ID101, not ordinal zero.
        icon=PACK.verify_icon_resources(dll,ROOT/'windows/resources/AppIcon.ico',group_id=identifier)
        self.assertGreater(icon['images'],0)
    def test_only_keyboard_and_supported_systray_capability_registered(self):
        source=(ROOT/'windows/src/Registration.cpp').read_text()
        calls=re.findall(r'->RegisterCategory\(CLSID_PrivateInput,([^,]+),CLSID_PrivateInput\)',source)
        self.assertEqual(set(calls),{'GUID_TFCAT_TIP_KEYBOARD','linghe::tsf::SystrayCategory'})
        self.assertIn('BrandingProfileIconIndex',source)
        self.assertIn('if(addedSystray)categories->UnregisterCategory',source)
        self.assertIn('if(hasSystray){hr=categories->UnregisterCategory',source)
        self.assertIn('profileEnabledBefore,0',source)
    def test_installer_snapshots_new_reverse_mapping_without_version_change(self):
        source=(ROOT/'windows/installer/Setup.cpp').read_text()
        self.assertIn('StringFromGUID2(linghe::tsf::SystrayCategory,systray,39)',source)
        self.assertIn('snapshots(bool includeSystray=false)',source)
        self.assertIn('auto before=snapshots(true)',source)
        self.assertIn('result.emplace_back(hive,std::wstring(L"Software\\\\Microsoft\\\\CTF\\\\Category\\\\Category\\\\")+systray',source)
    def test_native_probe_does_not_activate_or_register(self):
        source=(ROOT/'windows/tests/tsf_branding_probe.cpp').read_text()
        for call in ['RegisterCategory(', 'RegisterProfile(', 'ActivateProfile(', 'RegSetValue', 'ShellExecute', 'CreateProcess']:
            self.assertNotIn(call,source)
        self.assertIn('LOAD_LIBRARY_AS_DATAFILE_EXCLUSIVE|LOAD_LIBRARY_AS_IMAGE_RESOURCE',source)
        self.assertIn('ExtractIconExW(',source)

if __name__=='__main__':unittest.main()
