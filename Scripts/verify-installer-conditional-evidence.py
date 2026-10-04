#!/usr/bin/env python3
"""Verify a current refusal plus immutable historical identical-source proof.

This is NOT the positive fixture verifier and never describes current eligibility.
The retained ZIP is the actual downloaded GitHub artifact, not a synthesized test.
"""
import argparse
import hashlib
import io
import json
from pathlib import Path
import re
import stat
import os
import zipfile

ROOT = Path(__file__).resolve().parent.parent
BASELINE = ROOT / 'Scripts/Fixtures/installer-idle-baseline'
BASELINE_SHA = 'bffd9235d07b79f62533ce631dbb44390389c52d'
ARCHIVE_SHA = 'e89b6f6dfb2dd251fbbd5417d9120b04008edb992978e898acb63ba7153543cb'
PROVIDER_SHA = 'a719b3074d80ba5bd432bf7a16e890960a72049c0f6e262ecb8253e470c21a32'
PROVIDER_BLOB = 'ce458ca68eef3e9912bcd59fddf0442ed17b2560'
CONTRACT_SHA = 'ffbe72889ee2fa07498938dc8282f82e07a7260147a673b0a08aefcd78196fd8'
REFUSAL = ('This version requires a complete, empty disk-image inventory and cannot rule out use through any attached image. '
           'Eject only images you opened yourself, then check again. Leave system-managed images alone; their presence can '
           'keep this action unavailable. MoeKit does not classify or eject images.')
UNSUPPORTED_FILE = 'idle-use-unsupported-environment.json'


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':')).encode()


def bounded_file(path, maximum):
    metadata = path.lstat()
    require(stat.S_ISREG(metadata.st_mode) and metadata.st_nlink == 1 and 0 < metadata.st_size <= maximum,
            f'not a bounded regular file: {path.name}')
    data = path.read_bytes()
    after = path.lstat()
    stable = ('st_dev', 'st_ino', 'st_mode', 'st_nlink', 'st_uid', 'st_gid', 'st_size', 'st_mtime_ns', 'st_ctime_ns')
    require(len(data) == metadata.st_size and all(getattr(after, key) == getattr(metadata, key) for key in stable)
            and getattr(after, 'st_flags', 0) == getattr(metadata, 'st_flags', 0), 'file changed during read')
    return data


def prior_positive(record):
    require(record.get('schema') == 1 and record.get('kind') == 'idle-use' and record.get('sourceSHA') == BASELINE_SHA,
            'prior positive provenance does not match')
    detail = record.get('detail', {})
    require(detail.get('result') == 'noUseObserved' and detail.get('observedUseControl') == 'true',
            'prior actual positive and duplicate control are both required')
    for key in ('sourceDevice', 'sourceInode'):
        require(isinstance(detail.get(key), str) and detail[key].isdigit() and int(detail[key]) > 0, 'invalid prior source identity')


def verify_baseline(baseline=BASELINE):
    archive = bounded_file(baseline / 'native-idle-use-bffd923.zip', 8192)
    require(digest(archive) == ARCHIVE_SHA, 'historical ZIP digest mismatch')
    provenance = json.loads(bounded_file(baseline / 'provenance.json', 8192))
    expected = {'schema': 1, 'repository': 'cosZone/MoeKit', 'sourceSHA': BASELINE_SHA,
                'runID': 37206181809, 'jobID': 111447725620, 'artifactID': 11304509105,
                'archiveSHA256': ARCHIVE_SHA, 'providerGitBlob': PROVIDER_BLOB,
                'providerSHA256': PROVIDER_SHA, 'compilerContractSHA256': CONTRACT_SHA,
                'priorHarnessSHA256': '52dbfa03f4c4bff46d697d75b4180b24255fe1f7d09ed7d816d99e4f288e8a31',
                'priorWorkflowSHA256': '641f4b600ee44bb74c33530664b9e36bdf72415d746af124878ae3be42fdb9cc'}
    require(all(provenance.get(k) == v for k, v in expected.items()), 'historical run/job/artifact provenance mismatch')
    contract = json.loads(bounded_file(baseline / 'compiler-contract.json', 8192))
    require(digest(canonical(contract)) == CONTRACT_SHA, 'historical compiler contract changed')
    # No extraction, paths, executable contents, or arbitrary members are used.
    with zipfile.ZipFile(io.BytesIO(archive)) as zipped:
        members = zipped.infolist()
        require(len(members) == 2 and {m.filename for m in members} == {'InstallerIdleEvidence/idle-use.json', 'InstallerIdleProbe.log'},
                'unexpected historical ZIP members')
        require(all(m.file_size <= 4096 and not m.is_dir() for m in members), 'historical ZIP exceeds member budget')
        record = json.loads(zipped.read('InstallerIdleEvidence/idle-use.json'))
        prior_positive(record)
        log = zipped.read('InstallerIdleProbe.log').decode('utf-8')
        require(f'Actual standalone native idle-use observation and exact fixture cleanup succeeded for {BASELINE_SHA}.' in log,
                'historical successful runtime log missing')
    return provenance, contract


def verify_conditional(record, source_sha, provider_bytes, invocation, baseline=BASELINE):
    require(re.fullmatch(r'[0-9a-f]{40}', source_sha) is not None, 'invalid current source SHA')
    require(digest(provider_bytes) == PROVIDER_SHA, 'provider source changed; new native positive proof required')
    blob = hashlib.sha1(b'blob ' + str(len(provider_bytes)).encode() + b'\0' + provider_bytes).hexdigest()
    require(blob == PROVIDER_BLOB, 'provider Git blob changed')
    provenance, contract = verify_baseline(baseline)
    require(invocation.get('schema') == 1 and invocation.get('sourceSHA') == source_sha and invocation.get('probeExit') == 3,
            'current invocation or distinct unsupported exit missing')
    require(invocation.get('providerSHA256') == PROVIDER_SHA and invocation.get('providerUnchangedAfterRun') is True,
            'current compiled provider binding missing')
    require(invocation.get('harnessSHA256') == digest(bounded_file(ROOT / 'Scripts/InstallerIdleProbe.swift', 256 * 1024)),
            'current compiled harness binding missing')
    require(invocation.get('contract') == contract and invocation.get('compilerContractSHA256') == CONTRACT_SHA,
            'actual compiler invocation/environment contract changed')
    require(invocation.get('resolvedCompiler') == contract['developerDirectory'] + '/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc',
            'resolved compiler binding missing')
    require(invocation.get('hostedRunner') == 'github-hosted' and invocation.get('architecture') == 'x86_64'
            and invocation.get('osMajor') == '15', 'current host contract mismatch')
    require(record.get('schema') == 1 and record.get('kind') == 'idle-use-unsupported-environment'
            and record.get('sourceSHA') == source_sha, 'not current unsupported-environment evidence')
    require(record.get('providerSHA256') == PROVIDER_SHA and record.get('compilerContractSHA256') == CONTRACT_SHA,
            'runtime source/compiler binding mismatch')
    detail = record.get('detail', {})
    required = {'result': 'unsupported-current-environment', 'fullProviderResult': 'unavailable-attached-images',
                'fullProviderReason': REFUSAL, 'handlePositiveControl': 'observedHandleUse',
                'handleNegativeControl': 'noHandleUseObserved', 'inventoryStable': 'true',
                'fixtureCleanup': 'verified', 'priorIdenticalSourcePositiveRequired': 'true'}
    require(all(detail.get(k) == v for k, v in required.items()), 'current exact refusal/fresh controls/cleanup not established')
    for key in ('sourceDevice', 'sourceInode', 'inventoryBeforeCount', 'inventoryAfterCount'):
        require(isinstance(detail.get(key), str) and detail[key].isdigit() and int(detail[key]) > 0,
                'current source identity or complete nonempty inventory missing')
    require(detail['inventoryBeforeCount'] == detail['inventoryAfterCount'] and int(detail['inventoryBeforeCount']) <= 64,
            'current inventory changed or exceeded its budget')
    return {'schema': 1, 'kind': 'idle-use-conditional-verification', 'sourceSHA': source_sha,
            'status': 'unsupported-current-environment-with-prior-identical-source-positive',
            'currentNoUseObserved': False, 'providerSHA256': PROVIDER_SHA, 'compilerContractSHA256': CONTRACT_SHA,
            'currentUnsupportedEvidenceSHA256': digest(canonical(record)),
            'priorPositive': {k: provenance[k] for k in expected_public_provenance()}}


def expected_public_provenance():
    return ('repository', 'sourceSHA', 'runID', 'jobID', 'artifactID', 'archiveSHA256', 'providerGitBlob', 'providerSHA256')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', type=Path, required=True)
    parser.add_argument('--source-sha', required=True)
    parser.add_argument('--invocation', type=Path, required=True)
    args = parser.parse_args()
    metadata = args.directory.lstat()
    require(stat.S_ISDIR(metadata.st_mode) and stat.S_IMODE(metadata.st_mode) == 0o700
            and metadata.st_uid == os.geteuid(), 'evidence directory must be private')
    require(not (args.directory / 'idle-use.json').exists(), 'positive and unsupported evidence cannot coexist')
    path = args.directory / UNSUPPORTED_FILE
    metadata = path.lstat()
    require(stat.S_IMODE(metadata.st_mode) == 0o600 and metadata.st_uid == os.geteuid(), 'unsupported evidence permissions changed')
    record = json.loads(bounded_file(path, 8192))
    invocation = json.loads(bounded_file(args.invocation, 16384))
    provider = bounded_file(ROOT / 'Sources/Installer/InstallerUseEvidence.swift', 256 * 1024)
    summary = verify_conditional(record, args.source_sha, provider, invocation)
    output = args.directory / 'idle-use-conditional-verification.json'
    fd = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'wb') as stream:
        stream.write(canonical(summary) + b'\n'); stream.flush(); os.fsync(stream.fileno())
    print('CURRENT ENVIRONMENT UNSUPPORTED: exact attached-image refusal and fresh handle controls verified. '
          f'Prior identical-source positive is from {BASELINE_SHA}; current noUseObserved was NOT established.')


if __name__ == '__main__':
    main()
