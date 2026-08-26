from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "FixSthenoUIWindows.m").read_text()
PLIST = (ROOT / "FixSthenoUIWindows.plist").read_text()
CONTROL = (ROOT / "control").read_text()


class FunctionalCandidateContractTests(unittest.TestCase):
    def test_package_is_new_springboard_only_candidate(self):
        self.assertIn("Version: 0.0.4", CONTROL)
        self.assertEqual(PLIST.count('"com.apple.springboard"'), 1)
        self.assertNotIn("com.apple.UIKit", PLIST)

    def test_candidate_uses_exact_keyboard_arbiter_abi_gates(self):
        for selector in (
            "launchAdvisorWithOmniscientDelegate:",
            "handlerForPID:",
            "setWindowHostingPID:active:",
            "owner",
            "processIdentifier",
        ):
            self.assertIn(selector, SOURCE)
        for encoding in (
            "@24@0:8@16",
            "@16@0:8",
            "@20@0:8i16",
            "v24@0:8i16B20",
        ):
            self.assertIn(encoding, SOURCE)

    def test_candidate_is_not_the_rejected_geometry_or_global_level_fix(self):
        for forbidden in (
            "UIRemoteKeyboardWindow",
            "remoteKeyboardWindowForScreen:create:",
            "setWindowLevel:",
            "setFrame:",
            "setBounds:",
            "zPosition",
            "setKeyWindow",
            "makeKeyAndVisible",
        ):
            self.assertNotIn(forbidden, SOURCE)

    def test_only_springboard_filter_and_no_uikit_domain_remain(self):
        self.assertNotIn("SXDProcessDomainUIKit", SOURCE)
        self.assertNotIn("SXDProcessDomainUnknown", SOURCE)
        self.assertNotIn("SXDUIKit", SOURCE)
        self.assertNotIn("com.apple.UIKit", SOURCE + PLIST)

    def test_deactivation_clears_local_pair_before_external_call(self):
        match = re.search(
            r"static void SXDDeactivateHost\(void\) \{(?P<body>.*?)\n\}",
            SOURCE,
            re.S,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertLess(body.index("SXDActiveHandle = nil"), body.index("SXDArbiterHostSelectorName"))
        self.assertLess(body.index("SXDActivePID = 0"), body.index("SXDArbiterHostSelectorName"))


if __name__ == "__main__":
    unittest.main()
