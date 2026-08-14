# 小熙项目文档索引

本目录中的 `00` 至 `14` 文件构成当前项目启动基线。发生冲突时，按“决策记录 → 对应领域权威文档 → 研究材料”的顺序处理。

| 文档 | 用途 | 当前状态 |
|---|---|---|
| [00_overview.md](00_overview.md) | 项目总览、定位、范围和启动状态 | 当前 |
| [01_prd.md](01_prd.md) | 产品需求、用户旅程和产品规则 | V0.2 已评审通过 |
| [02_roadmap.md](02_roadmap.md) | 阶段计划、里程碑和 Go/No-Go Gate | 当前 |
| [03_architecture.md](03_architecture.md) | 设备、云端、Web 和 PC Bridge 架构 | 当前，待架构评审 |
| [04_acceptance_checklist.md](04_acceptance_checklist.md) | V0 验收、证据要求和停止条件 | 当前 |
| [05_ai_coding_agent_guide.md](05_ai_coding_agent_guide.md) | Codex/AI Coding 工作协议 | 当前 |
| [06_progress.md](06_progress.md) | 进度、评审状态和下一步 | 持续更新 |
| [07_decisions.md](07_decisions.md) | 已冻结决策和待决策项 | 持续更新 |
| [08_hardware_prototype_plan.md](08_hardware_prototype_plan.md) | H0 参考设备、自研硬件主线、双轴形态、成本边界和专项验收 | V0.2 方向已批准，未采购或制作 |
| [09_jlceda_placement_guide.md](09_jlceda_placement_guide.md) | 嘉立创原理图器件放置接力清单 | 当前，待人工放置后进入连线 |
| [10_hardware_board_design_spec.md](10_hardware_board_design_spec.md) | H0C 自研板器件、电源、接口、GPIO、保护、去耦与 PCB 设计权威规范 | V0.1 架构基线，待 G0/G1 评审 |
| [11_h0c_reva_schematic_wiring_handoff.md](11_h0c_reva_schematic_wiring_handoff.md) | H0C Rev A 人工原理图连线、页内布局、补件与复核交接单 | V1.0，01 A 表至 77、02 至 A38、06 至 A33；不替代 10 |
| [12_h0c_reva_g0_schematic_audit.md](12_h0c_reva_g0_schematic_audit.md) | H0C Rev A 原理图审计、P0/P1 与接线前检查卡 | 当前，P0 与 06 器件级 P1-02 已关闭；仍未 ERC/转 PCB |
| [13_h0c_reva_g0_sample_procurement.md](13_h0c_reva_g0_sample_procurement.md) | G0 台架样件采购、风险备料与到货验证顺序 | 当前，可用于样件询价/采购；不代表 PCB 下单 |
| [14_h0c_reva_non_power_schematic_workplan.md](14_h0c_reva_non_power_schematic_workplan.md) | 保护 01 已接线内容，审计并安排 02–07/Head 的安全施工顺序 | V0.3，06 器件级 P1-02 已关闭、Head 四页已逐页确认空白；非 ERC/PCB 放行 |

## 研究和历史材料

| 文件 | 定位 |
|---|---|
| [deep search.md](<deep search.md>) | 2026-08-06 商业化前置调研；外部价格、法规和产品能力需在使用前复核 |
| [prd.md](prd.md) | 2026-08-06 转向前的完整 PRD；已被 `01_prd.md` 取代，不再作为当前需求来源 |

两段竞品抖音录屏保留在项目根目录，仅作为本地研究证据。未经权利确认，不应随仓库公开发布。

## 文档更新规则

1. 产品规则变化先更新 `01_prd.md`，再同步架构、路线图和验收。
2. 架构边界变化更新 `03_architecture.md`，并在 `07_decisions.md` 记录原因。
3. 任何阶段完成、评审结论或阻塞更新 `06_progress.md`。
4. 测试通过不等于用户验收；合并、推送、发布和生产验收分别记录。
5. 研究材料只提供证据，不覆盖已冻结决策。
6. H0 的 BOM、结构、设备状态和硬件验收以 `08_hardware_prototype_plan.md` 为权威；其他文档只记录阶段和追踪关系。
7. H0C 板级实现以 `10_hardware_board_design_spec.md` 为权威；与 `09` 放置清单冲突时以 `10` 为准。
8. `11_h0c_reva_schematic_wiring_handoff.md` 是人工连线执行单；其中标记为 `GATE` 的项不得凭推测接线，器件和架构判断仍以 `10` 为准。
