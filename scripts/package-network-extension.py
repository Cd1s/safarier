#!/usr/bin/env python3
"""Opt-in Developer ID packaging. Never installs, activates, notarizes or modifies the input app."""
import argparse
import datetime
import hashlib
import pathlib
import plistlib
import re
import shutil
import subprocess
import tempfile

HOST = "sh.safarier.app"
EXTENSION = HOST + ".network-extension"
NE = "com.apple.developer.networking.networkextension"
GROUPS = "com.apple.security.application-groups"
INSTALL = "com.apple.developer.system-extension.install"
ROOT = pathlib.Path(__file__).resolve().parent.parent


def run(*args):
    result = subprocess.run(args, cwd=ROOT, capture_output=True)
    if result.returncode:
        # Profiles and signing identities must not be dumped into build logs.
        raise ValueError(f"{pathlib.Path(args[0]).name} failed (exit {result.returncode})")
    return result.stdout


def validate_profile(profile, team, bundle, identity, host=False):
    entitlements = profile.get("Entitlements", {})
    expiration = profile.get("ExpirationDate")
    if not isinstance(expiration, datetime.datetime) or expiration.replace(tzinfo=datetime.timezone.utc) <= datetime.datetime.now(datetime.timezone.utc):
        raise ValueError("profile expired or missing expiration")
    if team not in profile.get("TeamIdentifier", []) or entitlements.get("com.apple.developer.team-identifier") != team:
        raise ValueError("profile team mismatch")
    if not profile.get("ProvisionsAllDevices") or "OSX" not in profile.get("Platform", []):
        raise ValueError("requires a Developer ID macOS profile")
    app_id = entitlements.get("com.apple.application-identifier", entitlements.get("application-identifier"))
    if app_id != f"{team}.{bundle}":
        raise ValueError("profile requires the exact application identifier")
    if "app-proxy-provider-systemextension" not in entitlements.get(NE, []):
        raise ValueError("profile lacks the system-extension app-proxy entitlement")
    if f"{team}.sh.safarier.proxy" not in entitlements.get(GROUPS, []):
        raise ValueError("profile lacks the shared application group")
    if host and entitlements.get(INSTALL) is not True:
        raise ValueError("host profile lacks system-extension.install")
    if not any(hashlib.sha1(cert).hexdigest().upper() == identity for cert in profile.get("DeveloperCertificates", [])):
        raise ValueError("signing certificate is not included in the profile")
    if entitlements.get("get-task-allow") or entitlements.get("com.apple.security.get-task-allow"):
        raise ValueError("debug signing profiles are not supported")


def signing_entitlements(team, host):
    values = {NE: ["app-proxy-provider-systemextension"], GROUPS: [f"{team}.sh.safarier.proxy"],
              "com.apple.developer.team-identifier": team,
              "com.apple.application-identifier": f"{team}.{HOST if host else EXTENSION}"}
    if host:
        values[INSTALL] = True
    else:
        values.update({"com.apple.security.app-sandbox": True, "com.apple.security.network.client": True,
                       "com.apple.security.network.server": True})
    return values


def extension_info(team, version, build):
    return {"CFBundleIdentifier": EXTENSION, "CFBundleExecutable": "SafarierProxyExtension",
            "CFBundleName": "SafarierProxyExtension", "CFBundlePackageType": "SYSX",
            "CFBundleShortVersionString": version, "CFBundleVersion": build,
            "LSMinimumSystemVersion": "15.0", "SafarierTeamIdentifier": team,
            "NSSystemExtensionUsageDescription": "将独立环境的 WebRTC 流量送往其代理。",
            "NetworkExtension": {"NEMachServiceName": f"{team}.sh.safarier.proxy.control",
                                 "NEProviderClasses": {"com.apple.networkextension.app-proxy": "SafarierTransparentProxyProvider"}}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=pathlib.Path, required=True, help="app freshly built by scripts/build-app.sh")
    parser.add_argument("--output", type=pathlib.Path, required=True, help="new .app path; must not exist")
    parser.add_argument("--team", required=True)
    parser.add_argument("--identity", required=True, help="40-digit Developer ID Application certificate SHA-1")
    parser.add_argument("--host-profile", type=pathlib.Path, required=True)
    parser.add_argument("--extension-profile", type=pathlib.Path, required=True)
    parser.add_argument("--check-only", action="store_true")
    args = parser.parse_args()
    identity = args.identity.upper()
    if not re.fullmatch(r"[A-Z0-9]{10}", args.team) or not re.fullmatch(r"[0-9A-F]{40}", identity):
        raise ValueError("invalid team or certificate fingerprint")
    if args.output.exists() or args.output.suffix != ".app":
        raise ValueError("output must be a new .app path")
    source = args.app.resolve(strict=True)
    if source == args.output.resolve() or source in args.output.resolve().parents:
        raise ValueError("output cannot replace or be nested inside the input app")
    info = plistlib.loads((source / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != HOST:
        raise ValueError("input app bundle identifier mismatch")
    identities = run("security", "find-identity", "-v", "-p", "codesigning").decode()
    if not any(identity in line and '"Developer ID Application:' in line for line in identities.splitlines()):
        raise ValueError("selected Developer ID Application signing identity is unavailable")
    for path, bundle, host in [(args.host_profile, HOST, True), (args.extension_profile, EXTENSION, False)]:
        profile = plistlib.loads(run("security", "cms", "-D", "-i", str(path.resolve(strict=True))))
        validate_profile(profile, args.team, bundle, identity, host)
    if args.check_only:
        print("Profile and identity preflight passed. No build, signing or installation performed.")
        return
    build_args = ["swift", "build", "-c", "release", "--arch", "arm64", "--arch", "x86_64", "--product", "SafarierProxyExtension"]
    run(*build_args)
    binary_dir = pathlib.Path(run(*build_args, "--show-bin-path").decode().strip())
    shutil.copytree(source, args.output, symlinks=True)
    output = args.output.resolve()
    ext = output / "Contents/Library/SystemExtensions" / (EXTENSION + ".systemextension")
    (ext / "Contents/MacOS").mkdir(parents=True, exist_ok=False)
    shutil.copy2(binary_dir / "SafarierProxyExtension", ext / "Contents/MacOS/SafarierProxyExtension")
    (ext / "Contents/Info.plist").write_bytes(plistlib.dumps(extension_info(args.team, info["CFBundleShortVersionString"], info["CFBundleVersion"])))
    info["SafarierTeamIdentifier"] = args.team
    info["NSSystemExtensionUsageDescription"] = "将独立环境的 WebRTC 流量送往其代理。"
    (output / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    shutil.copy2(args.host_profile, output / "Contents/embedded.provisionprofile")
    shutil.copy2(args.extension_profile, ext / "Contents/embedded.provisionprofile")
    with tempfile.TemporaryDirectory(prefix="safarier-sign-") as temporary:
        host_ent = pathlib.Path(temporary) / "host.plist"
        ext_ent = pathlib.Path(temporary) / "extension.plist"
        host_ent.write_bytes(plistlib.dumps(signing_entitlements(args.team, True)))
        ext_ent.write_bytes(plistlib.dumps(signing_entitlements(args.team, False)))

        def sign(path, ent=None):
            command = ["codesign", "--force", "--sign", identity, "--options", "runtime", "--timestamp"]
            if ent:
                command += ["--entitlements", str(ent)]
            run(*command, str(path))

        # Sign every nested Mach-O and code bundle, deepest first, including the sing-box helper.
        for path in sorted(output.rglob("*"), key=lambda p: len(p.parts), reverse=True):
            if path.is_symlink() or path == ext or ext in path.parents:
                continue
            if path.is_file() and b"Mach-O" in run("file", "-b", str(path)):
                sign(path)
            elif path.is_dir() and path.suffix in {".framework", ".xpc", ".bundle", ".app"}:
                sign(path)
        sign(ext, ext_ent)
        sign(output, host_ent)
        run("codesign", "--verify", "--deep", "--strict", str(output))
    print(f"Signed experimental app: {output}\nNot installed, activated, notarized or media-validated.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, plistlib.InvalidFileException) as error:
        raise SystemExit(str(error))
