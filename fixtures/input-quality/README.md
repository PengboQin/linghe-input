# 输入质量夹具

- `benchmark-20261020.json`：57 条期望，延续已有 ranking case 结构。
- `results-template-20261020.json`：全部未运行；`null` 不是空候选，`[]` 才是实际空输出。
- 每条 case 使用独立 `state.fixture`；`rank_hints` 仅建议，硬断言在 `assertions/contracts`。
- `contracts` 依据实际观察字段，不操作产品或设备。UI/学习层不能用 engine capture 冒充。

格式、命令、指标及采集合同边界见 [设计说明](../../docs/INPUT-QUALITY-BENCHMARK-20261020.md)。公开夹具只存合成文本或用户明确给出的输入例子，禁止加入 NAS 私人正文、真实设备/组/事件标识或部署路径。实际运行结果另存 evidence。
