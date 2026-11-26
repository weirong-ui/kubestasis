#!/usr/bin/env python3
"""文档一致性门：同一事实在多份文档里必须只有一个数字。

起因（2026-11-05 外部评审）：README 徽章写 139 用例，同一文件"开发"节还写着
113，STATUS 正文是 139，ROADMAP 的 envtest 已完成但 DESIGN 仍标"计划中"。
都是同步滞后，不是造假——但一个主打"文档即唯一可信账本"的项目，账本自己
对不上就是硬伤。人工核对靠不住（上次就是脚本替换漏了一处），所以做成门。

检查四类：
1. 数字：所有"当前时态"的用例数必须等于徽章数字。
   历史流水账（形如 "103 → 113 用例"）豁免——记录演进是正当的。
2. 现实：仓库里已经存在的东西，文档里不能还说"计划中/未做/未实测"。
   这类断言写死映射，改代码时若文档没跟上，CI 直接红。
3. 归档：报告 §3 的表里说"未归档"就不能挂链接，说有归档就必须点得开。
4. 日期：STATUS 顶部的"最后更新"不能早于台账里最晚的一条记录。
"""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
errors: list[str] = []


def rel(p: pathlib.Path) -> str:
    return str(p.relative_to(ROOT))


# ---------- 1. 用例数一致性 ----------

BADGE = re.compile(r"tests-(\d+)%20cases")
# "139 用例" / "**139 个用例**" / "139 cases"
# 2026-11-05 外部评审指出的漏网写法："100 个单元测试用例"——数字和"用例"之间
# 隔着"个单元测试"，旧正则只允许一个"个"，直接放过。单独加一支收口。
CLAIM = re.compile(
    r"(\d+)\s*个\s*(?:单元|集成)?测试用例"      # 100 个单元测试用例
    r"|(\d+)\s*(?:个\s*)?用例"                  # 139 用例 / 139 个用例
    r"|(\d+)\s+cases"                            # 139 cases
)
ARROW_HISTORY = re.compile(
    r"\d+\s*(?:个\s*)?(?:测试)?用例\s*→\s*\d+"       # "113 用例 → 137"
    r"|\d+\s*→\s*\d+\s*(?:个\s*)?(?:测试)?用例"       # "113 → 137 用例"
)
# 带日期的台账行（"| 2026-11-03 | P1 ... 31 个单测 ... |"）陈述的是那天的状态，
# 和箭头演进同理，属于历史记录而非当前声明
DATE_ROW = re.compile(r"^\|\s*\d{4}-\d{2}-\d{2}\s*\|")


def is_history(line: str) -> bool:
    """历史演进行豁免：'103 → 113 用例'、'113 → 137 用例'、日期台账行。

    2026-11-06 外部评审：这里原来是 `or "→" in line`，任何带箭头的行整行豁免，
    像 "139 用例（真集群 1→5→1 验证）" 这种当前时态声明会被静默跳过。
    现在箭头必须紧邻用例计数，1→5 之类的普通箭头不再构成豁免。
    """
    stripped = line.strip()
    return bool(ARROW_HISTORY.search(line)) or bool(DATE_ROW.match(stripped))


def collect_counts() -> tuple[int | None, list[tuple[str, int, int, str]]]:
    badge = None
    claims: list[tuple[str, int, int, str]] = []
    for md in sorted(ROOT.rglob("*.md")):
        # juejin/ 是已对外发布的稿件快照，数字属于"发表时的事实"，不回改
        if any(part in {".git", "vendor", "node_modules", "juejin"} for part in md.parts):
            continue
        for i, line in enumerate(md.read_text(encoding="utf-8").splitlines(), 1):
            b = BADGE.search(line)
            if b:
                badge = int(b.group(1))
            for m in CLAIM.finditer(line):
                if is_history(line):
                    continue
                n = int(m.group(1) or m.group(2) or m.group(3))
                # 压测段落里会出现 "137m"、时间之类的数字，先靠上面正则收窄；
                # 小于 20 的数字基本不是用例总数（如"4 条链路"）
                if n >= 20:
                    claims.append((rel(md), i, n, line.strip()[:100]))
    return badge, claims


badge, claims = collect_counts()
if badge is None:
    errors.append("README 徽章里找不到 tests-N%20cases，无法建立基准")
else:
    for path, line_no, n, text in claims:
        if n != badge:
            errors.append(f"{path}:{line_no} 写 {n} 用例，徽章是 {badge} —— {text}")

# ---------- 2. 现实 vs 文档陈述 ----------

# (产物存在则说明已落地, 文档文件, 不该再出现的说法（正则）)
REALITY = [
    ("test/envtest", "docs/DESIGN.md", r"envtest[^\n]{0,120}(计划中|未实现|未做|⬜)"),
    ("deploy/monitoring/grafana", "docs/STATUS.md", r"Grafana 面板[^\n]{0,60}(未做|计划中|仍未)"),
    ("charts/kubestasis", "docs/ROADMAP.md", r"Helm Chart[^\n]{0,60}未"),
    # README 也写过同一类过期话（2026-11-05：Roadmap 节把已入库的 envtest/Grafana 标"未完成"），
    # "未完成/计划中"可能写在名词前面，两个方向都要查
    ("test/envtest", "README.md", r"(未完成|计划中|未做)[^\n]{0,120}envtest|envtest[^\n]{0,120}(未完成|计划中|未做)"),
    ("deploy/monitoring/grafana", "README.md", r"(未完成|计划中|未做|仍未)[^\n]{0,120}Grafana|Grafana[^\n]{0,120}(未完成|计划中|未做|仍未)"),
    # 2026-11-20 合并预演：工作分支落后 main 8 个提交时，README/STATUS 仍写
    # "AI 推理信号尚未执行/未实测"，而同日的 vLLM 实测记录已在 main 入库。
    # 这类"分支分叉导致的过期声明"和上面几条一样，产物存在就不许再说没做。
    # 正则限定在 AI 推理那两行内，避免误伤 STATUS §七「控制面高可用从未实测」
    # 和 docs/ai-collaboration.md 里「没有证据的地方标未实测」这类仍然成立的表述。
    ("docs/benchmark/vllm-inference-run-2026-11-20.md", "README.md",
     r"AI 推理信号[^\n]{0,80}(尚未执行|未实测|只有单测|尚欠实测)"),
    ("docs/benchmark/vllm-inference-run-2026-11-20.md", "docs/STATUS.md",
     r"AI 推理弹性信号[^\n]{0,40}(⚠️ 未实测|未实测|尚欠实测|没有在真实)"),
    # 2026-11-25：双副本选主与接管已在真集群跑通（docs/ha-verification.md），
    # 两处"未验证"的表述必须一起改。正则收得很窄：STATUS 新写法里仍有
    # "webhook 双副本准入未验证"这类成立的残余，宽匹配会误伤。
    ("docs/lab/ha-20261125-145018/summary.txt", "docs/STATUS.md",
     r"双副本下的选主接管[^\n]{0,30}从未实测"),
    ("docs/lab/ha-20261125-145018/summary.txt", "README.md",
     r"leaderElection 已开但双副本切换未验证"),
]

for artifact, doc, pattern in REALITY:
    if not (ROOT / artifact).exists():
        continue
    p = ROOT / doc
    if not p.exists():
        continue
    for i, line in enumerate(p.read_text(encoding="utf-8").splitlines(), 1):
        if re.search(pattern, line, flags=re.IGNORECASE):
            errors.append(
                f"{doc}:{i} 仍称未完成，但 {artifact} 已存在 —— {line.strip()[:100]}"
            )

# ---------- 3. 账本表里的"归档"必须对得上文件 ----------
# 起因（2026-11-06 外部评审）：报告 §3 开头写"每轮的废数据都归档"，同节表格
# run2 却写"未归档"，目录里也只有 3 份废 CSV；README 又把这句话抄成"五轮废
# 数据的归档"。这类事实不需要等评审来抓——表里给了链接就必须有文件，写了
# "未归档"就不能给链接，机器判得比人准。

BENCH_DOC = ROOT / "docs/benchmark/hpa-vs-kubestasis.md"
LINK = re.compile(r"\]\(([^)]+)\)")
if BENCH_DOC.exists():
    for i, line in enumerate(BENCH_DOC.read_text(encoding="utf-8").splitlines(), 1):
        s = line.strip()
        if not s.startswith("| run"):
            continue
        cells = [c.strip() for c in s.strip("|").split("|")]
        if len(cells) < 4:
            continue
        run, archive = cells[0], cells[-1]
        m = LINK.search(archive)
        if "未归档" in archive:
            if m:
                errors.append(f"{rel(BENCH_DOC)}:{i} {run} 标\"未归档\"却给了链接")
            continue
        if not m:
            errors.append(f"{rel(BENCH_DOC)}:{i} {run} 声称有归档但没给链接")
            continue
        target = BENCH_DOC.parent / m.group(1)
        if not target.exists():
            errors.append(f"{rel(BENCH_DOC)}:{i} {run} 归档链接指向不存在的文件：{m.group(1)}")

# ---------- 4. 账本顶部的"最后更新"不能早于台账 ----------
# 起因（2026-11-18 AI 对抗性自审）：STATUS 顶部写"最后更新：2026-11-04 晚"，
# 台账里却已有 11-05 傍晚的记录。日期是给人判断"这份账本新鲜度"的最快信号，
# 贴错了比没有更糟——读者会以为 11-05 之后的记录都不存在。

STATUS_DOC = ROOT / "docs/STATUS.md"
UPDATED = re.compile(r"最后更新：(\d{4}-\d{2}-\d{2})")
LEDGER_ROW = re.compile(r"^\|\s*(\d{4}-\d{2}-\d{2})")

if STATUS_DOC.exists():
    text = STATUS_DOC.read_text(encoding="utf-8")
    m = UPDATED.search(text)
    if not m:
        errors.append("docs/STATUS.md 顶部找不到「最后更新：YYYY-MM-DD」")
    else:
        header_date = m.group(1)
        ledger_dates = []
        for line in text.splitlines():
            row = LEDGER_ROW.match(line.strip())
            if row:
                ledger_dates.append(row.group(1))
        if ledger_dates and max(ledger_dates) > header_date:
            errors.append(
                f"docs/STATUS.md 顶部写「最后更新：{header_date}」，"
                f"但台账里已有 {max(ledger_dates)} 的记录"
            )

# ---------- 5. 副本-分钟结论必须带版本声明 ----------
# 起因（2026-11-26 外部评审）：报告开头写明 run5 采于 565b0fb、缩容稳定窗口落地之前，
# README 首屏却把 −12.5% 当"最稳的一个数"挂着，没说它来自旧代码。读者会把它读成
# 当前 main 的能力。REALITY 管的是"产物已存在就不许说没做"，管不了"数字还在、
# 依据已经漂了"，所以单独查：首页出现这个数就必须带哈希，且报告里得有同一处声明。

README_DOC = ROOT / "README.md"
if README_DOC.exists():
    readme_text = README_DOC.read_text(encoding="utf-8")
    has_number = re.search(r"12\.5\s*%", readme_text)
    has_version = "565b0fb" in readme_text
    if has_number and not has_version:
        errors.append("README.md 写了副本-分钟 −12.5%，却没有 run5 的版本声明（565b0fb）")
    if has_version and BENCH_DOC.exists():
        if "565b0fb" not in BENCH_DOC.read_text(encoding="utf-8"):
            errors.append("README.md 引用了 565b0fb，但压测报告的版本声明里没有这个哈希")

if errors:
    print("文档一致性检查失败：")
    for e in errors:
        print("  -", e)
    sys.exit(1)

print(f"文档一致：用例数 {badge}（{len(claims)} 处声明），现实断言 {len(REALITY)} 条，台账日期单调，归档链接可点，版本声明已核对")