#!/usr/bin/env python3
"""Require exact owned cache-render coverage plus actual displayed-frame evidence."""
import argparse
import importlib.util
import json
import math
from pathlib import Path

spec = importlib.util.spec_from_file_location('render_base', Path(__file__).with_name('verify-ui-render-artifacts.py'))
base = importlib.util.module_from_spec(spec)
spec.loader.exec_module(base)
SCENARIOS = ('first-use', 'trash-review', 'restore-review', 'permanent-review', 'uncertain-recovery')

def requirements(scenario, compact):
    if compact:
        prefix = 'cleanup.trash' if scenario == 'trash-review' else 'cleanup.recovery'
        return {prefix + '.confirm', prefix + '.cancel'}
    ids = {'cleanup.heading'}
    if scenario == 'trash-review':
        ids |= {'cleanup.trash.' + name for name in ('heading', 'effects', 'use-warning', 'workload-attestation', 'content-attestation', 'recovery-path', 'confirm', 'cancel', 'target.0.root', 'target.1.root')}
    elif scenario in ('restore-review', 'permanent-review'):
        ids |= {'cleanup.recovery.' + name for name in ('original-path', 'target.root', 'records', 'effects', 'confirm', 'cancel')}
        if scenario == 'permanent-review': ids.add('cleanup.recovery.attestation')
    elif scenario == 'uncertain-recovery':
        ids |= {'cleanup.unknown.warning', 'cleanup.unknown.effects'}
    return ids

def expected(language):
    names = {}
    for scenario in SCENARIOS:
        for style in ('light', 'dark'):
            name = f'cache-{scenario}-{language}-{style}'
            names[name] = (scenario, False)
            if scenario in ('trash-review', 'restore-review', 'permanent-review'):
                names[name + '-compact'] = (scenario, True)
    return names

def verify(directory, language):
    names = expected(language)
    images, scopes = {}, {}
    for test in json.loads((directory / 'manifest.json').read_text()):
        for attachment in test['attachments']:
            filename = attachment['exportedFileName']
            if Path(filename).name != filename: raise ValueError('nonlocal attachment')
            path = directory / filename
            if path.is_symlink(): raise ValueError('symlink attachment')
            label = attachment['suggestedHumanReadableName']
            for name in names:
                if label.startswith(name + '_') and path.suffix == '.png':
                    if name in images: raise ValueError('duplicate image')
                    images[name] = path
                if label.startswith(name + '-scope_') and path.suffix == '.json':
                    if name in scopes: raise ValueError('duplicate scope')
                    scopes[name] = json.loads(path.read_text())
    if set(images) != set(names) or set(scopes) != set(names): raise ValueError('missing exact cache render coverage')
    for name, (scenario, compact) in names.items():
        width, height = 760, 560 if compact else 2200
        if base.png_dimensions(images[name].read_bytes()) not in ((width, height), (width*2, height*2)):
            raise ValueError('wrong cache image dimensions')
        row = scopes[name]
        if row['schema'] != 1 or row['name'] != name or row['language'] != language or row['compact'] is not compact:
            raise ValueError('wrong render scope identity')
        if (row['width'], row['height']) != (width, height) or row['mutationCalls'] != 0: raise ValueError('mutating or wrong viewport scope')
        if row['scope'] != 'owned synthetic cleanup views; public SwiftUI bounds; no keyboard or VoiceOver acceptance': raise ValueError('wrong scope')
        ids = requirements(scenario, compact)
        if set(row['requiredIDs']) != ids or len(row['requiredIDs']) != len(ids): raise ValueError('missing mandatory IDs')
        frames = row['frames']
        if {item['id'] for item in frames} != ids or len(frames) != len(ids): raise ValueError('missing displayed frames')
        values = {item['id']: item['text'] for item in frames}
        for item in frames:
            x, y, w, h = item['bounds']
            if not all(isinstance(v, (int, float)) and math.isfinite(v) for v in (x,y,w,h)) or w <= 0 or h <= 0:
                raise ValueError('empty/nonfinite bounds')
            if x < -0.5 or y < -0.5 or x+w > width+0.5 or y+h > height+0.5: raise ValueError('clipped mandatory content')
            if not item['text'].strip(): raise ValueError('empty displayed content')
        chinese = language == 'zh-Hans'
        if not compact and values['cleanup.heading'] != ('原生缓存清理' if chinese else 'Native cache cleanup'): raise ValueError('locale fallback')
        if scenario == 'trash-review':
            if values['cleanup.trash.confirm'] != ('将所选缓存移入废纸篓' if chinese else 'Move selected caches to Trash'): raise ValueError('wrong confirmation label')
            if not compact:
                for index, leaf in enumerate(('one', 'two')):
                    if values[f'cleanup.trash.target.{index}.root'] != f'"/Synthetic/Caches/{leaf}"': raise ValueError('wrong target path')
                if values['cleanup.trash.recovery-path'] != '"/Synthetic/Recovery"': raise ValueError('wrong recovery path')
        elif scenario in ('restore-review', 'permanent-review'):
            label = ('恢复此缓存' if chinese else 'Restore this cache') if scenario == 'restore-review' else ('永久删除此缓存' if chinese else 'Permanently delete this cache')
            if values['cleanup.recovery.confirm'] != label: raise ValueError('wrong recovery label')
            if not compact:
                if values['cleanup.recovery.original-path'] != '"/Synthetic/Caches/one"' or values['cleanup.recovery.target.root'] != '"/Synthetic/Trash/one"': raise ValueError('wrong recovery targets')
    return len(names)

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('directory', type=Path)
    parser.add_argument('language', choices=('en','zh-Hans'))
    args = parser.parse_args()
    print(f'Verified {verify(args.directory,args.language)} exact cache renders and displayed bounds; not keyboard/VoiceOver acceptance')
