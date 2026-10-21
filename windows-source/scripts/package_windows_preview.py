# -*- coding: utf-8 -*-
from pathlib import Path
import shutil,subprocess,hashlib,json,zipfile
R=Path(__file__).resolve().parents[1];E=R/'evidence/cross-platform47-mac37-20261016';stage=R/'artifacts/LingheInput-Windows-x64-0.1.0';payload=stage/'payload';runtime=payload/'AMD64';runtime.mkdir(parents=True,exist_ok=True)
cert=R/'secrets/windows-development/development.crt';key=R/'secrets/windows-development/development.key';tool=R/'.tools/osslsigncode-build/osslsigncode';signed=[]
for source,target in [(R/'build/windows-tsf/x64/LingheInputSetup.exe',stage/'LingheInputSetup.exe'),(R/'build/windows-tsf/x64/LingheInputSettings.exe',stage/'LingheInputSettings.exe'),(R/'build/windows-tsf/x64/PrivateInputTSF.dll',runtime/'PrivateInputTSF.dll')]:
 temporary=target.with_name(target.name+'.signed-next')
 if temporary.exists():temporary.unlink()
 subprocess.run([str(tool),'sign','-certs',str(cert),'-key',str(key),'-h','sha256','-n','Linghe Input Development','-in',str(source),'-out',str(temporary)],check=True,stdout=subprocess.DEVNULL)
 with (E/(target.stem+'-authenticode.log')).open('w') as out:subprocess.run([str(tool),'verify','-CAfile',str(cert),'-in',str(temporary)],check=True,stdout=out,stderr=subprocess.STDOUT)
 temporary.replace(target)
 signed.append(target.name)
shutil.copy2(stage/'LingheInputSettings.exe',runtime/'LingheInputSettings.exe')
shutil.copy2(R/'build/rime/windows-x64/lib/librime.dll',runtime/'librime.dll')
for p in (R/'resources/rime').rglob('*'):
 if p.is_file() and p.suffix!='.gram':
  q=runtime/'data/rime'/p.relative_to(R/'resources/rime');q.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(p,q)
shutil.copytree(R/'docs/stages/P1/licenses',stage/'licenses',dirs_exist_ok=True)
(stage/'使用说明.txt').write_text('灵鹤输入法 Windows11 x64 工程体验版\n\n1. 解压整个文件夹，双击 LingheInputSetup.exe，按系统要求完成管理员授权。\n2. 在输入法列表中启用灵鹤输入法；Win+空格选择。可先在记事本试打 nihao、csm、shih。\n3. 左右选中候选，空格确认；上下展开网格并移动；数字选择当前行，滚轮浏览。\n4. 打开 LingheInputSettings.exe 调整收起数量与展开行列。\n5. 若需停用，从命令行运行 LingheInputSetup.exe --unregister，个人数据保留。\n\n这是自签工程包，尚未在你的实体Windows验收。首批只接离线Rime基础输入；Apple端的语义模型、复杂纠错和资料同步尚未迁入。多个宿主共同访问词库的日用稳定性也待验证。遇到问题可切回原输入法，本安装器不修改默认输入源，不安装根证书、不关闭安全防护、不删除个人数据。\n安装原型尚不含正式自动更新/开始菜单/完整卸载界面。\n',encoding='utf-8-sig')
files={str(p.relative_to(payload)):hashlib.sha256(p.read_bytes()).hexdigest() for p in payload.rglob('*') if p.is_file() and p.name!='manifest.sha256'}
(payload/'manifest.sha256').write_text('version=0.1.0-win1\n'+''.join(h+'  '+p+'\n' for p,h in sorted(files.items())))
archive=R/'artifacts/LingheInput-Windows11-x64-0.1.0-preview.zip'
temporaryZip=archive.with_suffix('.zip.new')
with zipfile.ZipFile(temporaryZip,'w',compression=zipfile.ZIP_DEFLATED) as z:
 for p in stage.rglob('*'):
  if p.is_file():z.write(p,str(p.relative_to(stage.parent)))
with zipfile.ZipFile(temporaryZip) as z:assert z.testzip() is None
temporaryZip.replace(archive)
report={'version':'0.1.0-win1','arch':'AMD64','payloadFiles':files,'zipSHA256':hashlib.sha256(archive.read_bytes()).hexdigest(),'authenticode':'self-signed development, digest verified against own certificate; not publicly trusted','signedFiles':signed,'executedOnWindows':False,'vmUsed':False,'defaultInputSourceChanged':False,'privateRelayConfigurationIncluded':False}
(E/'windows-package-audit.json').write_text(json.dumps(report,indent=2));print({'windowsPreviewPackaged':True,'payloadFiles':len(files),'bytes':archive.stat().st_size})
