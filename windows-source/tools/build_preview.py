# -*- coding: utf-8 -*-
from pathlib import Path
from shared_resources import canonical_resources
import argparse,subprocess,json,zipfile,hashlib,shutil,re,os
r=Path(__file__).resolve().parents[1]
public_resources=canonical_resources(r)
subprocess.run([os.sys.executable, str(r/'tools/check_shared_core.py')], check=True)
p=argparse.ArgumentParser(description='Build a local unsigned Windows preview, without installation or publishing.');p.add_argument('--toolchain',type=Path,required=True);p.add_argument('--cmake',type=Path,required=True);p.add_argument('--version',default='0.6.0-win1');p.add_argument('--no-zip',action='store_true',help='Prepare payload without a duplicate zip before offline EXE packaging');a=p.parse_args()
if not re.fullmatch(r'0\.\d{1,3}\.\d{1,3}-win[1-9]\d{0,2}',a.version):p.error('Expected a version such as 0.2.3-win1')
version=a.version.split('-win')[0]
stage=r/('artifacts/LingheInput-Windows-x64-'+version)
archive=r/('artifacts/LingheInput-Windows11-x64-'+version+'-preview.zip')
if stage.exists() or archive.exists():p.error('Candidate exists; preserve it and select a new version')
source=(r/'windows/installer/Setup.cpp').read_text()
if ('L"'+a.version+'"') not in source or ('"'+a.version+'"') not in source:p.error('Installer version does not match candidate')
e=r/('evidence/windows'+version.replace('.',''));e.mkdir(parents=True,exist_ok=True)
temp=r/'build/tmp';temp.mkdir(parents=True,exist_ok=True);env=os.environ.copy();env['TMPDIR']=str(temp)
compiler=a.toolchain/'bin/x86_64-w64-mingw32-clang++';rc=a.toolchain/'bin/x86_64-w64-mingw32-windres';assert compiler.is_file() and rc.is_file()
# Toolchain can be read from an existing installation; all build writes stay here.
commands=[[str(a.cmake),'-S',str(r/'windows'),'-B',str(r/'build/windows-tsf/x64'),'-DCMAKE_SYSTEM_NAME=Windows','-DCMAKE_CXX_COMPILER='+str(compiler),'-DCMAKE_RC_COMPILER='+str(rc),'-DPRIVATE_RIME_PREFIX='+str(r/'build/rime/windows-x64'),'-DPRIVATE_SODIUM_PREFIX='+str(r/'build/sodium-membership/x64'),'-DCMAKE_BUILD_TYPE=Release','-DCMAKE_SHARED_LINKER_FLAGS=-static','-DCMAKE_EXE_LINKER_FLAGS=-static'],[str(a.cmake),'--build',str(r/'build/windows-tsf/x64'),'--parallel','2','--target','PrivateInputTSF','LingheInputSetup','LingheInputSettings','LingheInputActivity','LingheLegacyExport']]
with (e/'reproducible-build.log').open('w') as log:
 for cmd in commands:subprocess.run(cmd,cwd=r,env=env,stdout=log,stderr=subprocess.STDOUT,check=True)
runtime=stage/'payload/AMD64';runtime.mkdir(parents=True)
for name in ['LingheInputSetup.exe','LingheInputSettings.exe']:shutil.copy2(r/'build/windows-tsf/x64'/name,stage/name)
shutil.copy2(r/'build/windows-tsf/x64/PrivateInputTSF.dll',runtime/'PrivateInputTSF.dll');shutil.copy2(stage/'LingheInputSettings.exe',runtime/'LingheInputSettings.exe');shutil.copy2(r/'build/windows-tsf/x64/activity/LingheInputActivity.exe',runtime/'LingheInputActivity.exe');shutil.copy2(r/'build/windows-tsf/x64/LingheLegacyExport.exe',runtime/'LingheLegacyExport.exe');shutil.copy2(r/'build/rime/windows-x64/lib/librime.dll',runtime/'librime.dll')
for p in (public_resources/'rime').rglob('*'):
 if p.is_file() and p.suffix!='.gram':
  q=runtime/'data/rime'/p.relative_to(public_resources/'rime');q.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(p,q)
q=runtime/'data/semantic';q.mkdir(parents=True);shutil.copy2(public_resources/'semantic/pinyin-syllables.txt',q/'pinyin-syllables.txt');shutil.copy2(public_resources/'semantic/continuation.bin',q/'continuation.bin');shutil.copy2(public_resources/'semantic/CONTINUATION.json',q/'CONTINUATION.json');shutil.copytree(r/'docs/stages/P1/licenses',stage/'licenses');shutil.copytree(r/'docs/stages/P1/licenses',stage/'payload/licenses')
files={str(p.relative_to(stage/'payload')):hashlib.sha256(p.read_bytes()).hexdigest() for p in (stage/'payload').rglob('*') if p.is_file()}
(stage/'payload/manifest.sha256').write_text('version='+a.version+'\n'+''.join(h+'  '+n+'\n' for n,h in sorted(files.items())))
(stage/'使用说明.txt').write_text('灵鹤 Windows11 x64 '+a.version+' 工程预览\n\n本包未签受信任发行证书，未通过Windows真实输入验收，请勿作为正式日用版。\n本批增加默认关闭的设备组与活动归档组件。设置中可填写自部署同步服务器和独立归档服务器、六位码加入或新建设备组。归档分别要求本组开启和本设备明确授权，服务器存具体明文。关闭隔离旧待传，不自动补传；明确清本机或确认离组才清空。输入法成功提交异步送入DPAPI加密SQLite队列，后台HTTPS签名传输。剪贴板独立授权，可读文字不按网址、路径或提供方标签过滤；已识别密码字段、安全桌面及实际无法读取的内容不采集。复制观测不代表已粘贴。\n完整解压后运行 LingheInputSetup.exe；该工程安装器依赖旁置payload，不要只移动exe。\n基础：nihao / csm / shih；长句：wokankanzhegedaoshihounengyouduochang。\n左右选择、上下原位展开，数字仅选当前行；设置可调行列。单击Shift或Ctrl+Shift+空格切中英文；英文保留原文首候选并提供补全/纠错，选择不额外加空格。\n个人词库保留。系统若阻止未签名程序，请停止，不关闭安全防护。\n本批保留端到端加密词库/个人词条/快捷短语同步，剪贴板复制后自动组内转发，不提供消息收发或复制历史列表、独立在组节点限时发码与后台接入；近期词频仅在新协议与组内写入端均支持、且时间可信时启用，旧服务器保留累计同步。MacBERT等神经语义模型尚未包含；跨端真实运行仍待安装后验收。Windows原生组创建、六位码入组、后台归档已用隔离合成组实测；不保证捕获其他App的全部编辑或未知密码字段。单文件离线包另行构建核验。\n',encoding='utf-8-sig')
if not a.no_zip:
 with zipfile.ZipFile(archive,'x',zipfile.ZIP_DEFLATED) as z:
  for p in stage.rglob('*'):
   if p.is_file():z.write(p,str(p.relative_to(stage.parent)))
 with zipfile.ZipFile(archive) as z:assert z.testzip() is None
(e/'package-audit.json').write_text(json.dumps({'version':a.version,'arch':'x64','payloadFiles':files,'zipSHA256':None if a.no_zip else hashlib.sha256(archive.read_bytes()).hexdigest(),'signature':'unsigned engineering preview','executedOnWindows':False,'sourceWorkspace':str(r),'modifiedAppleMaster':False,'storeEligible':False},indent=2))
print(stage if a.no_zip else archive)
