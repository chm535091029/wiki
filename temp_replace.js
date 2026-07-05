const fs = require('fs');
const path = 'd:\\A.python project\\wiki\\knowledge\\03-research\\Agent\\harness-engineering\\harness-compare-claude-vs-cygcode\\slides\\09-claude-l5-l8.html';

let c = fs.readFileSync(path, 'utf-8');
console.log('File size:', c.length);

const start = c.indexOf('<!-- 3 concepts');
const end = c.indexOf('<!-- Budget + Read exemption -->');
console.log('Section from', start, 'to', end);

const newSection = `    <!-- 3 concepts with comparison table -->
    <p style="font-size:22px; margin-top:4px;"><strong>投影 vs 替换 vs 压缩 — 三种收缩手段</strong></p>
    <div class="three-concepts">
      <div class="tc-card">
        <div class="tc-head" style="background:var(--accent-claude);">📽 投影 Projection</div>
        <div class="tc-body">
          <p style="font-size:18px;font-style:italic;color:#666;margin-bottom:2px;">像 Git stash：REPL 完整保留，API 只见短 ID</p>
          <p><strong>REPL 保留 · API 不发</strong><br><span style="color:var(--accent-claude);font-weight:700;">✅ 可逆</span></p>
          <table class="tc-table">
            <tr><td>REPL 数据</td><td>✅ 完整保留</td></tr>
            <tr><td>磁盘备份</td><td>❌ 不需要</td></tr>
            <tr><td>发给 API</td><td>❌ 短 ID [id:xxx]</td></tr>
            <tr><td>下轮恢复</td><td>✅ 展开 ID → 全量</td></tr>
          </table>
          <div style="font-size:18px;text-align:left;margin-top:6px;padding-top:6px;border-top:1px solid var(--border-light);">
            <strong>⏱ 触发时机：</strong><br>
            • Snip：HISTORY_SNIP 开启时，每轮检查可投影消息 → 替换为 [id:xxx]<br>
            • Collapse：上下文 >90%/95%，单大 tool 折叠为 [id:foldN]
          </div>
          <div style="font-size:18px;text-align:left;margin-top:4px;">
            <strong>🔁 如何复原：</strong><br>
            模型需要查看时，通过短 ID 回查 REPL state → 提取原文 → 重新注入对话。<br>
            因为 REPL 始终持有完整数据，投影是完全可逆的。
          </div>
          <p style="font-size:18px;margin-top:4px;">snipCompact · contextCollapse</p>
        </div>
      </div>
      <div class="tc-card">
        <div class="tc-head" style="background:var(--accent-cyg);">🗃 替换 Replacement</div>
        <div class="tc-body">
          <p style="font-size:18px;font-style:italic;color:#666;margin-bottom:2px;">像文件缩略图：原文件存磁盘，对话只看预览</p>
          <p><strong>永久改 state.messages</strong><br><span style="color:var(--accent-cyg);font-weight:700;">⚠ 对话不可逆，数据不丢失</span></p>
          <table class="tc-table">
            <tr><td>REPL 数据</td><td>🔄 preview 字符串</td></tr>
            <tr><td>磁盘备份</td><td>✅ 完整保存</td></tr>
            <tr><td>发给 API</td><td>✅ 2KB preview</td></tr>
            <tr><td>下次再发</td><td>✅ byte-identical 不重算</td></tr>
          </table>
          <div style="font-size:18px;text-align:left;margin-top:6px;padding-top:6px;border-top:1px solid var(--border-light);">
            <strong>⏱ 触发时机：</strong><br>
            • 单 msg tool_result > 50K 字符 → 写入磁盘 + 生成 2KB preview + 附加路径提示<br>
            • 同一结果再遇到 → 直接返回缓存中的 byte-identical preview
          </div>
          <div style="font-size:18px;text-align:left;margin-top:4px;">
            <strong>🔁 如何复原：</strong><br>
            state.messages 已被 preview 替换（不可逆）。但原始数据在磁盘上，且 preview 携带路径提示（path hint）。模型需要时可通过 Read 工具重新读取文件，获取完整内容。
          </div>
          <p style="font-size:18px;margin-top:4px;">toolResultBudget</p>
        </div>
      </div>
      <div class="tc-card">
        <div class="tc-head" style="background:var(--accent-gold);">📄 压缩 Compression</div>
        <div class="tc-body">
          <p style="font-size:18px;font-style:italic;color:#666;margin-bottom:2px;">像会议纪要：保留要点，丢掉逐字稿</p>
          <p><strong>splice 删除 + summary</strong><br><span style="color:var(--accent-gold);font-weight:700;">⚠ 不可逆，但 L7 保证规则不丢</span></p>
          <table class="tc-table">
            <tr><td>REPL 数据</td><td>❌ splice 删除</td></tr>
            <tr><td>磁盘备份</td><td>🔄 session log 可查</td></tr>
            <tr><td>发给 API</td><td>✅ summary (~5K)</td></tr>
            <tr><td>下轮恢复</td><td>❌ 需手动从 log 恢复</td></tr>
          </table>
          <div style="font-size:18px;text-align:left;margin-top:6px;padding-top:6px;border-top:1px solid var(--border-light);">
            <strong>⏱ 触发时机：</strong><br>
            • autoCompact：token ≥ effectiveWindow − 13K → fork agent 生成 summary → splice 替换<br>
            • reactiveCompact：API 返回 413（prompt too long）→ 用户不知情下自动重试并压缩
          </div>
          <div style="font-size:18px;text-align:left;margin-top:4px;">
            <strong>🔁 如何复原：</strong><br>
            对话原文不可恢复（splice 已删除）。<br>
            但 <strong>L7「压缩后规则再激活」</strong> 在 boundary 后立即：重新 prepend Rules、重新计算附件/nudge、重新触发 hook、保持 permission mode 和 todo 状态——规则永远在场，只丢了历史细节。
          </div>
          <p style="font-size:18px;margin-top:4px;">autoCompact · reactiveCompact</p>
        </div>
      </div>
    </div>
`;

c = c.substring(0, start) + newSection + c.substring(end);
fs.writeFileSync(path, c, 'utf-8');
console.log('DONE. New size:', c.length);
