#!/usr/bin/env python3
"""Validate the actual packaged app, widget and Sparkle, including nested signatures."""
import argparse
import pathlib
import plistlib
import re
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('app', type=pathlib.Path)
parser.add_argument('--universal', action='store_true')
args = parser.parse_args()
app = args.app.resolve(strict=True)
def info(bundle):
    return plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
def details(bundle):
    result = subprocess.run(['codesign', '-dvv', str(bundle)], capture_output=True, text=True, check=True)
    return result.stderr
main = info(app)
widget = app / 'Contents/PlugIns/QuotAIWidget.appex'
wi = info(widget)
assert wi['CFBundleIdentifier'] == main['CFBundleIdentifier'] + '.QuotaWidget', 'Widget bundle identifier mismatch'
for field in ['CFBundleShortVersionString', 'CFBundleVersion', 'QuotAIAppGroup', 'QuotAIURLScheme']:
    assert wi[field] == main[field], f'Widget/app {field} mismatch'
for bundle in [app, widget]:
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(bundle)], check=True)
    arches = subprocess.run(['lipo', '-archs', str(bundle / 'Contents/MacOS' / info(bundle)['CFBundleExecutable'])], capture_output=True, text=True, check=True).stdout.split()
    if args.universal:
        assert set(arches) == {'arm64', 'x86_64'}, f'{bundle.name} missing universal slices'
if int(main['CFBundleVersion']) >= 54:
    for bundle in [app, widget]:
        for name in ['CodexProviderMark.png', 'ClaudeProviderMark.png', 'AntigravityProviderMark.png']:
            assert (bundle / 'Contents/Resources' / name).is_file(), f'{bundle.name} missing provider logo {name}'
assert (app / 'Contents/Frameworks/Sparkle.framework').is_dir(), 'Sparkle framework missing'
framework = app / 'Contents/Frameworks/Sparkle.framework'
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(framework)], check=True)
sparkle = plistlib.loads((framework / 'Resources/Info.plist').read_bytes())
assert sparkle['CFBundleShortVersionString'] == '2.9.6', 'Sparkle version must match the pinned dependency'
assert main.get('SUVerifyUpdateBeforeExtraction') is True
assert main.get('SUSendProfileInfo') is False
team_match = re.search(r'^TeamIdentifier=([A-Z0-9]{10})$', details(app), re.M)
if team_match:
    team = team_match.group(1)
    assert main['QuotAIAppGroup'].startswith(team + '.'), 'App group does not use the signing team'
    for bundle in [app, widget]:
        assert f'TeamIdentifier={team}' in details(bundle), 'App and widget must share the signing team'
        result = subprocess.run(['codesign', '-d', '--entitlements', ':-', str(bundle)], capture_output=True, check=True)
        entitlements = plistlib.loads(result.stdout)
        if int(main['CFBundleVersion']) >= 61:
            assert not entitlements.get('com.apple.security.get-task-allow', False), 'Release must not allow debugger attachment'
        assert main['QuotAIAppGroup'] in entitlements.get('com.apple.security.application-groups', []), 'Signed group entitlement missing'
        if bundle == widget:
            assert entitlements.get('com.apple.security.app-sandbox') is True
    print('Team-signed app and widget: matching groups and entitlements verified.')
else:
    print('Ad-hoc build: widget group sharing is unavailable; the app explains this in Settings.')
print(f'Validated QuotAI {main["CFBundleShortVersionString"]} ({main["CFBundleVersion"]}), widget and Sparkle 2.9.6.')
