#!/usr/bin/env python3
"""Check public source inventory and local links without reading user databases."""
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import unquote

root = Path(__file__).resolve().parent.parent
files = subprocess.check_output(['git', 'ls-files', '-z'], cwd=root).decode().split('\0')[:-1]
if not files:
    raise SystemExit('No staged/tracked public files; stage the audited source first.')
errors = []
for name in files:
    p = root / name
    if p.is_symlink() or name.startswith(('work/', 'output/', 'evidence/', 'prompts/', 'docs/design/')):
        errors.append(f'Unsupported public file: {name}')
    if (p.name.startswith('.env') and p.name != '.env.example') or p.suffix.lower() in {'.db','.sqlite','.sqlite3','.pem','.key','.jks','.keystore','.p8','.p12','.mobileprovision','.apk','.aab'}:
        errors.append(f'Private or distribution artifact: {name}')
    if p.suffix in {'.md','.dart','.ts','.tsx','.py','.ps1','.sh','.json','.toml','.yml','.yaml'}:
        text = p.read_text(encoding='utf-8')
        forbidden = ['https://' + 'chatgpt.com/', 'C:' + '\\Users\\', 'C:' + '\\Development\\', 'github.com/ayu0201/' + 'university_schedule_app', 'github.com/ayumu-homma/' + 'university_schedule_app/']
        for marker in forbidden:
            if marker in text:
                errors.append(f'Internal reference: {name}')
        if p.suffix == '.md':
            targets = re.findall(r'!?\[[^\]]*\]\(([^)\s]+)', text) + re.findall(r'(?:src|href)="([^"]+)"', text)
            for target in targets:
                if re.match(r'^(?:https?:|mailto:|tel:|data:|#)', target):
                    continue
                target = unquote(target.strip('<>').split('#')[0].split('?')[0])
                if target and not (p.parent / target).exists():
                    errors.append(f'Broken local link: {name} -> {target}')
release_version = (root / 'VERSION').read_text(encoding='utf-8').strip()
mobile_version = re.search(r'^version: (\d+\.\d+\.\d+)\+([1-9]\d*)$', (root / 'apps/mobile/pubspec.yaml').read_text(), re.MULTILINE)
if not re.fullmatch(r'\d+\.\d+\.\d+', release_version) or not mobile_version or mobile_version.group(1) != release_version:
    errors.append('Mobile release version is inconsistent')
if errors:
    print('\n'.join(errors), file=sys.stderr)
    raise SystemExit(1)
print(f'Public inventory and local links: PASS ({len(files)} files). Secret/content/license audits remain separate.')
