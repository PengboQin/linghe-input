#!/usr/bin/env python3
"""Build and audit one complete offline Windows x64 installer, without downloads.

This never signs, installs or executes a Windows PE. CA trust verification and actual
Windows installation are separate release gates. All writes stay in this project.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import subprocess

ROOT = Path(__file__).resolve().parents[1]
VERSION = '0.6.0-win1'
MAX_FILE = 256 * 1024 * 1024
MAX_TOTAL = 512 * 1024 * 1024


def project_path(path):
    path = path.resolve()
    if not path.is_relative_to(ROOT):
        raise ValueError('Outputs and payload must stay in the independent Windows project')
    return path


def safe_name(name):
    if not name or any(ord(c) < 32 or ord(c) > 126 or c in ':\\"<>|?*' for c in name):
        raise ValueError('Unsafe payload path')
    for part in name.split('/'):
        base = part.upper().split('.')[0]
        if not part or part in ('.', '..') or part[-1] in '. ' or base in {'CON', 'PRN', 'AUX', 'NUL'} or re.fullmatch(r'(COM|LPT)[0-9]', base):
            raise ValueError('Unsafe Windows payload component')
    return name


def pe_resources(path, resource_type=10):
    """Read RCDATA directly from the output PE, independent of compiler tooling."""
    data = path.read_bytes()
    def word(offset): return struct.unpack_from('<H', data, offset)[0]
    def dword(offset): return struct.unpack_from('<I', data, offset)[0]
    if data[:2] != b'MZ': raise ValueError('Missing PE DOS signature')
    pe = dword(60)
    if data[pe:pe+4] != b'PE\0\0' or word(pe+4) != 0x8664:
        raise ValueError('Installer must be Windows x64')
    count, optional_size = word(pe+6), word(pe+20)
    optional = pe+24
    if word(optional) != 0x20b: raise ValueError('Expected PE32+')
    sections = optional+optional_size
    def offset(rva, size=1):
        for index in range(count):
            section = sections+40*index
            virtual_size, address, raw_size, raw_offset = struct.unpack_from('<IIII', data, section+8)
            if address <= rva and rva+size <= address+raw_size:
                position = raw_offset+rva-address
                if position+size <= len(data): return position
        raise ValueError('PE resource points outside a file-backed section')
    root_rva, root_size = struct.unpack_from('<II', data, optional+112+2*8)
    base = offset(root_rva, root_size)
    def directory(relative):
        if relative+16 > root_size: raise ValueError('Truncated resource directory')
        position = base+relative
        total = word(position+12)+word(position+14)
        if total > 1024 or relative+16+8*total > root_size: raise ValueError('Invalid resource count')
        result=[]
        for i in range(total): result.append(struct.unpack_from('<II', data, position+16+i*8))
        return result
    resources={}
    for kind, types in directory(0):
        if kind != resource_type: continue
        if not types & 0x80000000: raise ValueError('Invalid resource type tree')
        for name, names in directory(types & 0x7fffffff):
            if name & 0x80000000 or not names & 0x80000000: raise ValueError('RCDATA must have integer IDs')
            languages = directory(names & 0x7fffffff)
            if len(languages) != 1: raise ValueError('Ambiguous resource language')
            language, entry = languages[0]
            if entry & 0x80000000 or entry+16 > root_size: raise ValueError('Invalid resource data entry')
            rva, size = struct.unpack_from('<II', data, base+entry)
            if size > MAX_FILE: raise ValueError('Oversized resource')
            start=offset(rva,size)
            if name in resources: raise ValueError('Duplicate RCDATA')
            resources[name]=data[start:start+size]
    certificate_offset, certificate_size = struct.unpack_from('<II', data, optional+112+4*8)
    return resources, bool(certificate_offset and certificate_size)


def read_version_information(path):
    """Decode RT_VERSION's actual UTF-16LE StringFileInfo and fixed file version."""
    resources,_=pe_resources(path,16)
    if set(resources)!={1}: raise ValueError('Missing or ambiguous RT_VERSION')
    data=resources[1]
    def word(position):
        if position<0 or position+2>len(data): raise ValueError('Truncated version resource')
        return struct.unpack_from('<H',data,position)[0]
    def align(position): return (position+3)&~3
    def block(start,limit,depth=0):
        if depth>8 or start+6>limit: raise ValueError('Invalid version block')
        length,value_length,kind=word(start),word(start+2),word(start+4)
        end=start+length
        if length<6 or end>limit or kind not in (0,1): raise ValueError('Invalid version block length')
        position=start+6; key_start=position
        while position+2<=end and word(position): position+=2
        if position+2>end: raise ValueError('Unterminated version key')
        key=data[key_start:position].decode('utf-16le',errors='strict')
        position=align(position+2); value_size=value_length*(2 if kind else 1)
        if position+value_size>end: raise ValueError('Truncated version value')
        value=data[position:position+value_size]; position=align(position+value_size)
        children=[]
        while position+6<=end:
            child=block(position,end,depth+1); children.append(child); position=align(position+child['length'])
        return {'key':key,'value':value,'kind':kind,'children':children,'length':length}
    root=block(0,len(data))
    if root['key']!='VS_VERSION_INFO' or len(root['value'])!=52:
        raise ValueError('Missing VS_FIXEDFILEINFO')
    signature,structure,version_ms,version_ls=struct.unpack_from('<IIII',root['value'])
    if signature!=0xfeef04bd: raise ValueError('Invalid fixed version signature')
    numeric='.'.join(map(str,(version_ms>>16,version_ms&65535,version_ls>>16,version_ls&65535)))
    strings={}
    for container in root['children']:
        if container['key']!='StringFileInfo': continue
        for table in container['children']:
            for field in table['children']:
                if field['kind']!=1 or not field['value'].endswith(b'\0\0'):
                    raise ValueError('Invalid version string')
                key=field['key']; value=field['value'].decode('utf-16le',errors='strict').rstrip('\0')
                if key in strings: raise ValueError('Ambiguous duplicate version string')
                strings[key]=value
    if not strings: raise ValueError('Missing version strings')
    return {'fixedFileVersion':numeric,'strings':strings}


def version_numbers(version):
    match=re.fullmatch(r'(0)\.(\d{1,3})\.(\d{1,3})-win([1-9]\d{0,2})',version)
    if not match: raise ValueError('Expected a bounded version such as 0.2.4-win1')
    return tuple(int(value) for value in match.groups())


def verify_version_information(path, version=VERSION):
    actual=read_version_information(path)
    file_version='.'.join(map(str,version_numbers(version)))
    expected={'ProductName':'灵鹤输入法','FileDescription':'灵鹤输入法安装程序',
              'FileVersion':file_version,'ProductVersion':version,
              'InternalName':'LingheInputSetup','OriginalFilename':'LingheInputSetup.exe'}
    if actual['fixedFileVersion']!=file_version or actual['strings']!=expected:
        raise ValueError('Actual PE UTF-16 version resources differ: '+repr(actual))
    return actual


def verify_icon_resources(path,source,group_id=1):
    """Compare actual RT_GROUP_ICON/RT_ICON bytes against the current project ICO."""
    groups,_=pe_resources(path,14); images,_=pe_resources(path,3)
    if set(groups)!={group_id}: raise ValueError('Missing or ambiguous icon group')
    original=source.read_bytes(); group=groups[group_id]
    if len(original)<6 or len(group)<6: raise ValueError('Truncated icon header')
    header=struct.unpack_from('<HHH',original); actual=struct.unpack_from('<HHH',group)
    if header!=actual or header[0]!=0 or header[1]!=1 or not 1<=header[2]<=256:
        raise ValueError('Icon group header differs from source')
    count=header[2]
    if len(original)<6+count*16 or len(group)!=6+count*14: raise ValueError('Invalid icon directory size')
    ids=set(); actual_image_hashes=[]
    for index in range(count):
        source_entry=struct.unpack_from('<BBBBHHII',original,6+index*16)
        group_entry=struct.unpack_from('<BBBBHHIH',group,6+index*14)
        if source_entry[:7]!=group_entry[:7]: raise ValueError('Icon dimensions or metadata differ')
        size,offset=source_entry[6:]; resource_id=group_entry[7]
        if resource_id in ids or offset+size>len(original): raise ValueError('Invalid icon image offset or identity')
        ids.add(resource_id); image=images.get(resource_id)
        if image!=original[offset:offset+size]: raise ValueError('Actual PE icon pixels differ from source')
        actual_image_hashes.append(hashlib.sha256(image).hexdigest())
    if set(images)!=ids: raise ValueError('Unexpected icon image resources')
    return {'verified':True,'images':count,'imageSHA256':actual_image_hashes,
            'sourceIconSHA256':hashlib.sha256(original).hexdigest()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', default=VERSION)
    parser.add_argument('--payload', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--cmake-cache', type=Path, default=ROOT/'build/windows-tsf/x64/CMakeCache.txt')
    parser.add_argument('--unsigned-engineering-preview', action='store_true', required=True,
                        help='Acknowledge this artifact is not a Microsoft Store release')
    args=parser.parse_args()
    numbers=version_numbers(args.version)
    payload=project_path(args.payload)
    output=project_path(args.output)
    cache=project_path(args.cmake_cache)
    if output.exists() or output.with_suffix('.audit.json').exists():
        raise ValueError('Output or audit already exists; choose a new output filename')
    setup_source=(ROOT/'windows/installer/Setup.cpp').read_text()
    if 'constexpr char VersionUtf8[] = \"'+args.version+'\";' not in setup_source:
        raise ValueError('Installer source version differs from package version')
    work=ROOT/'build/offline-installer/x64'
    work.mkdir(parents=True,exist_ok=True)
    entries=[]; folded=set(); total=0
    for path in sorted(payload.rglob('*')):
        if path.is_symlink(): raise ValueError('Payload symlinks are forbidden')
        if not path.is_file() or path.name=='manifest.sha256': continue
        name=safe_name(path.relative_to(payload).as_posix())
        if name.upper() in folded: raise ValueError('Case-insensitive duplicate payload')
        folded.add(name.upper()); size=path.stat().st_size; total+=size
        if not size or size>MAX_FILE or total>MAX_TOTAL: raise ValueError('Invalid payload size')
        entries.append((name,path,hashlib.sha256(path.read_bytes()).hexdigest()))
    if not {'AMD64/PrivateInputTSF.dll','AMD64/LingheInputSettings.exe','AMD64/librime.dll'} <= {e[0] for e in entries}:
        raise ValueError('Incomplete offline payload')
    if not 1<=len(entries)<=256: raise ValueError('Invalid payload count')
    # Reject file/parent collisions, including case folding on case-sensitive build hosts.
    for name in folded:
        parts=name.split('/')
        for n in range(1,len(parts)):
            if '/'.join(parts[:n]) in folded: raise ValueError('Payload file is also a directory')
    manifest=('version='+args.version+'\n'+''.join(sha+'  '+name+'\n' for name,_,sha in entries)).encode('ascii')
    if len(manifest)>256*1024: raise ValueError('Oversized manifest')
    source_manifest=payload/'manifest.sha256'
    if not source_manifest.is_file() or source_manifest.is_symlink():
        raise ValueError('Missing or symlinked source stage manifest')
    source_bytes=source_manifest.read_bytes().replace(b'\r\n',b'\n')
    if source_bytes != manifest:
        raise ValueError('Source stage manifest version, paths, ordering or SHA256 differs from actual payload')
    manifest_path=work/'manifest.sha256'; manifest_path.write_bytes(manifest)
    rc=work/'payload.rc'
    application_manifest=work/'setup.manifest'
    application_manifest.write_text('''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0">
  <assemblyIdentity version="FILE_VERSION_STRING" processorArchitecture="amd64" name="LingheInput.Setup" type="win32"/>
  <trustInfo xmlns="urn:schemas-microsoft-com:asm.v3"><security><requestedPrivileges>
    <requestedExecutionLevel level="requireAdministrator" uiAccess="false"/>
  </requestedPrivileges></security></trustInfo>
  <compatibility xmlns="urn:schemas-microsoft-com:compatibility.v1"><application>
    <supportedOS Id="{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}"/>
  </application></compatibility>
</assembly>
'''.replace('FILE_VERSION_STRING','.'.join(map(str,numbers))),encoding='utf-8')
    def quote(path): return '"'+str(path).replace('\\','/').replace('"','\\"')+'"'
    version_resource = r'''1 VERSIONINFO
FILEVERSION FILE_VERSION_NUMBERS
PRODUCTVERSION FILE_VERSION_NUMBERS
FILEFLAGSMASK 0x3fL
FILEFLAGS 0x0L
FILEOS 0x40004L
FILETYPE 0x1L
FILESUBTYPE 0x0L
BEGIN
 BLOCK "StringFileInfo"
 BEGIN
  BLOCK "040904b0"
  BEGIN
   VALUE "ProductName", "灵鹤输入法\0"
   VALUE "FileDescription", "灵鹤输入法安装程序\0"
   VALUE "FileVersion", "FILE_VERSION_STRING\0"
   VALUE "ProductVersion", "PRODUCT_VERSION_STRING\0"
   VALUE "InternalName", "LingheInputSetup\0"
   VALUE "OriginalFilename", "LingheInputSetup.exe\0"
  END
 END
 BLOCK "VarFileInfo"
 BEGIN
  VALUE "Translation", 0x0409, 1200
 END
END
'''
    version_resource=version_resource.replace('FILE_VERSION_NUMBERS',','.join(map(str,numbers))).replace('FILE_VERSION_STRING','.'.join(map(str,numbers))).replace('PRODUCT_VERSION_STRING',args.version)
    icon=ROOT/'windows/resources/AppIcon.ico'
    if not icon.is_file(): raise ValueError('Current project app icon unavailable')
    rc.write_text('#pragma code_page(65001)\nLANGUAGE 0, 0\n1 ICON '+quote(icon)+'\n1 24 '+quote(application_manifest)+'\n'+version_resource+
                  '1000 RCDATA '+quote(manifest_path)+'\n'+''.join(str(1001+i)+' RCDATA '+quote(path)+'\n' for i,(_,path,_) in enumerate(entries)),encoding='utf-8')
    values={}
    for line in cache.read_text().splitlines():
        if line.startswith(('CMAKE_CXX_COMPILER:','CMAKE_RC_COMPILER:')):
            key,value=line.split('=',1); values[key.split(':')[0]]=value
    compiler=Path(values['CMAKE_CXX_COMPILER']); windres=Path(values['CMAKE_RC_COMPILER'])
    if not compiler.is_file() or not windres.is_file(): raise ValueError('Existing toolchain unavailable')
    resource=work/'payload.res'
    env=os.environ.copy(); env['SOURCE_DATE_EPOCH']='1792281600'; env['TMPDIR']=str(work)
    commands=[
        [str(windres),'--codepage=65001','-i',str(rc),'-o',str(resource),'-O','coff'],
        [str(compiler),'-std=c++17','-O2','-static','-mwindows','-municode','-DUNICODE','-D_UNICODE','-DNOMINMAX',
         '-D_WIN32_WINNT=0x0A00','-DWINVER=0x0A00','-DLINGHE_EMBEDDED_ONLY=1',
         str(ROOT/'windows/installer/Setup.cpp'),str(resource),'-lshell32','-lole32','-loleaut32','-ladvapi32','-lbcrypt','-luser32','-luuid',
         '-Wl,--no-insert-timestamp','-o',str(output)]
    ]
    output.parent.mkdir(parents=True,exist_ok=True)
    with (work/'build.log').open('w') as log:
        for command in commands: subprocess.run(command,cwd=ROOT,env=env,stdout=log,stderr=subprocess.STDOUT,check=True)
    resources,signed_layout=pe_resources(output)
    actual_version=verify_version_information(output,args.version)
    actual_icon=verify_icon_resources(output,icon)
    manifest_resources,_=pe_resources(output,24)
    if manifest_resources.get(1) != application_manifest.read_bytes():
        raise ValueError('Final installer is missing the exact requireAdministrator manifest')
    expected={1000:manifest}
    expected.update({1001+i:path.read_bytes() for i,(_,path,_) in enumerate(entries)})
    if resources != expected: raise ValueError('Output PE does not contain the exact complete offline payload')
    audit={
        'schemaVersion':1,'version':args.version,'installer':str(output.relative_to(ROOT)),
        'sha256':hashlib.sha256(output.read_bytes()).hexdigest(),'bytes':output.stat().st_size,
        'payloadFiles':{name:sha for name,_,sha in entries},'payloadBytes':total,
        'singleFile':True,'offlineComplete':True,'embeddedPayloadMatches':True,
        'iconSHA256':actual_icon['sourceIconSHA256'],'iconResourceReadback':actual_icon,'fileVersion':actual_version['fixedFileVersion'],
        'productName':actual_version['strings']['ProductName'],'fileDescription':actual_version['strings']['FileDescription'],
        'versionResourceReadback':actual_version,
        'embeddedOnlyFailClosed':True,'requestedExecutionLevel':'requireAdministrator','authenticodeCertificateTablePresent':signed_layout,
        'trustedCASignatureVerified':False,'windowsExecuted':False,'storeEligible':False,
        'pending':['CA sign every embedded PE before packaging; regenerate manifest after signing',
                   'CA sign the final installer; verify timestamp and Windows trust',
                   'Windows real-device silent install, upgrade, TSF and unregister acceptance',
                   'Immutable version-specific public HTTPS installer URL and Store certification']}
    audit_path=output.with_suffix('.audit.json'); audit_path.write_text(json.dumps(audit,indent=2)+'\n')
    print(json.dumps({'installer':str(output),'audit':str(audit_path),'offlineComplete':True,'storeEligible':False}))

if __name__=='__main__': main()
