#!/usr/bin/env python3
"""Sign a prepared archive with the project Keychain key; write a reviewable feed.

No upload, git mutation or private-key export. Pass the official Sparkle 2.9.6
bin directory with --sparkle-bin (or SPARKLE_BIN).
"""
import argparse
import base64
import datetime
import hashlib
import os
import pathlib
import plistlib
import subprocess
import tempfile
import urllib.parse
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(__file__).resolve().parent.parent
NS = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', NS)
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('archive', type=pathlib.Path)
parser.add_argument('--sparkle-bin', type=pathlib.Path, default=os.environ.get('SPARKLE_BIN', str(ROOT / 'build/SparkleSDK/distribution/bin')))
parser.add_argument('--download-url')
parser.add_argument('--output', type=pathlib.Path)
parser.add_argument('--qa-feed', action='store_true', help='Allow loopback HTTP only for the isolated QA bundle.')
args = parser.parse_args()
archive = args.archive.resolve(strict=True)
if archive.suffix != '.zip':
    parser.error('Expected the ZIP created by --package-release.')
with tempfile.TemporaryDirectory(prefix='quotai-update-') as directory:
    subprocess.run(['ditto', '-x', '-k', str(archive), directory], check=True)
    apps = list(pathlib.Path(directory).glob('*.app'))
    if len(apps) != 1:
        parser.error('Archive must contain one top-level app.')
    app = apps[0]
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    version, build = info['CFBundleShortVersionString'], info['CFBundleVersion']
    expected_id = 'com.willhsu.QuotAI.qa' if args.qa_feed else 'com.willhsu.QuotAI'
    if info['CFBundleIdentifier'] != expected_id:
        parser.error('Unexpected bundle identifier for this feed.')
    key = subprocess.run([str(args.sparkle_bin / 'generate_keys'), '--account', 'com.willhsu.QuotAI', '-p'], check=True, capture_output=True, text=True).stdout.strip()
    if len(base64.b64decode(key, validate=True)) != 32 or key != info.get('SUPublicEDKey'):
        parser.error('The archive public key does not match the project signing key.')
url = args.download_url or f'https://github.com/williamhsu218/QuotAI/releases/download/v{version}/{urllib.parse.quote(archive.name)}'
parsed = urllib.parse.urlsplit(url)
loopback = args.qa_feed and parsed.scheme == 'http' and parsed.hostname in ['localhost', '127.0.0.1', '::1']
if parsed.scheme != 'https' and not loopback:
    parser.error('Update downloads require HTTPS (or explicit QA loopback HTTP).')
if parsed.username or parsed.password or not parsed.hostname:
    parser.error('Invalid download URL.')
signature = subprocess.run([str(args.sparkle_bin / 'sign_update'), '--account', 'com.willhsu.QuotAI', '-p', str(archive)], check=True, capture_output=True, text=True).stdout.strip()
subprocess.run([str(args.sparkle_bin / 'sign_update'), '--account', 'com.willhsu.QuotAI', '--verify', str(archive), signature], check=True)
feed = ET.parse(ROOT / 'Updates/appcast.xml')
channel = feed.getroot().find('channel')
for previous in list(channel.findall('item')):
    if previous.findtext(f'{{{NS}}}version') == build:
        channel.remove(previous)
item = ET.Element('item')
ET.SubElement(item, 'title').text = f'QuotAI {version}'
ET.SubElement(item, 'pubDate').text = datetime.datetime.now(datetime.timezone.utc).strftime('%a, %d %b %Y %H:%M:%S %z')
ET.SubElement(item, f'{{{NS}}}version').text = build
ET.SubElement(item, f'{{{NS}}}shortVersionString').text = version
ET.SubElement(item, f'{{{NS}}}minimumSystemVersion').text = '14.0'
ET.SubElement(item, f'{{{NS}}}releaseNotesLink').text = f'https://github.com/williamhsu218/QuotAI/releases/tag/v{version}'
ET.SubElement(item, 'enclosure', {'url': url, 'length': str(archive.stat().st_size), 'type': 'application/octet-stream', f'{{{NS}}}edSignature': signature})
channel.insert(3, item)
output = args.output or archive.parent / f'appcast-{version}.xml'
output.parent.mkdir(parents=True, exist_ok=True)
ET.indent(feed, space='  ')
feed.write(output, encoding='utf-8', xml_declaration=True)
print(f'FEED_PATH={output.resolve()}')
print(f'SHA256={hashlib.sha256(archive.read_bytes()).hexdigest()}')
print('Signature verified. Publish the archive before promoting this feed to Updates/appcast.xml.')
