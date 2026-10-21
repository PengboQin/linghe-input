# 许可与第三方组件

灵鹤输入法原创代码以 **GNU GPL version 3 only（SPDX: GPL-3.0-only）** 发布，完整文本见仓库根目录 `LICENSE`。Copyright (c) 2026 PengboQin and Linghe Input contributors。

使用、修改、再分发请遵守 GPL-3.0。对外分发本软件或修改版本的二进制时，应按该许可证提供对应源码和必要的构建材料；不得将开发者或使用者的私有配置、密钥及输入记录当作源码公开。

第三方代码、词库、模型和素材保留各自版权与许可证；本项目的GPL声明不替代其单独声明。组件固定来源、许可证和构建要求见源码中的 `SOURCE.json`、`resources/`、`vendor/`、`server/requirements*.txt` 及 `MODELS.md`。

编译所需的公开依赖应按 `BUILDING.md` 及固定来源清单取得。模型权重未全部包含在源码包中；缺少可选模型时采用本机规则回退，不能把缺模型构建宣传为相同的神经模型效果。

固定组件与来源：

- librime、librime-octagram：`docs/stages/P1/licenses/`、`vendor/librime-octagram/LICENSE` 及依赖锁。
- Rime Luna Pinyin、essay、octagram语料：`vendor/dictionaries/`、`resources/rime/licenses/`、词典/语法锁；其中词库/数据含 LGPL-3.0 声明，保留其对应源和许可。
- Boost、yaml-cpp、LevelDB、marisa-trie、OpenCC：`docs/stages/P1/` 的固定修订及许可证。
- ZXing、Bouncy Castle、libsodium：`vendor/` 下对应 SOURCE 和原始许可文件，重建所需源码按固定来源取得。
- ELECTRA、MacBERT：模型 manifest、上游修订、转换脚本及模型许可；大权重不包含在源码存档中。
