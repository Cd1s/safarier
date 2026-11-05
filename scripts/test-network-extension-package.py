#!/usr/bin/env python3
"""Pure preflight tests with synthetic dictionaries; NOT signing or provisioning evidence."""
import datetime
import hashlib
import importlib.util
import pathlib
import plistlib
import unittest

spec = importlib.util.spec_from_file_location("packaging", pathlib.Path(__file__).with_name("package-network-extension.py"))
packaging = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packaging)


class PackagingTests(unittest.TestCase):
    team = "TESTTEAM01"
    certificate = b"synthetic-validator-fixture-not-a-certificate"

    def profile(self, host=True):
        return {"ExpirationDate": datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=1),
                "TeamIdentifier": [self.team], "Platform": ["OSX"], "ProvisionsAllDevices": True,
                "DeveloperCertificates": [self.certificate], "Entitlements": packaging.signing_entitlements(self.team, host)}

    def validate(self, profile, host=True):
        packaging.validate_profile(profile, self.team, packaging.HOST if host else packaging.EXTENSION,
                                   hashlib.sha1(self.certificate).hexdigest().upper(), host)

    def test_exact_entitlements_and_expiration(self):
        self.validate(self.profile())
        self.validate(self.profile(False), False)
        for key, value in [("ExpirationDate", datetime.datetime(2020, 1, 1)), ("TeamIdentifier", ["OTHERTEAM1"]),
                           ("Platform", ["iOS"]), ("ProvisionsAllDevices", False), ("DeveloperCertificates", [b"wrong"])]:
            with self.subTest(key=key):
                profile = self.profile(); profile[key] = value
                with self.assertRaises(ValueError): self.validate(profile)

    def test_unauthorized_capabilities_rejected(self):
        for key, value in [(packaging.NE, ["app-proxy-provider"]), (packaging.GROUPS, ["unrelated"]),
                           (packaging.INSTALL, False), ("com.apple.application-identifier", self.team + ".*"),
                           ("get-task-allow", True), ("com.apple.developer.team-identifier", "OTHERTEAM1")]:
            with self.subTest(key=key):
                profile = self.profile(); profile["Entitlements"][key] = value
                with self.assertRaises(ValueError): self.validate(profile)

    def test_generated_bundle_and_service_namespace(self):
        info = packaging.extension_info(self.team, "1.3.0", "1")
        info = plistlib.loads(plistlib.dumps(info))
        entitlements = packaging.signing_entitlements(self.team, False)
        self.assertEqual(info["CFBundlePackageType"], "SYSX")
        self.assertEqual(info["LSMinimumSystemVersion"], "15.0")
        self.assertEqual(info["NetworkExtension"]["NEProviderClasses"]["com.apple.networkextension.app-proxy"], "SafarierTransparentProxyProvider")
        self.assertTrue(info["NetworkExtension"]["NEMachServiceName"].startswith(entitlements[packaging.GROUPS][0] + "."))
        self.assertNotIn(packaging.INSTALL, entitlements)
        self.assertEqual(packaging.signing_entitlements(self.team, True)[packaging.NE], entitlements[packaging.NE])


if __name__ == "__main__":
    unittest.main()
