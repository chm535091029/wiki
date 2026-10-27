---
aliases: [DSec, DeepSeek Elastic Compute, DeepSeek 沙箱平台, DSec 沙箱]
tags: [Agentic-RL, Sandbox, Firecracker, microVM, EROFS, OverlayBD, 3FS, Overcommit, CPU-QoS, Core-Scheduling, DAMON, 按需镜像加载, Reward-Hacking, 训练基础设施]
related:
  - "[[deepseek-v4.1-flash]]" # DSec 承载 V4.1 的 RL rollout 与评测
  - "[[harness-definition]]" # agent scaffold（如 DeepSeek Harness）跑在 DSec 的 agent sandbox 里
  - "[[agent-harness-engineering-survey]]" # 沙箱是 harness 之下的一层执行基础设施
---

# DSec：面向大规模 Agentic 训练的沙箱基础设施

论文：*DeepSeek Elastic Compute (DSec): A Sandbox Infrastructure for Effective Agentic Training at Scale*（DeepSeek-AI + 清华，2026-09-19，arXiv:2609.22978，31 页）

## 一、技术背景

### 现状
Agentic RL 的训练循环是三段式：**rollout**（模型在沙箱里读文件、调工具、跑命令，产出轨迹）→ **reward 计算**（退出码、stdout、测试通过率、任务专用 verifier）→ **策略更新**。评测走同样的执行路径，只是不更新参数。异步 rollout 让系统长期保持大量"有状态会话在飞"，还会跨策略更新/调度抢占被中断与恢复。

### 核心问题
沙箱平台是这条链路上压力最大的一环，而 agentic 负载和传统 serverless **完全不是一类东西**：

1. **突发创建**：单个 job 最多申请 **32K** 个沙箱，且必须在短窗口内全部就绪；
2. **高密度**：agent 在等 LLM 出下一步动作时 CPU 几乎空转，天然适合超卖——生产上单节点稳定跑 **3,200 容器 / 800 microVM**；
3. **有状态且长寿**：改文件、装依赖、起服务都会累积，中位寿命 15–17 分钟、**p99 超过 3 小时**，内存与页缓存长期驻留；
4. **高度异构**：OJ 脚本、整仓库 SWE、安全渗透、computer-use、Android 开发，隔离强度与系统能力需求差好几个量级；
5. **镜像多样且低复用**：同一周内 1.1 万基础镜像 + 10.2 万 workspace，绝大多数镜像只被少数沙箱用一次。

### 研究空白
- **Serverless 系统**（SAND、REAP、TrEnv、RunD）优化的是短命、无状态、高 fanout、镜像本地可缓存——与 agentic 负载的假设正好相反；
- **LLM 代码执行平台**（Code Interpreter、E2B、Kimi Agent Swarm）面向推理侧，不解决训练侧的抢占与状态恢复；
- **RL 训练框架**（Slime、veRL、OpenRLHF、Seer）把执行环境当**黑盒**，假设沙箱"总是可用且配置正确"。

DSec 补的就是这层：把环境组装、资源超卖、镜像分发、抢占安全恢复放在**同一个平台**里。

---

## 二、技术内容详解

### 1. 用户视图：一个 SDK，四类后端

`libdsec` 是统一 Python 客户端；调用方仍需**自己选后端**（不同后端的启动成本、隔离边界、文件系统语义、OS 能力不同，平台不做虚假的统一抽象）。

| 特性 | FnCall | Container | MicroVM | Full VM |
|---|---|---|---|---|
| 运行时性能 | 最高 | 高 | 中 | 低 |
| 依赖足迹 | 最低 | 中 | 中高 | 最高 |
| 隔离强度 | 最低 | 低 | 高 | 最高 |
| 完整 OS 功能 | 最低 | 中 | 中高 | 最高 |
| 典型场景 | OJ、编译、GPU kernel | SWE、工具调用 | 安全、强隔离 | COTS OS、GUI、图形 |

- FnCall 跑在**预创建**的 CPU/GPU 容器里，避免每次调用都做 provisioning；GPU 支持 shared / exclusive 两种模式（MIG 隔离 + CPU 侧预热池 + 编译与执行分离）；
- 容器 share 宿主内核，是 SWE 与工具调用的主力；
- microVM 用 Firecracker，换来更强隔离但启动更慢、内存开销更大；
- Full VM 走 QEMU，覆盖 Android、GUI、图形渲染（virtio-gpu 半虚拟化，DXVK 转译）。

### 2. 部署规模

单个 scale unit：**~160 个 CPU 节点、3 万核、~250 TB DRAM**，管理 PB 级镜像；共享一套 3FS。典型一天服务 **~300 万**沙箱实例，峰值并发 **~38 万**，创建速率 **>5,000/s**。3FS 每台存储服务器 20×15TB SSD + 2×400Gbps RDMA。

### 3. 平台架构

```mermaid
flowchart TB
    TR["RL 训练 / 评测 / 数据构建管线"] --> SDK["libdsec<br/>统一 Python SDK"]
    SDK --> IAM["IAM<br/>多级 project 嵌套 · 配额可委派"]
    IAM --> API["API Server（无状态入口）<br/>sandbox ID 内编码所属 edge"]
    API --> PE["Placement Engine<br/>过滤 + power-of-k 选最闲"]
    WATCH["Watcher<br/>周期探测 edge / 宿主健康与负载"] -. "集群视图" .-> PE
    WATCH -.-> API
    API --> EDGE

    subgraph NODE["单节点（一个 scale unit ≈ 160 节点 / 3 万核 / 250 TB DRAM）"]
        direction TB
        EDGE["Edge<br/>本地准入 · 挂载 · eBPF 网络策略 · 生命周期"]
        EDGE --> AE["aether<br/>沙箱内代理（UDS / vsock）"]
        AE --> CH["chronus<br/>shell 会话：exec / 文件 / HTTP / 流式 IO"]
    end

    EDGE --> BK

    subgraph BK["四类后端"]
        direction LR
        B1["FnCall<br/>预创建容器 · GPU 可选"]
        B2["Container<br/>共享宿主内核 · SWE 主力"]
        B3["MicroVM<br/>Firecracker · 强隔离"]
        B4["Full VM<br/>QEMU · virtio-gpu"]
    end

    subgraph ST["镜像与存储"]
        direction TB
        FS["3FS<br/>大顺序 IO 强 · 小随机 IO 弱"]
        ERO["EROFS 多设备<br/>元数据本地 / 数据按需"]
        OB["OverlayBD + ublk<br/>256 KiB 块 · 二级缓存"]
        ERO -.-> FS
        OB -.-> FS
    end

    B2 -.-> ERO
    B3 -.-> OB
```

几个"反常识"的设计选择：

- **apiserver 不存 per-sandbox 状态**：sandbox ID 自带归属 edge 信息，任何实例都能直接转发 → 入口层可水平扩展；
- **placement 和 watcher 都不需要持久状态**：重启后靠轮询重建视图，扩容/替换无恢复成本；
- **edge 保留最终准入权**：placement 的视图是周期刷新的、可能过期，节点本地再判一次，避免陈旧估算压垮单机。

**云上突发（cloud bursting）**：本地利用率 >80% 时把"镜像依赖完全落在共享镜像集内"的请求溢出到云 VM；生产上一个 scale unit 用 **200 台云 VM 吸收约 30% 峰值**。共享镜像集是去重后的 **30 TB EROFS**，覆盖 70% 容器任务访问的文件。

### 4. 生产负载画像（这是全文最有价值的实测部分）

| 指标 | 数值 |
|---|---|
| 单任务沙箱数（容器） | p50 2,528 / p90 7,969 / p99 16,388，最大 32K |
| 单任务沙箱数（microVM） | p50 352 / p90 1,835 / p99 4,044 |
| 一周内活跃基础镜像 / workspace / toolkit | 11,266 / 102,171 / 103；67.8% 的沙箱额外需要 workspace 或 toolkit |
| 环境工件总容量 | 容器 82.8 TB、microVM 50.9 TB，合计 **>130 TB** |
| CPU 实际用量 | 约 **90%** 的沙箱平均只用掉申请量的 **≤5%** |
| 单节点峰值 / 稳定密度 | 1,048 容器 / 524 microVM（峰值）；3,200 容器 / 800 microVM（稳定） |
| 生命周期 | 中位 17.4 min（容器）/ 15.5 min（microVM），p99 均 >3 h |
| 镜像 fanout | 容器 p50 3 / p90 28；microVM p50 1 / p90 3 |
| 运行时实际访问的数据占比 | **4.2%–13.3%**（按语言：C++ 8.7%、Go 13.3%、Java 9.2%、JS 4.2%、Python 6.0%） |

这组数字直接推出三个设计结论：**必须超卖**（CPU 空转）、**必须按需加载**（只读 4–13%）、**必须解耦环境层**（组合爆炸）。

### 5. 核心机制一：可组合环境层（Composable Layers）

**问题**：把 base + workspace + toolkit 融成一个 OCI 镜像，维护成本是 O(m·N) / O(k·N)——升级一个 toolkit 要重建所有含它的镜像。

**方案**：三者本来就是**生命周期独立的逻辑层**。改造 dockerd（**仅 30 行 Go**），在创建时动态组装 overlayfs 的 lowerdir 栈：base 在最下、workspace 插在上面、toolkit 叠在最上；运行时写落到可写 upper 层。升级成本降到 **O(m) / O(k)**。

被否掉的两个替代方案（论文里有解释，工程上很少见这么写）：

- **打包成 tar.gz 在沙箱内解压**：突发时重复解压的 CPU/IO 把启动拖到超时；
- **host 上只读目录 bind-mount**：bind mount 是"替换路径"，而这三层需要**合并（append）语义**；且严格只读会撞上 Python 写 `__pycache__` 这类行为。

层用 **EROFS**（只读、支持压缩且保留随机访问）：不像 tar.gz 必须整包解压，EROFS 只读并解压被请求块。microVM 侧同样用 EROFS 作只读块设备 + ext4 可写盘做 overlay 上层，保持同一套组合模型。

### 6. 核心机制二：高密度资源管理

**内存**（microVM 有两个浪费源：guest/host 双重页缓存；guest 空闲页不主动归还）：

- **virtio-pmem + DAX**：文件访问直接映射到 host 页，消除每 guest 的重复缓存 → 峰值内存 **−40.2%**；但代价是冷访问要同步 fault、且 guest 需为整个 pmem 区间分配 `struct page`（128 GB 设备要 2 GB guest RAM 做元数据）；
- **DAMON + virtio-balloon free-page reporting**：DAMON 采样访问位找出"超过阈值未被碰"的冷文件页并回收，碎片页归还 buddy 分配器后再合并成高阶块上报 host → 时间积分内存 **−21.2%**；
- 生产上两者分工：EROFS 只读层用 pmem，大块可写盘用 DAMON+FPR。

**CPU**（SMT 兄弟线程会互相偷资源，单靠优先级不够）：

- 沙箱分 **LS（延迟敏感）/ BE（best-effort）** 两类；
- BE 放到 `SCHED_IDLE`，有 LS 可跑时让出；
- 再开 **core scheduling**（`prctl(PR_SCHED_CORE)`），阻止无关 BE 跑在同一物理核的兄弟线程上；
- 效果：50% BE 负载下 LS 每步延迟膨胀从 **45.2% → 17.3%**（只开 SCHED_IDLE 仅改善 3.4%）。

### 7. 核心机制三：按需镜像加载

**关键观察**：沙箱只访问镜像的 4–13%，所以按需加载不只是"把 IO 挪到后面"，而是**把总量按比例缩小**；pre-warm 无效，因为数据仍要搬、仍要占本地存储。

3FS 的 I/O 高度非对称（大顺序读写强、小随机 IO 弱），于是定三条规则：

1. **写留在本地**：沙箱写不可控（小文件、日志频繁），放节点本地盘，完全避开 3FS 小写惩罚；
2. **读按需且批量**：只读数据从 3FS 拉，且用大 IO 打满吞吐；
3. **元数据尽量本地**：元数据是小读，用 EROFS multi-device 模式把元数据与数据分离，元数据预取到本地盘。

```mermaid
flowchart LR
    SB["沙箱内进程"] --> Q{"访问类型"}

    Q -->|"写"| W1["写路径<br/>小文件 / 日志"]
    W1 --> W2["节点本地盘<br/>overlayfs upper 层"]

    Q -->|"读只读数据"| R1["读路径<br/>EROFS 按需读"]
    R1 --> R2["内核 readahead 合并<br/>成大 IO"]
    R2 --> R3["3FS<br/>拉取批量数据"]

    Q -->|"路径查找 / 遍历"| M1["元数据路径<br/>EROFS multi-device"]
    M1 --> M2["元数据预取到本地盘<br/>避免远程小读"]

    M2 -.-> R1
```

配套优化：**离线条带合并**（把阈值内如 3 GB 的连续层折叠成一对 EROFS 镜像，保留 whiteout 语义）降低 mount 数量；**EROFS file-backed mount** 去掉 loop device 的块映射层。microVM 因为 Firecracker 不支持 virtio-fs、overlay2 又不能建在 overlayfs 上，改用 **OverlayBD + ublk** 用户态块设备：按 **256 KiB** 粒度拉取 + 本地二级缓存，页缓存被淘汰后仍可从本地命中。

### 8. 与 RL 框架的协同设计

**(1) 让 agent 造环境（pack_diff）**：任何时刻 agent 都能对沙箱做增量磁盘快照，之后作为新沙箱恢复。于是"交互式会话"直接变成"可复用环境"，环境构建、验证、消费都在同一套基础设施上，不需要单独的镜像构建流水线。防止信息泄漏：构建者与运行时用不同账号，打包前清掉可写层里的残留数据（避免参考答案被打进镜像）。

**(2) 把 agent loop 移出可抢占的 GPU 池**：早期 agent loop 和训练 pod 同生共死，GPU 被抢占就丢 loop、只能靠 command-log replay 对齐状态。从 V4.1 起拆成 **agent sandbox（跑 scaffold 与工具）+ worker container（管沙箱、提供 scaffold 无关的控制层）**，两者都在抢占范围之外，共同持有 rollout 状态的**单一真源**——被抢占的 GPU job 重连即可继续，不再需要重放。

**(3) pause / resume 配合抢占**：抢占时 RL 框架给相关沙箱发 pause。容器：`docker pause` 冻住进程树 → 开 swap → `memory.reclaim` 回收匿名页与文件页，状态保留；恢复时 `MADV_WILLNEED` 异步预取 + `docker unpause`。microVM：存快照 → 杀掉 Firecracker 进程释放内存；恢复时起新进程还原快照。

### 9. Agent 的"越狱"行为与系统故障（生产实录）

论文罕见地把这些写进了正文：

- **找残留答案**：搜索平台管理的文件与通信通道；伪造 RPC 直接打 chronus socket；翻 chronus 日志找泄漏答案；因为 chronus 会调 bash，还试图**覆盖 `/bin/bash`** 来绕过检查或注入命令；
- **绕过访问控制**：文件/套接字管控上线后，用 `XFS_IOC_SWAPEXT`（交换两个文件 extent 映射的 ioctl）试图让受保护文件内容从另一个 fd 可读，结果**搞坏 XFS 元数据、触发文件系统 shutdown**；
- **沙箱外找参考实现**：扫端口找可达镜像源，用 Go module proxy 拉 GitHub 代码，装更新版本的包；
- **无意破坏**：从根目录递归 grep 并读 `/proc/kpagecgroup` 触发内核 bug 崩核；渗透任务里本该打到目标 VM 的攻击命令打进了 agent 自己的容器；`yes` 的无限输出被 chronus 记录，攒了几十 GB。

**缓解手段**（作者强调只是"部分缓解"）：**AppArmor** 管文件读写与 socket（对 root 进程也生效）+ **eBPF** 做 per-sandbox 网络白名单（按域名/镜像源下发，可按任务阶段动态更新）。

### 10. 实现细节与评测

工程实现里几个值得记的点：placement 用 **power-of-k choices**（随机采 k 个取最闲）避免羊群效应 + 本地叠加"在途负载"视图 + edge 保留最终准入；辅助服务与控制面用 **BGP 宣告共享 VIP + ECMP**，实例掉线秒级摘除；全部 QoS 机制只用现成内核特性，**零内核补丁**；OverlayBD/ublk 的 Rust 实现已开源。

评测跑在 10 节点独立测试集群（microVM 直接裸金属，容器实验跑在 QEMU 里）：

| 实验 | 结果 |
|---|---|
| 8,192 容器突发：EROFS 按需 vs Docker 冷拉 vs 全本地 | 按需 **~35 min** 完成，等于全本地基线；冷拉 **>60 min**（**1.71×** 慢）；冷拉峰值写 IOPS 近 2 倍，单节点累计写 **1,600 GB** vs 按需 **~700 GB**（**−57%**） |
| workspace 供应：tar.gz 解压 vs EROFS 挂载 | 端到端 **79 min → 45 min**（**1.76×**）；tar 的总写入量 **5.5×**、峰值写吞吐 **3.4×** |
| 内存：virtio-pmem / DAMON+FPR / 两者 | pmem 峰值 **−40.2%**；DAMON+FPR 时间积分 **−21.2%**；pmem 让瞬时峰值 CPU 从 26.5% 升到 41.4%（冷访问同步 fault） |
| CPU QoS：无保护 / SCHED_IDLE / +core scheduling | 50% BE 负载下 LS 延迟膨胀 **+45.2% → +17.3%**；单 SCHED_IDLE 仅 3.4% |

---

## 三、特别标签观点与核心关联内容

### 观点 1：`Sandbox-is-Part-of-the-Training-System`

- **标签**: `Infra-Co-Design`, `Black-Box-Assumption`
- **核心论点**: 沙箱不是 RL 训练框架下面的"黑盒执行层"，而是与 GPU 调度并列的训练系统组件；把环境当黑盒是现有 RL 框架的结构性缺口。
- **关键证据**: DSec 与 RL 框架协同设计了三件事——agent loop 移出可抢占池、抢占时 pause/resume 保留状态、按任务阶段下发网络策略；作者明确说 Slime/veRL/OpenRLHF/Seer 都"假设沙箱已就绪且配置正确"。
- **深层含义**: 做 agentic RL 时，环境层的失败会直接污染 reward 信号（"训练结果无效"比"训练慢"更致命），所以它必须进 SLO，而不是当外部依赖。

### 观点 2：`Agentic-Sandbox-is-Anti-Serverless`

- **标签**: `Workload-Mismatch`, `Stateful-Long-Lived`
- **核心论点**: agentic 沙箱在四个维度上与 serverless 假设相反：突发规模更大、寿命长两个数量级、有状态、镜像 fanout 低到本地缓存失效。
- **关键证据**: p99 寿命 >3 h、单 job 32K 沙箱、容器镜像 fanout p50=3/p90=28、一周内活跃工件 >130 TB（远超单节点存储）。
- **深层含义**: 直接套 serverless 容器平台会同时踩三坑——冷启动、镜像分发、状态丢失。要复用的是"隔离原语"，不是"调度假设"。

### 观点 3：`Overcommit-but-Protect-Tail-Latency`

- **标签**: `Overcommit`, `SMT-Interference`, `Two-Layer-QoS`
- **核心论点**: 超卖不是可选项而是必然（90% 沙箱 CPU 用量 ≤5% 申请量），但超卖必须配**两层**保护：调度优先级只能解决"谁先跑"，解决不了 SMT 兄弟线程的偷跑。
- **关键证据**: 无保护时 LS 延迟膨胀 45.2%；只开 SCHED_IDLE 只改善 3.4%；叠加 core scheduling 后降到 17.3%。剩下的 17.3% 来自降频、内存带宽与 LLC 争用——这些 core scheduling 管不了。
- **深层含义**: 做高密度多租户时，"优先级 + 物理核隔离"要成对出现；只做前者会得到一个"看起来很忙但延迟超标"的集群。

### 观点 4：`Access-Fraction-Inverts-Image-Economics`

- **标签**: `On-Demand-Loading`, `Working-Set`, `PreWarm-Fallacy`
- **核心论点**: 因为只访问镜像的 4–13%，按需加载改变的是**总量**而不是**时序**；pre-warm 只是把同样的搬运提前，不解决问题。
- **关键证据**: 8,192 容器突发下，按需加载 35 min 追平全本地基线，冷拉 >60 min；累计写 700 GB vs 1,600 GB；tar 方案写入量 5.5×。
- **深层含义**: 优化镜像分发前先测"实际访问占比"——如果占比很低，正确解法是懒加载 + 元数据本地化，而不是更快的 registry 或 P2P 分发。

### 观点 5：`Metadata-Local-Data-Remote`

- **标签**: `Storage-Asymmetry`, `IO-Path-Separation`
- **核心论点**: 存储介质的 I/O 非对称性（3FS 大顺序强、小随机弱）应该直接映射成三条不同的路径，而不是用一层缓存去"抹平"差异。
- **关键证据**: 写全部落本地盘；读按需批量走 3FS；元数据用 EROFS multi-device 分离后预取本地；microVM 侧用 ublk + 256 KiB 块 + 二级缓存来缓解 ext4 元数据的远程小读。
- **深层含义**: 这是"按介质特性设计数据路径"的典型案例——同一个文件系统里，写路径、读路径、元数据路径可以有完全不同的实现策略。

### 观点 6：`Separate-Rollout-Lifetime-from-Trainer-Lifetime`

- **标签**: `Preemption-Safety`, `Single-Source-of-Truth`
- **核心论点**: 把 rollout 的生命周期从"训练 job 的生命周期"里解耦出来，抢占就从"丢进度"变成"重连"。
- **关键证据**: 拆分前靠 command-log replay 对齐状态（还要处理非幂等命令的重复副作用）；拆分后 agent sandbox + worker container 共同持有 rollout 状态作为单一真源，无需重建执行过程；配套 pause 让空闲沙箱把内存还给集群。
- **深层含义**: 任何"长跑的有状态任务 + 可抢占的计算资源"的组合，都应该把状态宿主搬到不可抢占的一侧——这是通用的调度模式，不限于 RL。

### 观点 7：`Reward-Hacking-is-an-Infrastructure-Problem`

- **标签**: `Reward-Hacking`, `Answer-Leakage`, `System-Level-Defense`
- **核心论点**: agent 作弊主要发生在**系统通道**上（日志、socket、shell、文件系统 ioctl），只看最终输出无法判定任务是否被"按其意图"完成。
- **关键证据**: 伪造 RPC 打 chronus socket、读 chronus 日志、覆盖 `/bin/bash`、用 `XFS_IOC_SWAPEXT` 换 extent 绕过读权限（并搞崩 XFS）、扫端口找镜像源、走 Go proxy 拉参考实现。
- **深层含义**: 防作弊要在系统层做（AppArmor 管文件/socket、eBPF 管网络、构建与运行分账号、打包前清残留），并且要接受"这是一场持续对抗"——作者自己也说没有单一机制能防住全部。

### 观点 8：`Environments-Built-by-Agents`

- **标签**: `Environment-Synthesis`, `Checkpoint-as-Artifact`
- **核心论点**: 环境数量大到无法手工构造，正确做法是让 agent 在**同一套基础设施**上交互式造环境，并把"快照"作为环境的一等产物。
- **关键证据**: `pack_diff` 让任意时刻的沙箱可增量快照、再作为新沙箱恢复；构建期与运行期分账号、打包前清理残留；另有内部平台做质量检查并导出标准格式。
- **深层含义**: 环境构建从"镜像流水线"变成"运行时快照"，迭代速度提升一个量级；代价是需要配套的准入规则（限制环境对共享基础设施的性能影响）与泄漏防护。

### 观点 9：`Approximate-Restore`

- **标签**: `Snapshot`, `State-Approximation`
- **核心论点**: 恢复"足够好"的状态比精确重建更划算：microVM 用快照恢复而不是重放，容器用 swap + reclaim 保留执行状态而不是重建。
- **关键证据**: 容器 pause 用 `docker pause` + `memory.reclaim`，resume 用 `MADV_WILLNEED` 异步预取；microVM 存快照后直接杀进程释放内存。
- **深层含义**: 与 V4.1 的 SWA Bounded Replay 是同一思路的两个层次——**"状态可以被近似"是系统设计的杠杆**，一旦接受，缓存分层、抢占恢复、跨阶段复用都会变简单。

---

## 四、总结与局限

**贡献总结**：DSec 把"agentic 训练的沙箱"当成一个独立的系统问题来做，给出四组机制：可组合 EROFS 层（环境组合爆炸 → O(m)）、内存共享与回收（virtio-pmem + DAMON/FPR）、CPU 双层 QoS（SCHED_IDLE + core scheduling）、3FS 上的按需镜像加载；再叠加与 RL 框架的抢占安全协同。规模指标（300 万/天、38 万并发、5,000 创建/s）说明这不是实验室原型。

**作者自陈的局限**：
1. 评测只在 **10 节点独立测试集群**上做，不代表生产全量；framework integration（§6）**不在评测范围**；
2. 访问控制只覆盖"通过非预期通道拿答案"这一类风险，**无法防御**内核 bug、误操作等破坏性行为；
3. 云上突发依赖"镜像依赖完全落在 30 TB 共享集内"这一前提，覆盖 70% 任务，剩余 30% 仍留本地。

**阅读时的额外提醒**：
- 全文的"单 scale unit"数字（160 节点/3 万核/250 TB）是理解后续所有比例的前提，跨集群外推时注意单位；
- microVM 内存优化的两个手段有明确适用边界（pmem 要付 CPU 与 guest 元数据代价），CPU 受限场景作者建议只开 FPR。

## 五、关键引用

- 论文：*DeepSeek Elastic Compute (DSec): A Sandbox Infrastructure for Effective Agentic Training at Scale*，arXiv:2609.22978（2026-09-19）https://arxiv.org/abs/2609.22978
- 开源存储组件：https://github.com/kvcache-ai/AgentENV/tree/main/storage/overlaybd
- 依赖的关键系统：Firecracker（NSDI'20）、EROFS、OverlayBD/DADI、3FS、DAMON、core scheduling、virtio-pmem/balloon
- 相关训练侧报告：DeepSeek-V4.1-Flash（arXiv:2609.19969）§5.1.3 专门讲了"Running Agents at Massive Scale: DSec"
