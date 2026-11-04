#!/usr/bin/env python3
"""Verify deleted-code ownership with synthetic processes, never real widgets.

Usage: widget_upgrade_process_probe.py <compiled-widget-probe> <signing-identity> <team>
Uses an existing signing key without exporting it or registering any app bundle.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('probe', type=Path)
parser.add_argument('identity')
parser.add_argument('team')
args = parser.parse_args()
probe = args.probe.resolve(strict=True)
results = {}
with tempfile.TemporaryDirectory(prefix='quotai-deleted-widget-') as directory:
    root = Path(directory)
    for case, identifier, signer in [
        ('own_signed', 'com.willhsu.QuotAI.QuotaWidget', args.identity),
        ('other_signed', 'com.example.OtherWidget', args.identity),
        ('own_adhoc', 'com.willhsu.QuotAI.QuotaWidget', '-'),
    ]:
        executable = root / case / 'QuotAIWidget'
        executable.parent.mkdir()
        shutil.copyfile('/bin/sleep', executable)
        executable.chmod(0o755)
        subprocess.run(['codesign', '--force', '--sign', signer, '--identifier', identifier, str(executable)],
                       check=True, capture_output=True)
        process = subprocess.Popen([str(executable), '60'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        def owns(team=args.team, user=os.getuid()):
            return subprocess.check_output([
                str(probe), '--owns-process', str(process.pid), team, 'com.willhsu.QuotAI', str(user)
            ], text=True).strip() == 'owned'
        try:
            time.sleep(0.1)
            before = owns()
            wrong_team = owns(team='OTHERTEAM1')
            wrong_user = owns(user=os.getuid() + 1)
            executable.unlink()
            after = owns()
            alive = process.poll() is None
            results[case] = dict(before=before, after_deletion=after, alive=alive,
                                 wrong_team=wrong_team, wrong_user=wrong_user)
            expected = case == 'own_signed'
            assert before == expected and after == expected and alive
            assert not wrong_team and not wrong_user
        finally:
            if process.poll() is None:
                process.terminate()
            process.wait(timeout=5)
print(json.dumps(results, indent=2))
