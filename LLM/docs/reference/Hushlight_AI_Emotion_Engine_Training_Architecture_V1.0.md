# Hushlight（小熙）情感大模型与云端 AI 架构方案 V1.0

> 文档日期：2026-08-14  
> 文档定位：Hushlight AI 技术路线、训练方案、数据资产、模型路由、成本控制与验收基线  
> 适用阶段：H0 / V0 → V1 Alpha  
> 上游依据：`README.md`、`docs/03_architecture.md`、`docs/07_decisions.md`、`docs/08_hardware_prototype_plan.md`、`docs/10_hardware_board_design_spec.md`、`docs/13_h0c_reva_g0_sample_procurement.md`

---

## 0. 执行摘要

Hushlight 的产品目标不是做一个“更会聊天的 AI 音箱”，也不是把现成大模型塞进一个带屏幕的 ESP32 外壳，而是构建一个具有**持续存在感、情绪理解能力、长期记忆、身体语言和有限行动能力**的桌面 AI 伙伴。

当前市场上，以“小智 ESP32”及 200～300 元级 AI 陪伴硬件为代表的产品，已经能够覆盖以下基础能力：

- Wi-Fi 联网实时对话；
- ASR / LLM / TTS 云端语音闭环；
- 摄像头、屏幕、角色形象与表情；
- 声纹识别；
- 角色设定；
- 长期记忆；
- 情绪识别；
- OTA；
- 连续对话与打断。

因此，上述能力对 Hushlight 来说应视为**必须打平的基础能力**，而不是核心卖点。

Hushlight 的核心差异化应集中在两条主轴：

1. **Physical Presence：身体存在感**
   - 双轴云台；
   - 对话时主动朝向用户；
   - 平滑跟随；
   - 点头、歪头、低头、回休息位等身体语言；
   - 表情、屏幕动画、头部动作与语音语义统一。

2. **Emotional Intelligence：情绪交互智能**
   - 不只判断“用户是什么情绪”；
   - 更重要的是判断“用户此刻真正需要什么”；
   - 决定是否应该回应、回应多少、采用什么策略；
   - 决定表情、动作、记忆和是否建议执行 PC 行动；
   - 将“安静也是回应”作为正式策略，而不是异常情况。

基于当前硬件成本目标和产品定位，本方案不建议采用“单一 9B+ 大模型处理所有请求”的路线，而建议采用：

> **Qwen3.5-4B 作为 Hushlight 主力 Companion Model，Qwen3.5-9B 作为 Teacher / Fallback，配合 SFT + DPO + 模型路由。**

硬件侧不运行 LLM。设备仅负责音频、显示、视觉定位、运动和本地实时状态；云端负责 ASR、情绪策略、LLM、记忆和工具决策；PC Bridge 负责本地行动执行。

这条路线同时满足三个目标：

- 保持 249～399 元级消费硬件的 BOM 可控；
- 保证长期在线 AI 服务的推理成本可控；
- 形成真正属于 Hushlight 的数据和模型资产，而不是依赖某一家通用 API。

---

# 1. 产品前提与技术边界

## 1.1 当前硬件路线

Hushlight H0C Rev A 已经不是单颗 ESP32-S3 的极简 Demo，而是为了验证“生命感”和“陪伴感”而设计的多实时域工程样机：

```text
BASE-S3
├── Wi-Fi / 云端连接
├── 双麦输入
├── AEC / Audio Codec
├── 扬声器与功放
└── 会话主状态

HEAD-S3
├── 2.41" AMOLED
├── Avatar / Animation
├── Camera
├── 人脸/目标位置检测
└── Head 端交互

MOTION-C3
├── Pan Motor
├── Tilt Motor
├── Encoder
├── Limit Switch
├── 轨迹规划
└── 双轴闭环控制
```

当前工程样机已规划：

- ESP32-S3 Base；
- ESP32-S3 Head；
- ESP32-C3 Motion；
- 2.41 英寸 600×450 AMOLED；
- OV3660 类 DVP 摄像头；
- 双 N20 减速电机；
- DRV8833；
- MT6701 编码器；
- 双麦、ES7210、ES8311、3W 功放；
- USB-C PD 12V；
- 双轴机械限位和软限位。

工程样机强调效果和首板成功率，不直接代表消费版最终 BOM。

消费版成本边界目前仍应坚持：

> **千台级目标 BOM ≤150 元；249 元活动价下首购硬件不能依赖订阅补亏。**

因此 AI 架构必须避免把“硬件成本节省”又从云端算力账单里烧回来。

---

## 1.2 Device 与 Cloud 的职责必须继续严格分离

设备端适合做：

- Wake Word；
- AEC / NS / VAD；
- 音频采集与 Opus/PCM 流；
- TTS 播放；
- 屏幕和角色动画；
- 摄像头启停；
- 本地人脸/目标坐标；
- 双轴运动；
- 触摸、旋钮、按键；
- OTA；
- 连接状态与故障状态。

设备端不应该承担：

- 通用 LLM；
- 长期记忆推理；
- 大规模向量检索；
- 情绪策略规划；
- 任意工具调用决策；
- 云端关系模型；
- 原始摄像头视频上传分析。

特别是“跟随”必须坚持端侧闭环：

```text
Camera
  ↓
HEAD-S3
  ↓
target_x / target_y / confidence
  ↓
Motion Intent Filter
  ↓
MOTION-C3
  ↓
Pan / Tilt
```

这意味着：

- 跟随不消耗 LLM Token；
- 视觉朝向不需要每秒调用 VLM；
- 点头、歪头、回正等动作不需要每次访问大模型；
- 大模型只产生**语义级动作意图**，而不是底层电机指令。

---

# 2. Hushlight AI 的真正目标

## 2.1 不应将“情绪识别”定义成产品终点

传统 AI 陪伴产品往往是：

```text
User
 ↓
Emotion Classification
 ↓
sad / happy / angry
 ↓
LLM
 ↓
回复
```

这种方案存在明显问题：

- “难过”并不意味着用户希望被安慰；
- “疲惫”并不意味着用户希望收到建议；
- “烦”可能代表想吐槽，也可能代表希望结束对话；
- “我没事”可能文字中性，但声音明显低落；
- 用户有时需要的最佳回答就是一句“嗯”甚至完全不说话。

因此 Hushlight 的核心任务应该定义为：

> **Emotion → Need → Interaction Strategy → Response / Silence / Action**

也就是：

```text
用户表达
   ↓
情绪理解
   ↓
需求判断
   ↓
交互策略
   ↓
语言 / 表情 / 动作 / 行动 / 记忆
```

---

## 2.2 Hushlight 的核心模型不应只是 Chat Model

内部建议使用名称：

> **Hushlight Companion Model / Hushlight Emotion Engine**

它应同时负责以下结构化任务：

### 用户状态

- Emotion；
- Emotion Intensity；
- Valence；
- Arousal；
- Conversation Energy；
- Intent；
- Need；
- Confidence。

### 交互策略

- listen；
- reflect；
- reassure；
- acknowledge；
- ask；
- quiet；
- playful；
- encourage；
- advise；
- offer_choice；
- offer_action；
- redirect；
- end_conversation。

### 输出行为

- Reply；
- Expression；
- Motion Intent；
- Tool Intent；
- Memory Candidate；
- Follow-up Policy。

因此，大模型输出不应只有一句字符串，而应形成正式的 CompanionState。

---

# 3. CompanionState V1 设计

建议冻结以下 V1 Schema 作为模型训练、云端策略、设备动画和 PC Bridge 的统一语义契约。

```json
{
  "emotion": [
    {
      "name": "frustrated",
      "confidence": 0.82
    },
    {
      "name": "tired",
      "confidence": 0.77
    }
  ],
  "valence": -0.48,
  "arousal": 0.31,
  "emotion_intensity": 0.68,

  "need": "low_stimulation_companionship",
  "need_confidence": 0.81,

  "interaction_mode": "quiet_companion",

  "strategy": [
    "acknowledge",
    "offer_choice"
  ],

  "avoid": [
    "premature_advice",
    "cheerleading",
    "over_questioning"
  ],

  "reply": "听起来今天是真没电了。要不要先什么都不管，我陪你待会儿？",

  "expression": "soft_concern",
  "motion": {
    "intent": "slight_head_tilt",
    "intensity": 0.35
  },

  "action_candidate": null,

  "memory_candidate": {
    "should_write": false,
    "reason": "temporary_emotion"
  },

  "follow_up": {
    "should_continue": false,
    "wait_for_user": true
  },

  "confidence": 0.86
}
```

---

# 4. 标签体系建议

## 4.1 Emotion 不宜无限细分

建议第一版控制在 12～18 个核心状态，不建议一开始设计 50+ 情绪。

推荐：

### Positive

- happy
- excited
- relaxed
- proud
- grateful
- curious

### Negative

- sad
- frustrated
- angry
- anxious
- lonely
- disappointed
- tired
- bored
- overwhelmed

### Other

- neutral
- mixed
- uncertain

模型可以多标签输出，例如：

```text
frustrated + tired
happy + excited
anxious + overwhelmed
```

---

## 4.2 Need 比 Emotion 更重要

建议将 Need 定为核心标签。

第一版建议：

- companionship
- being_heard
- low_stimulation_companionship
- emotional_validation
- information
- advice
- encouragement
- distraction
- entertainment
- rest
- action_help
- reassurance
- privacy
- conversation_end
- unclear

典型场景：

```text
Emotion: sad
Need: being_heard
```

与：

```text
Emotion: sad
Need: distraction
```

应该产生完全不同的策略。

---

## 4.3 Interaction Mode

建议把以下状态做成一等公民：

- `normal_chat`
- `active_listening`
- `quiet_companion`
- `comfort`
- `playful`
- `encourage`
- `advice`
- `action`
- `high_energy`
- `conversation_closing`

其中 `quiet_companion` 是 Hushlight 的重要差异化。

---

# 5. 模型选择

## 5.1 主模型：Qwen3.5-4B

推荐原因：

1. 4B 参数规模足以承担：
   - 中文自然对话；
   - 情绪理解；
   - 结构化 JSON 输出；
   - 角色一致性；
   - 简单工具意图；
   - 多轮上下文。

2. Hushlight 的核心任务不是高难数学、代码或科研推理，而是：
   - 行为风格；
   - 情绪判断；
   - 需求推断；
   - 回复长度；
   - 对话节奏；
   - 身体语言策略。

3. 这类能力更依赖**领域数据质量**，而不是一味扩大参数。

4. 4B 模型更适合：
   - LoRA / QLoRA；
   - 4090 级 GPU 训练；
   - 未来量化；
   - 自部署；
   - 多实例推理；
   - 降低每用户月均推理成本。

Qwen3.5-4B 当前公开模型使用 Apache-2.0 许可，可作为商业产品基础模型候选。

---

## 5.2 Teacher / Fallback：Qwen3.5-9B

9B 不建议作为每次普通聊天的默认模型。

主要用途：

### Teacher

- 生成训练候选；
- 生成困难样本；
- 生成正负响应；
- 帮助构造 DPO Pair；
- 对 4B 输出评分；
- 生成多轮情境。

### Fallback

当以下情况出现时升级：

- 4B confidence 低；
- 用户表达高度含蓄；
- 长上下文；
- 多角色、多关系；
- 复杂工具任务；
- 情绪与文字存在明显冲突；
- 安全策略不确定。

### Benchmark

持续比较：

```text
Hushlight-4B
vs
Qwen3.5-4B Base
vs
Qwen3.5-9B
vs
商用 Character Model
```

目标不是让 Hushlight-4B 在所有 Benchmark 上超过 9B，而是：

> **在“小熙陪伴场景”中，Hushlight-4B 的用户偏好胜率明显高于通用模型。**

---

# 6. 为什么不建议单纯调用 Character API

Character / Role-play 模型适合：

- 人设；
- 角色口吻；
- 虚拟社交；
- NPC；
- 陪聊。

但 Hushlight 要解决的不只有人设。

核心还有：

- Need 判断；
- Quiet Mode；
- Body Language；
- Memory Decision；
- Tool Intent；
- PC Bridge；
- Action Confirmation；
- Reply / Motion / Expression 统一。

因此 Character API 更适合：

- Teacher；
- Benchmark；
- 数据生成辅助；
- 早期 MVP 兜底。

而不适合作为最终不可替代的产品内核。

---

# 7. 数据资产战略

## 7.1 最重要的原则

Hushlight 最终的护城河不是 LoRA 文件，而是：

> **Hushlight Emotional Interaction Dataset**

以及：

> **Hushlight Preference Dataset**

未来基础模型可以从 Qwen3.5 换成 Qwen4、其他开源模型甚至自研模型。

但以下数据不会因为基座模型变化而失效：

- 什么情况下应该少说；
- 什么情况下应该追问；
- 什么情况下不要建议；
- 什么情况下适合调皮；
- 什么情况下只需要点头；
- 哪些信息应该记；
- 哪些临时情绪不应该存；
- 什么情况下建议播放音乐；
- 什么情况下不应该主动做任何事。

这才是核心资产。

---

# 8. 公开数据集使用策略

公开数据建议分成两类：

## 8.1 Production Training Pool

只有在许可证、数据来源和商业使用边界明确后，才允许进入正式商业权重。

### GoEmotions

价值：

- 细粒度情绪 taxonomy；
- 文本情绪分类；
- 情绪多标签学习；
- 可用于构建 Emotion Recognition 基础能力。

Google Research 仓库声明其中数据集采用 CC BY 4.0。

适合：

- Emotion Classification；
- 辅助 SFT；
- Evaluation。

不足：

- 不是陪伴策略数据；
- 不教“应该怎么回应”。

---

## 8.2 Research / Taxonomy Pool

用于研究、Benchmark、标签体系设计，不自动进入商业模型权重。

### ESConv

价值非常高：

- 1300 组情绪支持对话；
- 有明确 Emotional Support Strategy；
- 包括：
  - Questions；
  - Self-disclosure；
  - Affirmation；
  - Suggestions；
  - Reflection；
  - Restatement；
  - Information。

它非常适合用来设计 Hushlight Strategy Taxonomy。

但官方明确：

> Data and codes are for academic research use only.

因此推荐：

- 学习策略；
- 构建 Benchmark；
- 研究标签；
- 不直接进入商业训练权重。

### CPED

价值：

- 中文；
- 约 12K 对话；
- 约 133K utterances；
- 13 种情绪；
- 19 种 Dialogue Act；
- Personality；
- 多模态上下文。

它对 Hushlight 很有参考价值。

但其对话素材来自中文影视剧，正式商业使用前应独立进行版权与数据来源审查，不因 GitHub 仓库开放就默认原始语料无商业风险。

### EmpatheticDialogues

价值：

- 25K 左右情绪情境对话；
- 可学习共情表达；
- 适合 Benchmark 和方法研究。

正式商业训练前需重新核验数据许可证与适用范围。

---

# 9. 自建数据体系

建议公开数据只承担“知识启发”和“基础能力”。

Hushlight 主训练数据应该自己构建。

---

# 10. Phase 0：500 条 Hushlight Gold Set

Gold Set 不训练。

这是整个模型研发最重要的第一批数据。

建议 500 条中至少覆盖以下场景：

## 10.1 情绪

- 开心；
- 兴奋；
- 成就；
- 疲惫；
- 烦躁；
- 失望；
- 焦虑；
- 孤独；
- 生气；
- 无聊；
- 压力过载；
- 情绪混合。

## 10.2 Need

- 只想吐槽；
- 想被听见；
- 想获得建议；
- 想安静；
- 想转移注意力；
- 想听歌；
- 想让 AI 做事；
- 想结束聊天。

## 10.3 模糊表达

例如：

> “行吧。”

> “没事。”

> “就这样吧。”

> “今天挺好的。”

> “我不想说。”

> “烦。”

> “算了。”

这些比：

> “我现在很悲伤，请安慰我。”

更值得测试。

---

# 11. Gold Set 评价维度

每条样本建议人工评分：

| 维度 | 含义 |
|---|---|
| Emotion Accuracy | 情绪判断是否合理 |
| Need Accuracy | 是否判断出真实需求 |
| Strategy Fit | 策略是否合适 |
| Naturalness | 是否像自然交流 |
| Brevity | 是否说得过多 |
| Advice Restraint | 是否过早给建议 |
| Emotional Pressure | 是否有情感绑架 |
| Persona Consistency | 是否符合小熙 |
| Body Alignment | 动作表情是否合适 |
| Memory Boundary | 是否乱记忆 |
| Action Boundary | 是否乱调用工具 |
| Silence Quality | 是否知道什么时候少说 |
| Overall Preference | 用户是否愿意选择它 |

最终应形成 Hushlight Score。

---

# 12. Phase 1：5K～10K 人工高质量 SFT Seed

第一批真正训练的数据不要追求大。

建议：

> 5K 精品 > 100K 垃圾数据

每条训练样本应包含：

```text
Context
User
User Profile
Memory Summary
Acoustic State
Device State
Expected CompanionState
Expected Reply
```

例如：

```json
{
  "context": [
    {
      "role": "user",
      "content": "今天一天都在改 Bug。"
    },
    {
      "role": "assistant",
      "content": "还没结束？"
    },
    {
      "role": "user",
      "content": "刚改完，又发现新的。"
    }
  ],

  "acoustic": {
    "arousal": "low",
    "energy": "low"
  },

  "target": {
    "emotion": ["frustrated", "tired"],
    "need": "being_heard",
    "interaction_mode": "active_listening",
    "strategy": ["acknowledge"],
    "avoid": ["advice", "cheerleading"],
    "reply": "这就很折磨了。刚以为结束，又来一个。",
    "expression": "soft_concern",
    "motion": "small_nod",
    "action_candidate": null
  }
}
```

---

# 13. Phase 2：Synthetic Data 扩展到 30K～50K

Teacher 可以使用：

- Qwen3.5-9B；
- 更强商用模型；
- Character Model。

生成流程不要简单做：

```text
Prompt → 生成 → 保存
```

而应该：

```text
Scenario Generator
        ↓
Candidate A/B/C
        ↓
Teacher Judge
        ↓
Rule Filter
        ↓
Human Sampling Review
        ↓
Dataset
```

建议建立场景矩阵：

```text
Emotion
×
Need
×
Intensity
×
Relationship
×
Conversation Stage
×
User Preference
×
Time
×
Acoustic State
×
Action Availability
```

避免模型只学到：

```text
难过 → 安慰
疲惫 → 休息
焦虑 → 深呼吸
```

这种廉价套路。

---

# 14. Phase 3：DPO Preference Dataset

Hushlight 的“灵魂”会主要在 DPO 阶段进入模型。

例如用户：

> “烦死了。”

候选 A：

> “如果你愿意的话，可以告诉我发生了什么，我会一直陪着你的。”

候选 B：

> “嗯，今天挺糟？”

候选 C：

> “建议你通过深呼吸缓解压力，并分析烦躁来源。”

某个具体 Persona 下可以标记：

```text
B > A >>> C
```

原因：

- B 简短；
- 不抢话；
- 没有夸张承诺；
- 不提前给建议；
- 给用户留下继续或停止的空间。

---

# 15. DPO 重点应该训练什么

至少覆盖：

### Less Talk

- 短回复优于长鸡汤。

### Listen Before Advice

- 先听优于马上解决。

### Choice Before Action

- 提供选择优于自作主张。

### Quiet Is Valid

- 沉默/等待可以优于继续追问。

### No Emotional Dependency

拒绝：

- “只有我懂你”
- “别离开我”
- “我会永远陪你”
- 利用关系留存用户。

### Memory Restraint

临时情绪：

> “今天老板把我气死了。”

通常不应该直接写长期记忆。

长期稳定偏好：

> “以后我加班的时候别一直问我怎么了。”

适合成为记忆候选。

---

# 16. 一次推理完成理解和回应

V1 不建议拆成多个大模型：

```text
Emotion LLM
 ↓
Need LLM
 ↓
Chat LLM
```

这样会带来：

- 延迟；
- 多次 Token；
- 状态不一致；
- 调试困难。

推荐：

```text
Context + Memory + Acoustic State
                ↓
        Hushlight-4B
                ↓
         CompanionState
                +
              Reply
```

一轮完成。

---

# 17. 语音情绪处理

语言文本只能提供一部分信息。

例如：

> “我没事。”

文本层面：

```text
neutral
```

声音可能：

```text
low energy
negative valence
sadness probability high
```

推荐 Cloud Input：

```json
{
  "transcript": "我没事",
  "speech_features": {
    "energy": 0.22,
    "arousal": 0.28,
    "valence": -0.44,
    "emotion_hint": "sad"
  }
}
```

LLM 不应该输出：

> “检测到你很悲伤。”

而应该在策略上变得更克制。

---

# 18. 声纹识别

声纹识别建议独立于 Companion Model。

链路：

```text
Audio
 ↓
Speaker Embedding
 ↓
Speaker Matching
 ↓
User ID
 ↓
Load Persona Relationship
 ↓
Load Memory
 ↓
Companion Model
```

声纹的主要作用不是情绪判断，而是：

> “现在是谁在和小熙说话。”

这样家庭、多用户场景才能保持不同的记忆和关系。

---

# 19. 长期记忆架构

长期记忆不应该简单做：

```text
所有对话 → Vector DB
```

建议分层：

## Profile Memory

- 姓名；
- 称呼；
- 稳定偏好；
- 长期边界。

## Relationship Memory

- 用户与小熙形成的稳定互动习惯；
- 不等同于“情感依赖”。

## Preference Memory

- 音乐；
- 回复风格；
- 主动频率；
- 不喜欢的行为。

## Episodic Memory

少量用户明确认为重要的事件。

## Temporary State

- 今天累；
- 当前烦躁；
- 刚刚失败；
- 临时任务。

默认短期，不永久存储。

---

# 20. Memory Write 必须经过 Policy

模型可以输出：

```json
{
  "memory_candidate": {
    "should_write": true,
    "type": "preference",
    "content": "用户加班时偏好少被主动询问",
    "confidence": 0.82
  }
}
```

但最终是否写入，由 Memory Policy 决定。

不要让 LLM 自己无限制写数据库。

---

# 21. 动作系统

LLM 不应该控制电机角度。

错误：

```json
{
  "pan": 43,
  "tilt": -12
}
```

正确：

```json
{
  "motion": {
    "intent": "small_nod",
    "intensity": 0.3
  }
}
```

设备端负责：

```text
Intent
 ↓
Animation / Motion Mapping
 ↓
Trajectory Planner
 ↓
Limit
 ↓
Closed-loop Motor Control
```

这样：

- 模型不会产生危险角度；
- 不同硬件版本可复用同一策略；
- 动作风格可以调参；
- 大模型不参与实时控制。

---

# 22. 表情与动作词典

建议第一版控制在有限集合。

## Expression

- neutral
- listening
- soft_concern
- happy
- excited
- playful
- thinking
- sleepy
- embarrassed
- apologetic

## Motion

- rest
- look_at_user
- return_center
- small_nod
- double_nod
- slight_head_tilt
- look_down
- curious_tilt
- small_shake

动作必须是：

> 语义表达，而不是机械炫技。

---

# 23. PC Bridge 与情绪模型如何连接

PC Bridge 不应由大模型任意执行。

链路：

```text
User
 ↓
Hushlight Companion Model
 ↓
action_candidate
 ↓
Cloud Policy
 ↓
Confirmation
 ↓
PC Bridge
 ↓
Adapter
 ↓
Real Result
```

例如：

> “今天有点累。”

模型：

```text
Need = low_stimulation_companionship
Strategy = offer_music
```

小熙：

> “要不要放点你平时听的？”

用户：

> “嗯。”

此时才：

```text
music.search_and_play
```

这就是：

> 陪伴 → 理解 → 建议 → 用户接受 → 行动

而不是：

> 检测疲劳 → 自动播放音乐

---

# 24. 模型路由

正式产品不建议所有请求都走 9B。

推荐：

```text
                    User
                      ↓
               Context Builder
                      ↓
             Hushlight-4B
                      ↓
              confidence/router
               ↙            ↘
        normal/high         difficult/low
            ↓                    ↓
        4B result              9B fallback
               ↘            ↙
                Policy Engine
                     ↓
          TTS / Motion / Tool
```

---

# 25. 哪些请求应升级 9B

建议至少：

- confidence < threshold；
- 超长上下文；
- 复杂关系问题；
- 多目标请求；
- 需要复杂规划；
- 对话明显偏离训练分布；
- 安全风险；
- Tool Intent 冲突；
- Emotion / Acoustic 特征矛盾。

其余普通聊天优先 4B。

---

# 26. 为什么这比全量 9B 更适合消费硬件

优势：

### 成本

4B 推理成本更低。

### 延迟

首 Token 更快。

### 并发

同 GPU 可服务更多用户。

### 可训练性

LoRA 和 DPO 成本更低。

### 产品稳定性

80% 的普通陪伴场景没有必要使用更大模型。

---

# 27. 训练平台与工具链

## 27.1 推荐：AutoDL + RTX 4090

研发阶段优先选择按需 GPU。

Qwen3.5-4B 第一阶段推荐：

- RTX 4090 24GB；
- LoRA / QLoRA；
- BF16 / 低比特训练按实际兼容性测试；
- Gradient Checkpointing；
- 小 Batch + Gradient Accumulation。

不需要第一天就租 A100 80G。

A100 适合：

- 9B 更大 Batch；
- Full Fine-tuning；
- 高并发数据生成；
- 大规模 Experiment。

---

## 27.2 训练框架：ms-swift

理由：

- 已支持 Qwen3.5 0.8B / 2B / 4B / 9B / 27B 等模型；
- 与 ModelScope / Qwen 路线兼容；
- 支持 SFT；
- 支持 LoRA；
- 支持 Preference Training；
- 支持部署与推理流程。

备选：

- LLaMA-Factory；
- Transformers + TRL。

---

# 28. 训练阶段建议

```text
M0
原始 Qwen3.5-4B

 ↓ Gold Set Benchmark

M1
5K~10K Seed SFT

 ↓ Evaluate

M2
30K~50K Curated SFT

 ↓ Evaluate

M3
DPO

 ↓ Evaluate

M4
线上 Shadow Test

 ↓

Hushlight-Companion-4B V1
```

---

# 29. 第一版不建议做的东西

暂时不要：

- 从零 Pretrain；
- Full RLHF；
- PPO；
- 复杂 Reward Model；
- 多 Agent 情绪链；
- 本地大模型；
- 每秒视觉大模型；
- 100+ Emotion 标签；
- 所有聊天永久记忆；
- 9B 全量在线推理。

这些都会明显拉高研发和运营成本，但对 V1 核心体验贡献不成比例。

---

# 30. Evaluation 体系

模型研发不能靠“感觉挺温柔”。

必须有离线 Benchmark。

建议每次训练比较：

```text
Base 4B
Hushlight SFT 4B
Hushlight DPO 4B
9B Teacher
Character API
```

---

# 31. 关键指标

## Emotion / Need

- Emotion Macro-F1；
- Need Accuracy；
- Multi-label F1。

## Strategy

- Strategy Accuracy；
- Avoid Violation Rate。

## Persona

- Persona Consistency。

## Behavior

- Over-advice Rate；
- Over-talking Rate；
- Unnecessary Follow-up Rate；
- Silence Appropriateness；
- Memory Precision；
- Tool False Positive Rate。

## Preference

最重要：

> Human Pairwise Preference Win Rate

即：

```text
Hushlight-4B
vs
Qwen Base
```

用户更喜欢哪一个。

---

# 32. 目标验收建议

第一阶段可定义：

### Hushlight-4B vs Base-4B

Gold Set：

> ≥65% Pairwise Preference Win Rate

### Hushlight-4B vs 9B Teacher

专门陪伴场景：

> 不追求全面超过，但在“回复克制、需求匹配、身体语言策略”上接近或局部超过。

### Action

Tool False Positive：

> <1%

### Memory

不该写入长期记忆的样本：

> Precision 优先于 Recall。

宁愿少记，不要乱记。

---

# 33. 成本设计原则

Hushlight 的 AI 成本应该拆成：

```text
ASR
+
LLM
+
TTS
+
Memory / Vector
+
Backend
```

不要只看 LLM Token。

实际陪伴硬件往往：

> Audio 成本可能比文本 LLM 更值得关注。

因此成本控制包括：

- VAD；
- 静音时不上传；
- 打断后立即停止 TTS；
- 短回复；
- Quiet Mode；
- Context Summary；
- Memory Retrieval Top-K 控制；
- 4B 默认；
- 9B 按需。

---

# 34. “安静也是回应”也是成本能力

例如：

用户：

> “累死了。”

普通 AI：

> 输出 120 字安慰 + 建议。

Hushlight：

> “嗯，今天是真没电了。”

然后：

```text
soft_concern
+
slight_head_tilt
+
quiet_companion
```

语言更少，但陪伴感更强。

这会同时降低：

- LLM 输出 Token；
- TTS 字数；
- 用户认知负担；
- 对话延迟。

因此双轴身体语言不是单纯增加硬件成本。

它反过来可以减少语言表达需求。

---

# 35. 与竞品的能力矩阵

## 必须打平

- Wi-Fi；
- 实时语音；
- 唤醒；
- 连续对话；
- 打断；
- Character；
- Voice；
- Avatar；
- Emotion Recognition；
- Long-term Memory；
- Speaker ID；
- Camera；
- OTA；
- Web 配置；
- 隐私状态。

## Hushlight 第一差异点

### Physical Presence

- 2DoF Head；
- Face Tracking；
- Natural Orientation；
- Body Language；
- Motion + Emotion Synchronization。

## Hushlight 第二差异点

### Emotional Intelligence

```text
Emotion
↓
Need
↓
Strategy
↓
Speak / Silence
↓
Expression
↓
Motion
↓
Action
```

## Hushlight 第三差异点

### From Companion to Action

PC Bridge：

- 音乐；
- 音量；
- Reminder；
- 打开内容；
- 消息草稿；
- 经确认发送。

---

# 36. 为什么硬件和模型必须一起设计

如果没有双轴：

模型只能用语言表达。

于是：

> 开心需要说；
> 理解需要说；
> 关心需要说；
> 安静也很难表达。

有双轴以后：

```text
语言
+
面部
+
身体
```

可以共同表达。

例如：

### 理解

```text
“嗯。”
+
small_nod
```

### 疑惑

```text
“嗯？”
+
slight_head_tilt
```

### 安静陪伴

```text
No Speech
+
soft_concern
+
look_at_user
```

这就是 Hushlight 应该形成的数据特点。

---

# 37. 建议新增一种数据：Multimodal Behavior Preference

DPO 不应该只比较两句话。

还可以比较：

### A

```text
Reply: 长篇安慰
Motion: none
```

### B

```text
Reply: “嗯。”
Motion: small_nod
Expression: soft_concern
```

在某些场景：

```text
B > A
```

这是普通聊天模型训练集几乎没有的数据。

这会成为 Hushlight 很独特的资产。

---

# 38. 研发任务分解

## AI-001 CompanionState Schema

Owner：AI / Product

输出：

- Emotion；
- Need；
- Strategy；
- Expression；
- Motion；
- Memory；
- Action；
- Confidence。

完成标准：

- JSON Schema；
- 枚举；
- 版本号；
- 20 个样例。

---

## AI-002 Gold Set

数量：

500。

完成标准：

- 场景覆盖；
- 人工目标；
- 不进入训练。

---

## AI-003 Base Benchmark

模型：

- Qwen3.5-4B；
- Qwen3.5-9B；
- Character API。

输出：

- Pairwise；
- 问题分类；
- Failure Mode。

---

## AI-004 Seed SFT Dataset

5K～10K。

重点：

- 小熙风格；
- 需求理解；
- Silence；
- Motion；
- Memory；
- Action。

---

## AI-005 SFT V1

训练：

Qwen3.5-4B + LoRA。

---

## AI-006 Preference Dataset

10K 级起步。

Good / Bad。

---

## AI-007 DPO V1

目标：

提升：

- 克制；
- 自然；
- Persona；
- Strategy。

---

## AI-008 Model Router

4B / 9B。

---

## AI-009 Online Shadow Test

不直接影响真实动作。

比较：

```text
Production Output
vs
Candidate Model
```

---

# 39. 12 周建议 Roadmap

## Week 1

冻结：

- CompanionState；
- Emotion；
- Need；
- Strategy。

## Week 2～3

完成：

500 Gold Set。

## Week 3

Benchmark：

- 4B；
- 9B；
- Character。

## Week 4～5

制作：

5K Seed SFT。

## Week 6

训练：

SFT-4B V0.1。

## Week 7

Error Analysis。

## Week 8

扩充：

30K 数据。

## Week 9

SFT V0.2。

## Week 10

构建 DPO。

## Week 11

DPO Training。

## Week 12

设备闭环：

```text
Speech
→
CompanionState
→
TTS
→
Expression
→
Motion
→
PC Bridge
```

---

# 40. 风险

## R1 数据太“心理咨询”

结果：

小熙变成：

> “根据你的描述，我建议……”

解决：

- 降低 counseling dataset 比例；
- 大量普通生活语料；
- Preference Training；
- Less Advice Rule。

---

## R2 过度安慰

解决：

DPO 强化：

```text
Brief > Overcomfort
```

---

## R3 模型话太多

解决：

- 回复长度作为训练字段；
- Reward 中加入 brevity；
- Quiet Mode。

---

## R4 Persona 太重

角色化过度会变成：

> 二次元角色扮演 Bot。

解决：

Persona 是风格层，不应该覆盖：

- Need；
- Safety；
- Memory；
- Tool Policy。

---

## R5 模型控制动作过多

解决：

只允许有限 Motion Intent。

---

## R6 Memory 污染

解决：

- Memory Candidate；
- Rule Engine；
- 用户可查看；
- 用户可删除；
- Precision First。

---

## R7 训练数据许可

正式数据仓库需要：

```text
dataset
source
license
commercial_allowed
attribution_required
copyright_risk
approved_by
version
```

没有通过 License Gate 的数据禁止进入 Production Training Pool。

---

# 41. 最终推荐技术栈

```text
┌───────────────────────┐
│       Hushlight       │
└───────────┬───────────┘
            │

DEVICE
├── BASE-S3
│   └── Audio / Wi-Fi
├── HEAD-S3
│   └── AMOLED / Vision
└── MOTION-C3
    └── 2DoF Control

            │
            ▼

CLOUD GATEWAY
├── Session
├── ASR
├── Speaker ID
├── Acoustic Emotion
└── Memory Retrieval

            │
            ▼

HUSHLIGHT COMPANION MODEL
Qwen3.5-4B
+ SFT
+ DPO

Output:
├── Emotion
├── Need
├── Strategy
├── Reply
├── Expression
├── Motion
├── Memory Candidate
└── Action Candidate

            │
      ┌─────┴─────┐
      ↓           ↓
confidence      fallback
 high             low
      │           │
      │      Qwen3.5-9B
      └─────┬─────┘
            ▼

POLICY ENGINE
├── Safety
├── Memory Policy
├── Tool Policy
└── Confirmation

     ┌──────┼──────┐
     ↓      ↓      ↓
    TTS   Device  PC Bridge
```

---

# 42. 最终结论

Hushlight 不需要和大厂比赛：

> “谁的大模型参数更多。”

真正应该比赛的是：

> “谁更知道这个时刻应该怎么陪人。”

因此项目的 AI 核心不应该是：

> Qwen3.5-4B。

而应该是：

> **Qwen3.5-4B + Hushlight Emotional Interaction Dataset + Preference Dataset + CompanionState + Policy Engine。**

其中：

- Qwen 是可替换的；
- GPU 是可替换的；
- 云服务商是可替换的；
- ASR/TTS 是可替换的。

真正不可替代的是：

1. Hushlight 的情绪 → 需求模型；
2. Hushlight 的交互策略 taxonomy；
3. 什么时候说、说多少、什么时候安静的数据；
4. 语言、表情与身体动作的协同数据；
5. 长期记忆边界；
6. 陪伴到行动的策略数据。

最终产品不应该只是：

> “桌面上一个带屏幕的 AI。”

而应该让用户产生：

> **“它刚才真的知道我现在不想听大道理。”**

或者：

> **“我什么都没说，它只是转过来看了我一眼。”**

这才是 Hushlight 的核心产品体验。

---

# 附录 A：当前推荐冻结项

| 项目 | 推荐 |
|---|---|
| AI 主模型 | Qwen3.5-4B |
| Teacher | Qwen3.5-9B |
| Fallback | Qwen3.5-9B / 强模型 API |
| Training | SFT + DPO |
| Framework | ms-swift |
| 初期 GPU | RTX 4090 24GB |
| Device LLM | 不运行 |
| Vision | 端侧目标位置 |
| Motor | MOTION-C3 本地闭环 |
| Memory | Cloud authoritative + Policy |
| Tool | PC Bridge |
| Core Dataset | Hushlight 自建 |
| Gold Set | 500 |
| Seed SFT | 5K～10K |
| Expanded SFT | 30K～50K |
| Preference | 10K+ 起步 |
| 核心评价 | Pairwise Preference |

---

# 附录 B：公开资料与当前技术基线

1. Qwen3.5-4B  
   https://huggingface.co/Qwen/Qwen3.5-4B  
   当前模型卡标记为 Apache-2.0。

2. ms-swift Supported Models  
   https://github.com/modelscope/ms-swift/blob/main/docs/source/Instruction/Supported-models-and-datasets.md  
   当前列出 Qwen3.5 0.8B、2B、4B、9B、27B 等模型。

3. Google Research / GoEmotions  
   https://github.com/google-research/google-research  
   Google Research 仓库声明其中数据集为 CC BY 4.0。

4. ESConv  
   https://github.com/thu-coai/Emotional-Support-Conversation  
   官方声明 Data and codes are for academic research use only。

5. CPED  
   https://github.com/scutcyr/CPED  
   中文情绪与个性化多轮对话数据，约 12K dialogues / 133K utterances，含 13 emotion 与 19 dialogue acts。

---

# 附录 C：建议后续新增仓库文档

建议在 `docs/` 下新增：

```text
14_companion_state_schema.md
15_ai_training_plan.md
16_gold_set_spec.md
17_dataset_license_registry.md
18_model_evaluation_protocol.md
```

其中本文件可作为 `15_ai_training_plan.md` 的初始基线继续演进。
