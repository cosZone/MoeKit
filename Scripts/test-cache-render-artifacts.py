#!/usr/bin/env python3
"""Synthetic negative controls for cache render evidence. No UI is operated."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

def load(name, file):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(file))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

verify = load('cache_render_verify', 'verify-cache-render-artifacts.py')
images = load('cache_render_images', 'test-ui-render-artifacts.py')

class CacheRenderTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='MoeKit-cache-render-evidence-')
        self.root = Path(self.temp.name)
    def tearDown(self): self.temp.cleanup()
    def fixture(self, language='en'):
        attachments = []
        for name, (scenario, compact) in verify.expected(language).items():
            height = 560 if compact else 2200
            ids = sorted(verify.requirements(scenario, compact))
            labels = {'cleanup.heading': '原生缓存清理' if language == 'zh-Hans' else 'Native cache cleanup',
                      'cleanup.trash.confirm': '将所选缓存移入废纸篓' if language == 'zh-Hans' else 'Move selected caches to Trash',
                      'cleanup.trash.target.0.root': '"/Synthetic/Caches/one"', 'cleanup.trash.target.1.root': '"/Synthetic/Caches/two"',
                      'cleanup.trash.recovery-path': '"/Synthetic/Recovery"', 'cleanup.recovery.original-path': '"/Synthetic/Caches/one"',
                      'cleanup.recovery.target.root': '"/Synthetic/Trash/one"'}
            labels['cleanup.recovery.confirm'] = ('恢复此缓存' if language == 'zh-Hans' else 'Restore this cache') if scenario == 'restore-review' else ('永久删除此缓存' if language == 'zh-Hans' else 'Permanently delete this cache')
            row = dict(schema=1, name=name, language=language, compact=compact, width=760, height=height, mutationCalls=0,
                       scope='owned synthetic cleanup views; public SwiftUI bounds; no keyboard or VoiceOver acceptance', requiredIDs=ids,
                       frames=[dict(id=id, text=labels.get(id,'Synthetic displayed content'), bounds=[2,2,40,20]) for id in ids])
            (self.root / (name+'.png')).write_bytes(images.png(760,height))
            (self.root / (name+'.json')).write_text(json.dumps(row))
            attachments += [dict(exportedFileName=name+'.png', suggestedHumanReadableName=name+'_0_TEST.png'),
                            dict(exportedFileName=name+'.json', suggestedHumanReadableName=name+'-scope_0_TEST.json')]
        (self.root / 'manifest.json').write_text(json.dumps([dict(attachments=attachments)]))
    def mutate(self, change):
        path = self.root / 'cache-permanent-review-en-light.json'
        row = json.loads(path.read_text()); change(row); path.write_text(json.dumps(row))
    def test_exact_bilingual_coverage(self):
        for language in ('en','zh-Hans'):
            self.fixture(language)
            self.assertEqual(verify.verify(self.root,language),16)
    def test_missing_scope(self):
        self.fixture(); (self.root / 'cache-first-use-en-light.json').unlink()
        with self.assertRaises((ValueError,FileNotFoundError)): verify.verify(self.root,'en')
    def test_clipped_control(self):
        self.fixture(); self.mutate(lambda row: row['frames'][0].update(bounds=[0,2199,100,30]))
        with self.assertRaisesRegex(ValueError,'clipped'): verify.verify(self.root,'en')
    def test_missing_attestation(self):
        self.fixture(); self.mutate(lambda row: row['frames'].pop())
        with self.assertRaisesRegex(ValueError,'frames'): verify.verify(self.root,'en')
    def test_mutation_claim(self):
        self.fixture(); self.mutate(lambda row: row.update(mutationCalls=1))
        with self.assertRaisesRegex(ValueError,'mutating'): verify.verify(self.root,'en')
    def test_wrong_target(self):
        self.fixture()
        def change(row):
            next(frame for frame in row['frames'] if frame['id']=='cleanup.recovery.target.root')['text']='"/Other/Unapproved"'
        self.mutate(change)
        with self.assertRaisesRegex(ValueError,'targets'): verify.verify(self.root,'en')
    def test_wrong_confirmation_language(self):
        self.fixture()
        def change(row):
            next(frame for frame in row['frames'] if frame['id']=='cleanup.recovery.confirm')['text']='Wrong label'
        self.mutate(change)
        with self.assertRaisesRegex(ValueError,'label'): verify.verify(self.root,'en')
    def test_nonfinite_geometry(self):
        self.fixture(); self.mutate(lambda row: row['frames'][0].update(bounds=[float('nan'),2,20,20]))
        with self.assertRaisesRegex(ValueError,'nonfinite'): verify.verify(self.root,'en')

if __name__ == '__main__': unittest.main()
