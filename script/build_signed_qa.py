#!/usr/bin/env python3
"""Build an isolated, locally signed QA app without altering the installed app.

Uses an existing Apple Development identity; it never creates certificates or
exports keys. --qa-preview selects synthetic providers and skips CLI migration.
"""
import argparse
import pathlib
import re
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--build-number', type=int)
args = parser.parse_args()
root = pathlib.Path(__file__).resolve().parent.parent
identities = subprocess.run(['security', 'find-identity', '-v', '-p', 'codesigning'], capture_output=True, text=True, check=True).stdout
matches = re.findall(r'([A-F0-9]{40}) "(Apple Development:[^"\n]+)"', identities)
if not matches:
    raise SystemExit('An existing Apple Development signing identity is required for signed QA.')
fingerprint, name = matches[0]
pem = subprocess.run(['security', 'find-certificate', '-c', name, '-p'], capture_output=True, check=True).stdout
subject = subprocess.run(['openssl', 'x509', '-noout', '-subject', '-nameopt', 'RFC2253'], input=pem, capture_output=True, check=True).stdout.decode()
team = re.search(r'(?:^|,)OU=([A-Z0-9]{10})(?:,|$)', subject).group(1)
output = root / 'build/SignedQA'
log = root / 'build/qa/upgrade-3.0.0/signed-qa-build.log'
log.parent.mkdir(parents=True, exist_ok=True)
command = ['xcodebuild', '-quiet', '-project', 'QuotAI.xcodeproj', '-scheme', 'QuotAI', '-configuration', 'Debug', '-destination', 'platform=macOS,arch=arm64', '-derivedDataPath', str(output), '-clonedSourcePackagesDirPath', str(root / 'build/SourcePackages'), f'CODE_SIGN_IDENTITY={fingerprint}', f'DEVELOPMENT_TEAM={team}', 'CODE_SIGN_STYLE=Manual', 'CODE_SIGNING_ALLOWED=YES', 'CODE_SIGNING_REQUIRED=YES', 'QUOTAI_APP_BUNDLE_ID=com.willhsu.QuotAI.qa', f'QUOTAI_APP_GROUP={team}.com.willhsu.QuotAI.qa', 'QUOTAI_URL_SCHEME=quotai-qa', 'QUOTAI_DISPLAY_NAME=QuotAI QA']
if args.build_number is not None:
    if args.build_number < 1:
        raise SystemExit('Build number must be positive.')
    command += [f'CURRENT_PROJECT_VERSION={args.build_number}']
with log.open('w') as stream:
    result = subprocess.run(command + ['build'], cwd=root, stdout=stream, stderr=subprocess.STDOUT)
if result.returncode:
    raise SystemExit(f'QA build failed; see {log}')
app = output / 'Build/Products/Debug/QuotAI.app'
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
print(app)
print('Launch with --qa-preview; optional --qa-widget and --qa-shortcut use synthetic data.')
