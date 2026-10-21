# Offline models and public data

The source archive excludes all compiled Core ML weight directories, PyTorch/Safetensors weights, and large experimental model caches. The normal public Rime dictionary, compact grammar, nine-key lexicon and continuation data are different resources and retain their source/license manifests.

| Component | Fixed source/revision | Checksums/recipe |
| --- | --- | --- |
| ELECTRA small discriminator | `hfl/chinese-electra-180g-small-discriminator`, revision `826a243f3f387450ef8d70de9c3d0706d8d8e924` | `docs/stages/P2/dictionary/semantic.lock.json`, `resources/semantic/MODEL.json`, `experiments/semantic/convert_electra.py` |
| MacBERT CSC | `shibing624/macbert4csc-base-chinese`, revision `615e6e09ef9a69ec487bc7c641ec3a311e2c11b9` | `docs/stages/P2/dictionary/macbert.lock.json`, `resources/semantic-mac/MODEL.json`, `experiments/macbert/convert.py` |
| Rime dictionary / essay | pinned Luna Pinyin and essay commits | `docs/stages/P2/dictionary/upstream.lock.json`, `resources/rime/SOURCE.json` |
| Compact n-gram grammar | octagram data release `20260712` | `docs/stages/P2/dictionary/grammar.lock.json` and `scripts/prepare_grammar.py` |

`python3 scripts/fetch_public_dependencies.py --models` is an explicit, potentially large download. It uses the recorded revisions, verifies every downloaded file hash and preserves existing files. This is never performed just by viewing the archive or compiling the non-neural components.

Conversion requires an appropriate local Python environment. The ELECTRA lock records torch 2.6.0, transformers 4.51.3, coremltools 8.3.0 and numpy 1.26.4. MacBERT also needs safetensors; its complete conversion environment was not separately pinned. Existing conversion scripts save `.mlpackage` outputs under `artifacts/` and audit files under `evidence/`; create those audit parent directories before running them. Compile with the local Xcode Core ML compiler into the resource directory named in the respective model manifest.

The compiled `*.mlmodelc` hashes document the internal candidate, but conversions can vary with toolchain/runtime. This archive has not been used for a clean-room reconstruction or proven byte-identical binary reproduction. Without restored compiled resources, neural reranking is unavailable and platform code uses its available fallback; do not claim parity with a candidate that loaded those models. No translation model is formally integrated.
