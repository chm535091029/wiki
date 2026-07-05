<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<title>13 · System Prompt 结构对比</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=Noto+Serif+SC:wght@600;700;900&family=Inter:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500;600&display=swap" rel="stylesheet">
<link rel="stylesheet" href="../shared/tokens.css">
<style>
  body { background: var(--bg-warm); }
  .content { overflow-y: auto; }
  .sp-compare { display: grid; grid-template-columns: 1fr 1fr; gap: 28px; flex: 1; }
  .sp-col { background: var(--bg-card); border-radius: 12px; border: 1px solid var(--border-light); overflow: hidden; display: flex; flex-direction: column; }
  .sp-col-header { padding: 18px 28px; font-size: 28px; font-weight: 700; color: #fff; display: flex; align-items: center; gap: 12px; }
  .sp-col-cyg .sp-col-header { background: var(--accent-cyg); }
  .sp-col-claude .sp-col-header { background: var(--accent-claude); }
  .sp-col-body { padding: 18px 24px; flex: 1; overflow-y: auto; font-size: 18px; line-height: 1.5; }
  .sp-section { margin-bottom: 14px; border-left: 3px solid var(--border-light); padding-left: 14px; }
  .sp-section.cyg-accent { border-left-color: var(--accent-cyg); }
  .sp-section.claude-accent { border-left-color: var(--accent-claude); }
  .sp-section .sp-sec-title { font-family: var(--font-mono); font-size: 16px; font-weight: 600; letter-spacing: 0.04em; text-transform: uppercase; margin-bottom: 4px; }
  .sp-col-cyg .sp-sec-title { color: var(--accent-cyg); }
  .sp-col-claude .sp-sec-title { color: var(--accent-claude); }
  .sp-section .sp-sec-body { font-size: 18px; line-height: 1.45; color: var(--text-body); }
  .insight-box { margin-top: auto; background: var(--bg-card-alt); border: 1px solid var(--border-light); border-radius: 8px; padding: 12px 16px; font-size: 18px; line-height: 1.5; }
  .insight-box strong { color: var(--accent-gold); }
  .diff-badge { display: inline-block; font-size: 14px; font-weight: 600; padding: 1px 8px; border-radius: 4px; margin-right: 4px; }
  .diff-badge.cyg { background: rgba(196,69,54,0.1); color: var(--accent-cyg); }
  .diff-badge.claude { background: rgba(45,106,111,0.1); color: var(--accent-claude); }
  .diff-table { width: 100%; font-size: 18px; border-collapse: collapse; margin-top: 8px; }
  .diff-table th { font-size: 16px; text-align: left; padding: 6px 10px; background: rgba(0,0,0,0.02); border-bottom: 2px solid var(--border-light); color: var(--accent-shared); letter-spacing: 0.04em; }
  .diff-table td { padding: 6px 10px; border-bottom: 1px solid rgba(0,0,0,0.04); vertical-align: top; }
  .diff-table tr:hover td { background: rgba(0,0,0,0.01); }
  h2 { font-size: 38px !important; }
  .bottom-strip { display: grid; grid-template-columns: 1fr 1fr 1fr; gap: 16px; margin-top: 14px; }
  .bottom-card { background: var(--bg-card); border-radius: 10px; border: 1px solid var(--border-light); padding: 14px 18px; text-align: center; }
  .bottom-card .bc-head { font-size: 20px; font-weight: 700; margin-bottom: 6px; }
  .bottom-card .bc-body { font-size: 18px; line-height: 1.45; color: var(--text-body); }
</style>
</head>
<body>
<div class="page-inner">
  <div class="page-header">
    <div class="logo-bar"><span class="dot-cyg"></span> CygCode <span class="sep">&middot;</span> <span class="dot-claude"></span> Claude Code</div>
    <div class="tag">Harness Engineering &middot; 调研报告</div>
  </div>
  <div class="content">
    <div class="kicker claude">对比分析</div>
    <h2>System Prompt 结构对比 &mdash; CygCode vs Claude Code</h2>

    <div class="sp-compare">
      <!-- CygCode -->
      <div class="sp-col sp-col-cyg">
        <div class="sp-col-header">&#x1F7E0; CygCode System Prompt</div>
        <div class="sp-col-body">
          <div class="sp-section cyg-accent"><div class="sp-sec-title">1. 身份定义</div><div class="sp-sec-body">"你是 <strong>Cyg Code</strong>，一位技术高超的软件工程师" &mdash; <strong>拟人化</strong>。有名有姓，赋予身份感和专业责任感。</div></div>
          <div class="sp-section cyg-accent"><div class="sp-sec-title">2. 工具使用说明</div><div class="sp-sec-body">列出所有可用工具及其使用策略：并行调用原则、task_progress 跟踪、ask_followup_question。<strong>工具教学意味强</strong>。</div></div>
          <div class="sp-section cyg-accent"><div class="sp-sec-title">3. ACT MODE vs PLAN MODE</div><div class="sp-sec-body"><strong>两种模式显式定义在 SP 中</strong>。PLAN MODE 收集信息→制定计划→用户批准；ACT MODE 执行。plan_mode_respond vs attempt_completion 工具分离。</div></div>
          <div class="sp-section cyg-accent"><div class="sp-sec-title">4. 能力声明</div><div class="sp-sec-body">列出 CLI 命令、文件操作、搜索、代码定义等所有能力。强调<strong>"你可以做什么"</strong>&mdash;&mdash;能力清单式教育。</div></div>
          <div class="sp-section cyg-accent"><div class="sp-sec-title">5. SKILLS（技能库）</div><div class="sp-sec-body">可激活的技能：add-new-knowledge、extract-pdf、huashu-design。通过 use_skill 按需加载。<strong>类似 micro-app 模式</strong>。</div></div>
          <div class="sp-section cyg-accent"><div class="sp-sec-title">6. 任务进度追踪</div><div class="sp-sec-body"><strong>task_progress 内嵌到每个工具调用</strong>&mdash;&mdash;不是可选功能，是基础设施。每步都必须更新 checklist。</div></div>
          <div class="insight-box"><strong>&#x1F4A1; CygCode 核心理念：</strong>把 agent 当作<strong>"合作伙伴"</strong>&mdash;&mdash;给它身份、能力清单、模式切换，通过 task_progress 让进度可感知。偏重<strong>教育式引导</strong>。</div>
        </div>
      </div>
      <!-- Claude Code -->
      <div class="sp-col sp-col-claude">
        <div class="sp-col-header">&#x1F535; Claude Code System Prompt</div>
        <div class="sp-col-body">
          <div class="sp-section claude-accent"><div class="sp-sec-title">1. 身份定义 + 边界声明</div><div class="sp-sec-body">"你是一个<strong>交互式 Agent</strong>"&mdash;&mdash;去人格化。立即声明 <strong>安全边界</strong>（禁止 DoS、恶意攻击、供应链破坏）。</div></div>
          <div class="sp-section claude-accent"><div class="sp-sec-title">2. SYSTEM RULES（运行规则）</div><div class="sp-sec-body">工具输出给用户看、权限模式决定执行、System Reminder 标签说明、Hook 反馈视为用户输入。<strong>运行期约束优先</strong>。</div></div>
          <div class="sp-section claude-accent"><div class="sp-sec-title">3. DOING TASKS（行为准则）</div><div class="sp-sec-body"><strong>精简到极致的编码纪律</strong>：不创建不必要文件、不给时间估算、不投机抽象。三行相似代码好过一个过早的抽象。</div></div>
          <div class="sp-section claude-accent"><div class="sp-sec-title">4. ACTIONS（风险动作）</div><div class="sp-sec-body">明确定义<strong>不可逆操作</strong>需确认：删除文件/分支、force-push、修改 CI/CD、发送消息。授权仅在指定范围有效、不可越界。</div></div>
          <div class="sp-section claude-accent"><div class="sp-sec-title">5. USING YOUR TOOLS</div><div class="sp-sec-body"><strong>专用工具优先原则</strong>&mdash;&mdash;有 Read 工具绝不用 cat；用 TaskCreate 拆分工作。并行调用独立工具。</div></div>
          <div class="sp-section claude-accent"><div class="sp-sec-title">6. OUTPUT EFFICIENCY</div><div class="sp-sec-body"><strong>"直奔主题，极度简练"</strong>。能用一句不用三句。先给答案，不是推导过程。不要复述用户说过的话。</div></div>
          <div class="insight-box"><strong>&#x1F4A1; Claude Code 核心理念：</strong>把 agent 当作<strong>"精密工具"</strong>&mdash;&mdash;最少字定义最严边界。静态段 byte-stable 跨 session 缓存。偏重<strong>约束式治理</strong>。</div>
        </div>
      </div>
    </div>

    <!-- Key dimension comparison table -->
    <p style="font-size:22px; margin-top:10px;"><strong>关键维度差异表</strong></p>
    <table class="diff-table">
      <tr><th style="width:15%;">维度</th><th style="width:42%;"><span class="diff-badge cyg">CygCode</span></th><th style="width:43%;"><span class="diff-badge claude">Claude Code</span></th></tr>
      <tr><td><strong>身份策略</strong></td><td><strong>拟人化</strong>&mdash;&mdash;有名有姓，"技术高超的软件工程师"</td><td><strong>去人格化</strong>&mdash;&mdash;"交互式 Agent"，纯粹角色工具</td></tr>
      <tr><td><strong>SP 结构与编译</strong></td><td><strong>组件化模板引擎</strong>&mdash;&mdash;PromptBuilder + 13 Section + Variant 系统；示例丰富</td><td><strong>静态/动态分离</strong>&mdash;&mdash;byte-stable 静态段（跨 session 缓存）+ per-turn 动态段；极度精简</td></tr>
      <tr><td><strong>模式切换</strong></td><td><strong>ACT MODE / PLAN MODE</strong> 显式定义在 SP 中，工具层面分离（plan_mode_respond vs attempt_completion）</td><td><strong>Plan 模式通过 Permission 实现</strong>&mdash;&mdash;不是 SP 的显式模式，Permission mode="plan" 时禁止写工具</td></tr>
      <tr><td><strong>进度追踪</strong></td><td><strong>task_progress 内嵌到每个工具调用</strong>&mdash;&mdash;基础设施级，每步必须更新 checklist</td><td><strong>TodoWrite / Task V2</strong> 作为独立工具&mdash;&mdash;通过 nudge 系统提醒，不强制</td></tr>
      <tr><td><strong>安全边界</strong></td><td>不显式声明，依赖工具权限控制</td><td><strong>SP 头部即声明</strong>：禁止 DoS、供应链攻击；风险操作需用户确认清单</td></tr>
      <tr><td><strong>输出约束</strong></td><td>教学式、详细；强调"倒金字塔结构"</td><td><strong>极致精简</strong>："直奔主题""能用一句就不用三句""不要复述用户说过的话"</td></tr>
      <tr><td><strong>缓存策略</strong></td><td>模板引擎分离 + 记忆系统（Memory），但无 prompt cache 标记</td><td><strong>byte-stable 静态段 + BOUNDARY 标记</strong>&mdash;&mdash;跨 session 缓存命中，每轮 iteration 零开销</td></tr>
      <tr><td><strong>扩展机制</strong></td><td><strong>Skills</strong>&mdash;&mdash;按需加载的 micro-app（如 huashu-design、extract-pdf）</td><td><strong>Hooks</strong>&mdash;&mdash;27 个生命周期事件，外部脚本可编程注入规则</td></tr>
    </table>

    <!-- Bottom insight strip -->
    <div class="bottom-strip">
      <div class="bottom-card">
        <div class="bc-head" style="color:var(--accent-cyg);">CygCode 思路</div>
        <div class="bc-body"><strong>"教育式引导"</strong>：把 agent 当作需要被"教会"的合作伙伴。详细说明能力、模式、工具用法。task_progress 强制追踪。Skills 扩展专项能力。</div>
      </div>
      <div class="bottom-card">
        <div class="bc-head" style="color:var(--accent-gold);">核心分歧</div>
        <div class="bc-body">一个<strong>教 agent 如何思考</strong>（CygCode），一个<strong>约束 agent 不要越界</strong>（Claude Code）。前者给身份和工具箱，后者给边界和底线。</div>
      </div>
      <div class="bottom-card">
        <div class="bc-head" style="color:var(--accent-claude);">Claude Code 思路</div>
        <div class="bc-body"><strong>"约束式治理"</strong>：把 agent 当作需要被"限制"的精密工具。最少字定义最严边界。静态/动态分离实现缓存零成本。Hooks 让外部可编程。</div>
      </div>
    </div>
  </div>
  <div class="page-footer">
    <span>CC &middot; SP 结构逐段对比 + 关键维度差异 + 设计思路分歧</span>
    <span>13</span>
  </div>
</div>
</body>
</html>
