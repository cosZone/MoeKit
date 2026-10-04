#!/usr/bin/env python3
"""Run the fixed native compiler recipe and verify positive OR distinct refusal evidence."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('conditional', ROOT / 'Scripts/verify-installer-conditional-evidence.py')
proof = importlib.util.module_from_spec(spec)
spec.loader.exec_module(proof)


def main():
    os.chdir(ROOT)
    env = os.environ.copy()
    sha = env.get('SOURCE_SHA', '')
    proof.require(env.get('GITHUB_ACTIONS') == 'true' and env.get('RUNNER_ENVIRONMENT') == 'github-hosted', 'hosted CI required')
    proof.require(env.get('MOEKIT_INSTALLER_SOURCE_SHA') == sha and len(sha) == 40, 'exact current source SHA required')
    proof.require(subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip() == sha, 'checkout does not match source SHA')
    contract = json.loads(proof.bounded_file(proof.BASELINE / 'compiler-contract.json', 8192))
    proof.require(platform.system() == 'Darwin' and platform.machine() == contract['architecture']
                  and platform.mac_ver()[0].split('.')[0] == contract['osMajor'], 'native host contract mismatch')
    proof.require(env.get('DEVELOPER_DIR') == contract['developerDirectory'], 'Xcode developer-directory contract mismatch')
    proof.require(not any(env.get(key) for key in ('SDKROOT', 'TOOLCHAINS', 'SWIFT_EXEC', 'SWIFTFLAGS', 'OTHER_SWIFT_FLAGS',
                                                 'MACOSX_DEPLOYMENT_TARGET', 'DYLD_INSERT_LIBRARIES', 'DYLD_LIBRARY_PATH', 'DYLD_FRAMEWORK_PATH')),
                  'unreviewed compiler or dynamic-loader override')
    proof.require(contract['compiler'] == 'swiftc' and contract['hostedRunner'] == env['RUNNER_ENVIRONMENT']
                  and contract['runner'] == 'macos-15-intel', 'compiler/runner contract mismatch')
    expected_compiler = Path(contract['developerDirectory']) / 'Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc'
    located_compiler = subprocess.check_output(['/usr/bin/xcrun', '--find', 'swiftc'], env=env, text=True).strip()
    proof.require(Path(located_compiler).resolve() == expected_compiler.resolve(), 'xcrun selected a different Xcode compiler')
    path_compiler = shutil.which('swiftc', path=env.get('PATH'))
    proof.require(path_compiler is not None and (path_compiler == '/usr/bin/swiftc'
                  or Path(path_compiler).resolve() == expected_compiler.resolve()), 'PATH selected an unreviewed Swift compiler')
    provider_path = ROOT / 'Sources/Installer/InstallerUseEvidence.swift'
    harness_path = ROOT / 'Scripts/InstallerIdleProbe.swift'
    provider = proof.bounded_file(provider_path, 256 * 1024)
    harness = proof.bounded_file(harness_path, 256 * 1024)
    provider_sha, harness_sha = proof.digest(provider), proof.digest(harness)
    contract_sha = proof.digest(proof.canonical(contract))
    directory = ROOT / 'InstallerIdleEvidence'
    proof.require(env.get('MOEKIT_INSTALLER_EVIDENCE_DIR') == str(directory), 'unexpected evidence directory')
    directory.mkdir(mode=0o700)  # Fresh owned CI directory only; never replace.
    build = Path(tempfile.mkdtemp(prefix='MoeKit-idle-probe.', dir=env['RUNNER_TEMP']))
    binary = build / 'moekit-installer-idle-probe'
    arguments = [str(binary) if value == '<owned-output>' else value for value in contract['arguments']]
    subprocess.run([path_compiler, *arguments], env=env, check=True)
    proof.require(proof.digest(proof.bounded_file(provider_path, 256 * 1024)) == provider_sha
                  and proof.digest(proof.bounded_file(harness_path, 256 * 1024)) == harness_sha, 'compiled source changed')
    env.update({'MOEKIT_INSTALLER_IDLE_PROBE': '1', 'MOEKIT_INSTALLER_CONDITIONAL_IDLE': '1',
                'MOEKIT_INSTALLER_PROVIDER_SHA256': provider_sha, 'MOEKIT_INSTALLER_COMPILER_CONTRACT_SHA256': contract_sha})
    completed = subprocess.run([str(binary)], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    proof.require(len(completed.stdout) <= 512 * 1024, 'native diagnostic output exceeded budget')
    with (ROOT / 'InstallerIdleProbe.log').open('xb') as log:
        log.write(completed.stdout)
    sys.stdout.buffer.write(completed.stdout); sys.stdout.flush()
    unchanged = (proof.digest(proof.bounded_file(provider_path, 256 * 1024)) == provider_sha
                 and proof.digest(proof.bounded_file(harness_path, 256 * 1024)) == harness_sha)
    proof.require(unchanged, 'source changed during runtime observation')
    invocation = {'schema': 1, 'sourceSHA': sha, 'probeExit': completed.returncode, 'providerSHA256': provider_sha,
                  'harnessSHA256': harness_sha, 'providerUnchangedAfterRun': unchanged, 'contract': contract,
                  'compilerContractSHA256': contract_sha, 'hostedRunner': env['RUNNER_ENVIRONMENT'],
                  'resolvedCompiler': str(expected_compiler),
                  'architecture': platform.machine(), 'osMajor': platform.mac_ver()[0].split('.')[0]}
    invocation_path = ROOT / 'InstallerIdleInvocation.json'
    with invocation_path.open('xb') as output:
        output.write(proof.canonical(invocation) + b'\n')
    if completed.returncode == 0:
        proof.require(not (directory / proof.UNSUPPORTED_FILE).exists(), 'mixed positive/unsupported evidence')
        subprocess.run([sys.executable, 'Scripts/verify-installer-fixture-evidence.py', '--directory', str(directory),
                        '--source-sha', sha, '--kinds', 'idle-use'], check=True)
        summary = 'Actual current full-provider positive and duplicate control passed.\n'
    elif completed.returncode == 3:
        subprocess.run([sys.executable, 'Scripts/verify-installer-conditional-evidence.py', '--directory', str(directory),
                        '--source-sha', sha, '--invocation', str(invocation_path)], check=True)
        summary = ('Current environment UNSUPPORTED: complete stable nonempty image inventory and exact provider refusal; '
                   'fresh handle controls passed. Current noUseObserved was NOT established. '
                   f'Prior identical-source positive verified from {proof.BASELINE_SHA}, '
                   'run37206181809/job111447725620/artifact11304509105.\n')
    else:
        raise RuntimeError(f'Native probe failed with exit {completed.returncode}; no conditional acceptance.')
    print(summary.strip())
    if env.get('GITHUB_STEP_SUMMARY'):
        with open(env['GITHUB_STEP_SUMMARY'], 'a') as output:
            output.write(summary)


if __name__ == '__main__':
    main()
