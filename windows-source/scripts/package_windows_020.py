# -*- coding: utf-8 -*-
"""Package the 0.2.0-win1 Windows preview: signed setup, settings, TSF DLL,
Rime runtime plus the repair syllable list."""
from pathlib import Path
import shutil
import subprocess
import hashlib
import json
import zipfile

R = Path(__file__).resolve().parents[1]
E = R / 'evidence/windows-0.2.0-20261017'
E.mkdir(parents=True, exist_ok=True)
VERSION = '0.2.0-win1'
stage = R / 'artifacts/LingheInput-Windows-x64-0.2.0'
payload = stage / 'payload'
runtime = payload / 'AMD64'
runtime.mkdir(parents=True, exist_ok=True)
cert = R / 'secrets/windows-development/development.crt'
key = R / 'secrets/windows-development/development.key'
tool = R / '.tools/osslsigncode-build/osslsigncode'
signed = []
for source, target in [
    (R / 'build/windows-tsf/x64/LingheInputSetup.exe', stage / 'LingheInputSetup.exe'),
    (R / 'build/windows-tsf/x64/LingheInputSettings.exe', stage / 'LingheInputSettings.exe'),
    (R / 'build/windows-tsf/x64/PrivateInputTSF.dll', runtime / 'PrivateInputTSF.dll'),
]:
    temporary = target.with_name(target.name + '.signed-next')
    if temporary.exists():
        temporary.unlink()
    subprocess.run([str(tool), 'sign', '-certs', str(cert), '-key', str(key), '-h', 'sha256',
                    '-n', 'Linghe Input Development', '-in', str(source), '-out', str(temporary)],
                   check=True, stdout=subprocess.DEVNULL)
    with (E / (target.stem + '-authenticode.log')).open('w') as out:
        subprocess.run([str(tool), 'verify', '-CAfile', str(cert), '-in', str(temporary)],
                       check=True, stdout=out, stderr=subprocess.STDOUT)
    temporary.replace(target)
    signed.append(target.name)
shutil.copy2(stage / 'LingheInputSettings.exe', runtime / 'LingheInputSettings.exe')
shutil.copy2(R / 'build/rime/windows-x64/lib/librime.dll', runtime / 'librime.dll')
for p in (R / 'resources/rime').rglob('*'):
    if p.is_file() and p.suffix != '.gram':
        q = runtime / 'data/rime' / p.relative_to(R / 'resources/rime')
        q.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(p, q)
# Repair lattice needs the public syllable list; without it no repair rows are
# offered at all, so a missing file must fail packaging instead of shipping.
syllables = R / 'resources/semantic/pinyin-syllables.txt'
lines = [line.strip() for line in syllables.read_text(encoding='utf-8').splitlines() if line.strip()]
assert 300 <= len(lines) <= 600 and all(0 < len(x) <= 8 and x.isascii() and x.islower() for x in lines), 'syllable list rejected'
target = runtime / 'data/semantic/pinyin-syllables.txt'
target.parent.mkdir(parents=True, exist_ok=True)
shutil.copy2(syllables, target)
shutil.copytree(R / 'docs/stages/P1/licenses', stage / 'licenses', dirs_exist_ok=True)
(stage / '使用说明.txt').write_text(
'''灵鹤输入法 Windows11 x64 工程体验版 0.2.0-win1

1. 解压整个文件夹，双击 LingheInputSetup.exe，按系统要求完成管理员授权。安装器不会改变你的默认输入源。
2. 在输入法列表中启用「灵鹤输入法」，Win+空格 切换过来。先在记事本试打。
3. 基本输入：nihao、zhongguo、shijie；简拼 csm（吃什么）、shih（时候）、zguo（中国）都支持。
4. 错漏换序纠正（本版新增）：linaxaing → 联想、haoo → 好、zhongguoo → 中国、shijei → 世界。
   纠错候选排在正常候选之后，只有词典里真实存在的词才会出现。
5. 候选操作：左右键移动并高亮，空格或回车确认；数字键选当前行第 N 个；上下键展开成网格，方向键移动，
   再次上下或 Esc 收起；鼠标点击可选项，滚轮翻页。
6. 打开 LingheInputSettings.exe，可分别调整单行候选数、展开列数、展开行数（各 3-9，默认 6/6/6），保存后下次输入生效。
7. 数字和标点直接上屏，不会被输入法拦下；没有待选拼音时输入 1.4 这类内容不会开启拼音组合。
8. 停用：命令行运行 LingheInputSetup.exe --unregister，个人词库和已安装文件都保留。
   升级到更新版本直接运行新的安装器，旧版目录保留，词库不覆盖、不清空。

这是自签工程包，尚未在你的实体 Windows 上验收。首批只接离线 Rime 基础输入与上方纠错；
Apple 端语义模型、附近上下文重排、英文混合联想和跨设备同步尚未迁入。密码框、只读区域与安全桌面
不加载本站引擎，直接交回系统处理。遇到问题随时切回原输入法；安装器不安装根证书、不关闭安全防护、
不删除个人数据。安装原型尚不含自动更新、开始菜单和完整卸载界面。
''', encoding='utf-8-sig')
files = {str(p.relative_to(payload)): hashlib.sha256(p.read_bytes()).hexdigest()
         for p in payload.rglob('*') if p.is_file() and p.name != 'manifest.sha256'}
(payload / 'manifest.sha256').write_text(
    'version=' + VERSION + '\n' + ''.join(h + '  ' + p + '\n' for p, h in sorted(files.items())))
archive = R / 'artifacts/LingheInput-Windows11-x64-0.2.0-preview.zip'
temporaryZip = archive.with_suffix('.zip.new')
with zipfile.ZipFile(temporaryZip, 'w', compression=zipfile.ZIP_DEFLATED) as z:
    for p in stage.rglob('*'):
        if p.is_file():
            z.write(p, str(p.relative_to(stage.parent)))
with zipfile.ZipFile(temporaryZip) as z:
    assert z.testzip() is None
temporaryZip.replace(archive)
report = {
    'version': VERSION, 'arch': 'AMD64', 'payloadFiles': files,
    'zipSHA256': hashlib.sha256(archive.read_bytes()).hexdigest(),
    'syllables': len(lines),
    'authenticode': 'self-signed development, digest verified against own certificate; not publicly trusted',
    'signedFiles': signed, 'executedOnWindows': False, 'vmUsed': False,
    'defaultInputSourceChanged': False, 'privateRelayConfigurationIncluded': False,
    'crossCompiledFrom': 'macOS LLVM-MinGW x86_64-w64-mingw32',
}
(E / 'windows-package-audit.json').write_text(json.dumps(report, indent=2))
print(json.dumps({'packaged': True, 'version': VERSION, 'payloadFiles': len(files),
                  'bytes': archive.stat().st_size, 'syllables': len(lines)}))
