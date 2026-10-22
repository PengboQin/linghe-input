#!/usr/bin/env python3
"""Host JVM + actual JNI/core admission and SDK Java compilation, no APK/device."""
from pathlib import Path
import datetime, hashlib, json, os, subprocess

ROOT = Path(__file__).resolve().parents[2]
BUILD = ROOT / 'build/android-mainland-admission'
EVIDENCE = ROOT / 'evidence/android-mainland-admission-20261021'
SDK = ROOT / '.tools/android'
OBJECTS = ROOT / 'build/apple-prediction26-mac/Build/Intermediates.noindex/PrivateInput.build/Release/PrivateInput-MacIME.build/Objects-normal/arm64'

def main():
    BUILD.mkdir(parents=True, exist_ok=True)
    EVIDENCE.mkdir(parents=True, exist_ok=True)
    sources = sorted((ROOT / 'android/app/src/main/java').rglob('*.java'))
    tracked = sources + [ROOT / 'android/app/src/main/cpp/jni.cpp', ROOT / 'android/tests/host/MainlandCandidateAdmissionTest.java', ROOT / 'core/include/private_input.h', ROOT / 'build/mainland-policy/core.o']
    before = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in tracked}
    rows = []
    def run(name, command):
        command = list(map(str, command))
        result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, timeout=120)
        (EVIDENCE / (name + '.log')).write_text(result.stdout + result.stderr)
        rows.append({'name': name, 'exitCode': result.returncode, 'command': command})
        (EVIDENCE / 'commands.json').write_text(json.dumps(rows, indent=2) + '\n')
        if result.returncode:
            raise RuntimeError(name + ' failed; inspect its evidence log')
        return result.stdout
    run('jni-host-link', ['xcrun', 'clang++', '-std=c++17', '-dynamiclib', '-I' + str(SDK/'jdk/include'), '-I' + str(SDK/'jdk/include/darwin'), '-Icore/include', 'android/app/src/main/cpp/jni.cpp', 'build/mainland-policy/core.o', *[OBJECTS / (name + '.o') for name in ['language_scoring','gram_db','gram_encoding','octagram']], '-Lbuild/rime/macos-arm64/lib', '-lrime', '-lyaml-cpp', '-lleveldb', '-lmarisa', '-lopencc', '-Xlinker', '-dead_strip', '-o', BUILD/'liblinghe.dylib'])
    run('android-ndk-jni-syntax', [SDK/'ndk/28.2.13676358/toolchains/llvm/prebuilt/darwin-x86_64/bin/aarch64-linux-android26-clang++','-std=c++17','-Icore/include','-fsyntax-only','android/app/src/main/cpp/jni.cpp'])
    minimal = BUILD/'classes'; minimal.mkdir(exist_ok=True)
    run('host-java-compile', [SDK/'jdk/bin/javac', '--release', '8', '-encoding', 'UTF-8', '-d', minimal, 'android/app/src/main/java/live/linghe/privateinput/NativeCore.java', 'android/app/src/main/java/live/linghe/privateinput/GlyphAvailability.java', 'android/tests/host/MainlandCandidateAdmissionTest.java'])
    output = run('host-jni-admission', [SDK/'jdk/bin/java', '-Djava.library.path=' + str(BUILD), '-cp', minimal, 'live.linghe.privateinput.MainlandCandidateAdmissionTest'])
    generated = BUILD/'generated/live/linghe/privateinput'; generated.mkdir(parents=True, exist_ok=True)
    (generated/'SyncBuildConfig.java').write_text('package live.linghe.privateinput; final class SyncBuildConfig {static final String DEFAULT_ENDPOINT="";}\n')
    (generated/'R.java').write_text('package live.linghe.privateinput; public final class R {public static final class drawable {public static final int app_icon=0;}}\n')
    classes = BUILD/'sdk-classes'; classes.mkdir(exist_ok=True)
    classpath = os.pathsep.join(map(str, [SDK/'platforms/android-36/android.jar', ROOT/'vendor/bouncycastle/bcprov-android.jar', ROOT/'vendor/zxing/core-3.5.3.jar']))
    run('sdk-java-compile', [SDK/'jdk/bin/javac','--release','8','-encoding','UTF-8','-classpath',classpath,'-d',classes,*sources,*sorted(generated.glob('*.java'))])
    stable = all(hashlib.sha256((ROOT/name).read_bytes()).hexdigest() == digest for name,digest in before.items())
    result = {'checkedAtUTC': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'result': 'passed' if stable else 'sourceChanged', 'hostChecks': 46, 'output': output.strip(), 'actualJNIAdapter': True, 'actualSharedCoreABI': True, 'allAndroidJavaSDKCompile': True, 'androidNDKJNISyntax':True, 'javaSourceCount': len(sources), 'compileOnlyResources': True, 'sourcesStable': stable, 'sourceSHA256': before, 'androidNDKBuild': False, 'nativeSessionCreated': False, 'realIMEInputRun': False, 'deviceAccess': False, 'apkBuilt': False, 'installed': False, 'productionChanged': False}
    (EVIDENCE/'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(output.strip()); print('PASS Android SDK compilation; APK/native-session/device tests not run')
    if not stable:
        raise RuntimeError('Sources changed during the checks')

if __name__ == '__main__':
    main()
