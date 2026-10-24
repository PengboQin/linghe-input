"""Common public diagnostic fingerprints for full and incremental APK builds."""
from pathlib import Path
import hashlib
import json

def fingerprint(root,paths):
    rows=sorted(str(p.relative_to(root))+':'+hashlib.sha256(p.read_bytes()).hexdigest() for p in paths)
    return hashlib.sha256('\n'.join(rows).encode()).hexdigest()

def write_config(root,output):
    root=Path(root);output=Path(output)
    core=fingerprint(root,[p for p in (root/'core').rglob('*') if p.is_file() and p.suffix in ['.h','.hpp','.c','.cpp']])
    resources=fingerprint(root,[p for p in (root/'resources/rime').rglob('*') if p.is_file()]+[root/('resources/semantic/'+n) for n in ['pinyin-syllables.txt','nine-lexicon.bin','continuation.bin']])
    policy=fingerprint(root,[root/('android/app/src/main/java/live/linghe/privateinput/'+n+'.java') for n in ['InputQuality','PinyinMatch','PinyinCorrector','CommonExpressionOrder','NinePathOrder']])
    output.parent.mkdir(parents=True,exist_ok=True)
    output.write_text('package live.linghe.privateinput; final class SyncBuildConfig {static final String DEFAULT_ENDPOINT="";static final String CORE_HASH='+json.dumps(core)+';static final String RESOURCE_HASH='+json.dumps(resources)+';static final String POLICY_HASH='+json.dumps(policy)+';}')
    return {'core':core,'resources':resources,'policy':policy,'privateEndpointEmbedded':False}
