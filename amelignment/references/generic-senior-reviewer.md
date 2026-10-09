# Generic senior-reviewer baseline: prior art survey

Research for the `amelignment` skill: a "first sweep" of a teammate's in-progress work
from the viewpoint of a specific senior engineer. This file is the **generic baseline**
(what senior/staff review looks like in public AI prompts and canonical human guides) plus
the prior art on **cloning a specific reviewer** from their past comments.

Collected 2026-10-09. Every claim below comes from a source listed under Sources, all of
which were fetched. Quotes are verbatim where marked.

---

## Part 1: Examples (12)

### AI skills / agents

#### 1. gstack `plan-eng-review` (Garry Tan)
- **URL:** https://github.com/garrytan/gstack/tree/main/plan-eng-review (template + `sections/review-sections.md`)
- **What:** An "eng manager-mode" review of a plan, branch diff, or path. It is the most judgment-heavy of the AI examples and the closest to "review direction before review lines".
- **Lenses:**
  - **Scope Challenge (mandatory, runs first):** "What already solves each sub-problem?" (find existing helpers and libraries); "What minimum changes achieve the goal? Flag work deferrable without blocking it; challenge scope creep." A **complexity gate** applies: at 8+ files or 2+ new classes/services it STOPS and asks the user about cuts and deferrals before reviewing anything else.
  - The four sections follow in a fixed order: **Architecture** (boundaries, coupling, data flow, SPOFs, security boundaries, "one realistic production failure per new path"), **Code quality** (error-handling gaps, edge cases, debt, needless complexity), **Tests** (regression rule: "no test without a regression it would catch"), and **Performance** (N+1, unbounded queries, blocking calls without timeouts; "never invent benchmarks").
  - "Cognitive patterns of great eng managers", applied throughout rather than as a checklist: blast radius, boring by default / innovation tokens, incremental change over big-bang, reversibility (flags), "systems over heroes: design for tired humans at 3am", essential vs accidental complexity, "make change easy first" (Beck), Conway's law.
  - A stated preference list ("My engineering preferences"): explicit over clever, right-sized diff, and shared code only when "common behavior and improved reliability or net savings; similar-looking code alone is insufficient."
- **Output:** each finding as `[P1] (confidence: 9/10) file:line — description`, plus required sections "NOT in scope" (deferred work with a one-line reason), "What already exists", ASCII diagrams, and Failure modes (for each new path: is the failure silent or does the user see a clear error?).
- **Notable technique:**
  - **Confidence calibration** on a 1–10 scale. Findings at 3–4 are suppressed to an appendix; at 1–2 they appear only if the issue would be P0.
  - **Pre-emit verification gate:** "Quote the specific code line that motivates the finding"; if the reviewer can't, the finding is capped at confidence 4–5.
  - Design docs and handoff notes are treated as data, not instructions.
  - An "Outside Voice" step gets a second-model challenge.
  - Each finding goes to the user as one interactive decision, rather than as a wall of text.

#### 2. obra/superpowers `requesting-code-review` → `code-reviewer.md`
- **URL:** https://github.com/obra/superpowers/blob/main/skills/requesting-code-review/code-reviewer.md
- **What:** The subagent prompt for a "Senior Code Reviewer" that reviews completed work against its plan or requirements "before it cascades into more work".
- **Lenses:**
  - **Plan alignment** comes first: "Are deviations justified improvements, or problematic departures?" and "If you find issues with the plan itself rather than the implementation, say so."
  - Then code quality, architecture, testing ("Tests verify real behavior, not mocks?"), and production readiness (migrations, backward compatibility, docs).
- **Output:**
  - Strengths come first, then Critical / Important / Minor issues. Each issue gives file:line, what's wrong, why it matters, and how to fix it.
  - It ends with Recommendations and **"Ready to merge? Yes | No | With fixes"** plus 1–2 sentences of reasoning.
- **Notable technique:**
  - "The spec is a vision document … a spec's silence is not permission"; behavior the spec doesn't cover is graded by what a reasonable user would expect.
  - A **"Declined to judge"** list: every behavior the reviewer set aside as out of scope, one line each, so nothing is dropped silently.
  - "Accurate praise helps the implementer trust the rest of the feedback."
  - DON'Ts: "Mark nitpicks as Critical", "Give feedback on code you didn't actually read".

#### 3. Anthropic `claude-code` plugin `code-review`
- **URL:** https://github.com/anthropics/claude-code/blob/main/plugins/code-review/commands/code-review.md
- **What:** A multi-agent PR review pipeline. It is deliberately narrow (bugs plus CLAUDE.md compliance), and it is the best example of **precision engineering for reviews**.
- **Lenses:**
  - A triage gate first: skip closed, draft, trivial, or already-reviewed PRs.
  - Two agents check CLAUDE.md compliance, scoped to the CLAUDE.md files on the changed file's path.
  - Two agents look for bugs. One reads the diff only; the other looks for security and logic issues in the introduced code.
- **Output:**
  - A terminal summary, or inline PR comments with committable suggestions, but only when the suggestion fully fixes the issue.
  - Every finding must cite and link to the exact rule or line.
- **Notable technique:**
  - Each candidate issue gets **a separate validator subagent**, and unvalidated issues are dropped.
  - "We only want HIGH SIGNAL issues … If you are not certain an issue is real, do not flag it. False positives erode trust."
  - An explicit **false-positive list**: pre-existing issues; "pedantic nitpicks that a senior engineer would not flag"; things a linter catches; and rules that are silenced in code.
  - The author's PR title and description go to every agent "to help provide context regarding the author's intent".

#### 4. c-kick/hnl-agent-skills `staff-review`
- **URL:** https://github.com/c-kick/hnl-agent-skills/blob/main/staff-review/SKILL.md
- **What:** A "Senior Staff Engineer code review … when you want ruthless technical feedback". It is read-only (Read/Grep/Glob).
- **Lenses:**
  - SOLID, DRY/KISS/YAGNI, cohesion and coupling, Law of Demeter, fail fast.
  - Security through OWASP SAMM (trust boundaries, authn/z, secrets, dependency hygiene).
  - Testability: seams for mocking, failure modes.
- **Output:**
  1. **Verdict**: `approve` / `approve-with-changes` / `block`.
  2. **Top Risks** (max 5).
  3. Architecture critique.
  4. Security.
  5. Testability.
  6. Actionable changes.
  - "If you block, list the minimum changes needed to unblock."
- **Notable technique:** Critique rules: "Prefer saying 'no' to hand-wavy designs"; "Call out hidden complexity (state management, migrations)"; "Detect accidental coupling and leaky abstractions"; "Explain the 'why' behind every critical note". The weakness is that it is principle-catalog heavy and light on judging the problem itself.

#### 5. addyosmani/agent-skills `code-reviewer` agent
- **URL:** https://github.com/addyosmani/agent-skills/blob/main/agents/code-reviewer.md
- **What:** "You are an experienced Staff Engineer conducting a thorough code review."
- **Lenses:** Five dimensions:
  - **Correctness:** spec match, edges, and "do the tests actually verify the behavior?"
  - **Readability**
  - **Architecture:** "follow existing patterns or introduce a new one? If new, is it justified?"; dependency direction; abstraction level.
  - **Security**
  - **Performance**
- **Output:** Verdict (APPROVE | REQUEST CHANGES) plus a 1–2 sentence overview, then Critical / Required / Optional / Nit, "What's Done Well" (at least one item), and a **Verification Story** (tests reviewed? build verified? security checked?).
- **Notable technique:**
  - "Review the tests first — they reveal intent and coverage."
  - "Read the spec … before reviewing code."
  - "If you're uncertain … say so and suggest investigation rather than guessing."
  - Personas don't call other personas; orchestration lives in commands.

#### 6. andreaswasita/copilot-agents-dojo `code-review`
- **URL:** https://github.com/andreaswasita/copilot-agents-dojo/blob/main/skills/code-review/SKILL.md
- **What:** "Reviews diffs and PRs the way a senior engineer would: **intent first, structure second, line-by-line third**."
- **Lenses:**
  - **Intent:** "If intent is unclear, stop and ask the author."
  - **Structural pass:** does the file list match the stated scope? Are new dependencies justified? Does it fit existing patterns? Is the deletion ratio healthy?
  - **Line pass:** correctness, security, performance, readability, tests, error handling.
- **Output:** 🔴 must / 🟡 should / 🟢 nit / ✅ what's good. If any 🔴 exists, the PR is explicitly marked not ready.
- **Notable technique:** "Does NOT rewrite the author's code — it directs, it does not replace." Pitfalls: "DO NOT miss the forest for the trees. Catching a typo while missing a SQL injection is a bad trade"; "DO NOT block a PR over formatting if a linter exists".

#### 7. RKHashmani/claude-personal-tools `review-plan`
- **URL:** https://github.com/RKHashmani/claude-personal-tools/blob/main/skills/review-plan/SKILL.md
- **What:** A senior engineer reviewing a **plan before implementation**. It suits in-progress work where the direction matters more than the code.
- **Lenses:**
  - **Phase 1 first verifies the plan's assumptions against the real codebase.** "Plans often contain assumptions about the codebase that are wrong."
  - Then correctness, completeness (rollback, migration, "building something that already partially exists?"), ordering and dependencies, edge cases, feasibility, **scope & focus** ("does it try to do too much at once?", "would you know when it's 'done'?"), consistency with conventions, testability and acceptance criteria, and risks.
- **Output:**
  - Verdict: **Ready / Ready with caveats / Needs revision / Needs rethink**.
  - Then Critical issues, Warnings, Suggestions, and Questions.
- **Notable technique:**
  - **Questions are a first-class output phase.** "ask … rather than assuming".
  - Each question is formatted as *What's unclear / Why it matters / Question*, and all questions are batched into one round.

#### 8. lokeshrana9999/shipyard `pr-review` (with `mine` mode)
- **URL:** https://github.com/lokeshrana9999/shipyard/blob/main/plugins/shipyard-delivery/skills/pr-review/SKILL.md (+ `references/mining.md`, `references/catalog.md`)
- **What:** Reviews against a **concern catalog**: a starter set plus concerns **mined from the project's own past review threads**. Bridges generic and personalized review.
- **Lenses:** The catalog entries themselves. Each entry has `look-for` (a diff signal), `applies-to` (globs), `triggers` (literal tokens), and **`gate` (when NOT to flag)**. Domains are correctness, security, architecture, testing, naming, style, and process.
- **Output:**
  - Bugs, then Issues, then Nits; each section says "none" when it is empty and is never omitted.
  - Each finding quotes its added line. Design-level findings are marked "possibly intentional".
  - An advisory ship verdict.
  - A **coverage line** of what actually ran; unreviewed concerns are listed, never hidden.
- **Notable technique:**
  - A separate skeptic agent validates each finding.
  - Mining details are in Part 3.

### Canonical human sources the skills draw on

#### 9. Google eng-practices: "What to look for" + "The Standard of Code Review"
- **URLs:** https://google.github.io/eng-practices/review/reviewer/looking-for.html and https://google.github.io/eng-practices/review/reviewer/standard.html
- **Lenses (in Google's order):**
  - **Design** first: does the change belong here or in a library, and "is now a good time to add" it?
  - **Functionality**, including what is "good for users, both end-users and future developers".
  - **Complexity**: "can't be understood quickly by code readers"; be alert to **over-engineering**, and solve "the problem they have now, not one they speculate about".
  - **Tests**: "would fail if the code broke"; test code is maintained code.
  - Then naming; comments ("why, not what"); style; consistency; documentation.
  - **Every line**: if you only reviewed part of the change, say which part.
  - **Context**: look beyond the diff; "Don't accept CLs that degrade the code health of the system."
  - Good things: praise.
- **Standard:**
  - Approve once it "definitely improves the overall code health of the system", even if it is not perfect. There is "no perfect code", only continuous improvement.
  - The **"Nit:" prefix** marks optional points, and educational comments are marked non-mandatory.
  - **Technical facts and data beat opinions.** If the author shows several approaches are equally valid, accept the author's choice.
  - Escalate rather than stall.

#### 10. Conventional Comments
- **URL:** https://conventionalcomments.org/
- **Format:** `<label> [decorations]: <subject>` + optional discussion.
- **Labels:**
  - **praise**: at least one per review, and sincere.
  - **nitpick**
  - **suggestion**: say what and why.
  - **issue**: pair it with a suggestion.
  - **todo**
  - **question**: a possible concern that may not be relevant.
  - **thought**: non-blocking, can seed mentoring.
  - **chore**
  - **note**
- **Decorations:** `(blocking)`, `(non-blocking)`, `(if-minor)`.
- **Rationale:** labels make intent and blocking status explicit and shift the tone; the format is machine-parseable.

#### 11. Sarah Vessels (GitHub Staff Engineer): "How to review code effectively"
- **URL:** https://github.blog/developer-skills/github/how-to-review-code-effectively-a-github-staff-engineers-philosophy/
- **Heuristics:**
  - **Requests to the author:**
    - Mark which comments are preference and which block approval.
    - Be specific: point to code, cite evidence, show an example from the same repo.
    - Say when a suggestion can wait.
  - **Questions over directives:**
    - Ask about assumptions: data shape, performance, resource use.
    - "Treat the author as the one with the most context, and trust their answers."
  - **Approving and blocking:**
    - Approve when the PR won't break production or harm users, even with optional suggestions open.
    - Weigh whether a suggestion is worth the delay of another review and deploy cycle.
    - Rarely "Request changes" (mainly for immediate security issues).
  - **Scope:** keep PRs small and behind feature flags; split big PRs.

#### 12. Gergely Orosz: "Good code reviews, better code reviews" (+ Michael Lynch, "How to do code reviews like a human")
- **URLs:** https://blog.pragmaticengineer.com/good-code-reviews-better-code-reviews/ and https://mtlynch.io/human-code-reviews-1/
- **Orosz on "good" vs "better":** the better reviewer:
  - asks **whether the change is necessary**, how it affects other parts of the system, and how new abstractions fit the architecture (a "contextual pass following an initial, light pass");
  - treats frequent nits as a sign that tooling is missing;
  - **reaches out to talk proactively after a first pass with many comments**, since heavy commenting usually signals a misunderstanding;
  - is "firm on the principle but flexible on the practice", allowing follow-ups in a separate PR.
- **Lynch's techniques:**
  - Let computers do the boring parts.
  - **Start high level and work your way down.** Low-level notes may become moot, and this avoids overwhelming the author.
  - Limit code examples to 2–3 per round.
  - Never say "you".
  - Frame feedback as requests.
  - Tie notes to principles, not opinions. For subjective calls, say "I found this hard to understand."
- **Supplementary:** https://gazar.dev/clean-code/code-review makes the senior/junior split explicit:
  - Juniors check correctness; seniors weigh intent and long-term consequences ("sets a pattern others will copy").
  - **Design smells as signals:** many defensive null checks mean low confidence in the data model, and a PR touching many unrelated files means a design problem.
  - File a ticket for unrelated observations instead of blocking.

### Also read (useful fragments, not full entries)
- **sagotsky/.dotfiles `pr-triage`** (https://github.com/sagotsky/.dotfiles/blob/main/home/.claude/skills/pr-triage/SKILL.md):
  - "I'm a busy staff engineer … A vast majority of PRs don't need my attention … Flag any PRs that do."
  - Also warns: "LLMs favor 3 item lists, but this is a situation to avoid that structure."
  - Relevant to the first-sweep framing: the senior's scarce attention is the resource being rationed.
- **larced/agent-playbook `review-policy-author`** (https://github.com/larced/agent-playbook/blob/main/.claude/skills/review-policy-author/SKILL.md):
  - Interviews the user on "what would make you block a PR", "what's never worth a comment", and "which areas are high-risk".
  - "**The skip list matters as much as the passes.** Review that comments on everything trains authors to ignore it."
  - "**Severity by example.**"
  - "Findings with less than high confidence are labelled as questions, not bugs."
- **wshobson/agents `architect-review`** (https://github.com/wshobson/agents/blob/main/plugins/comprehensive-review/agents/architect-review.md) and **`multi-reviewer-patterns`** (https://github.com/wshobson/agents/blob/main/plugins/agent-teams/skills/multi-reviewer-patterns/SKILL.md):
  - The architect agent is mostly a capability catalog: a long list of technologies with little judgment procedure. Treat it as an anti-pattern for this skill.
  - The multi-reviewer skill offers useful severity calibration as an impact × likelihood table, plus dedup rules.
- **mgmuscari/tgirl AGENTS.md** (https://github.com/mgmuscari/tgirl/blob/main/AGENTS.md):
  - "'Staff Engineer Reviewer' produces output that looks like a code review checklist. 'Interlocutor' produces output that reads like someone who's been listening carefully and found the three things you didn't realize you were assuming."
  - This is a useful warning: role labels prime checklist-shaped output.

---

## Part 2: Persona emulation examples (for the personalization phase)

#### P1. Mte90/linus-torvalds-skill: distilling one reviewer from 38k review moves
- **URL:** https://github.com/Mte90/linus-torvalds-skill (README, `docs/pipeline.md`, `docs/validation.md`, `linus-torvalds-skill/SKILL.md`)
- **Pipeline:**
  1. **Classify** emails as review or non-review, with rules and no LLM.
  2. **Extract** structured "review moves", **one email per LLM call**. Batching lost 18–46% of moves.
  3. **Cluster** by stratified sampling across category × severity × year (350 samples).
  4. **Calibrate** with rule-based stats such as P(severity | category). Examples: security 59% reject; style 36% nitpick and only 13% reject.
  5. **Distill** into SKILL.md.
- **Move schema:** `{category, severity, trigger, principle, quote}`.
- **Skill shape:**
  - "Reviewer Mindset" items, each with a verbatim quote and a "why it matters".
  - Leveled **triggers**, each with what to look for, why it's a problem, severity, and an example quote.
  - A precedence chain: Correctness > Performance > Complexity > Style.
  - A separate "soul" file for voice and persona.
- **Validation:**
  - Each model ran with the skill and as a baseline on a held-out codebase (plus 45 held-out diffs with ground-truth bugs).
  - One model **lost** critical findings with the skill ("narrowed focus too aggressively"): persona can suppress general competence.
  - Four generator models produced four noticeably different distillations, with "severity calibration drift". The distilling model shapes the persona.

#### P2. TomerCohen95/uvbot `build-team-personas` + `team-review`
- **URLs:** https://github.com/TomerCohen95/uvbot/blob/main/PLAN.md and https://github.com/TomerCohen95/uvbot/blob/main/templates/build-team-personas/SKILL.md
- **Gathering:**
  - Scrapes each member's Azure DevOps PR comments **with ±10 lines of code context** at the PR's source commit.
  - Always asks the user to add more repos, because "Personas built from a single repo will be narrow."
- **Analysis steps:** quantify (comments / PRs / repos); recurring themes; **3–7 core principles, each with quoted examples and the "why"**; communication style (questions vs directives vs suggestions, terse vs detailed, explains rationale?); anti-patterns they always reject; things they praise; domain expertise; inferred mental review process ("what do they look at first?").
- **Persona file sections:** Role Definition, Review Philosophy (top 3 non-negotiables), Core Principles, Communication Style Guide, Anti-Patterns, Things You Praise, Domain Knowledge, How to Review. The header records the evidence base ("Synthesized from N comments across M PRs in K repos").
- **Guardrail:** "Do NOT assume or infer job titles, seniority levels … only describe their review focus areas and demonstrated expertise."

#### P3. shipyard `mine` mode: team concerns from review threads
- **URL:** https://github.com/lokeshrana9999/shipyard/blob/main/plugins/shipyard-delivery/skills/pr-review/references/mining.md
- **Gather and clean:**
  - Use recent PRs first, about 100–300 of them ("recent history reflects current conventions"), and keep thread **resolution status**: "a comment whose thread was fixed is stronger evidence than one marked won't-fix".
  - Drop bot and CI-enforced items.
- **Extract and merge:**
  - **Generalize away from the specific code**: the concern should apply to the next change, not describe the old one.
  - Keep concerns seen in **≥2 threads**, or single-thread concerns only if they guard against a bug or security risk.
- **Validate:**
  - Check the catalog against real misses: "frequency says what reviewers commented on; misses say what the catalog must catch."
  - Get user approval before saving.
- **Refresh:**
  - Retire concerns that keep being dismissed even if they are technically correct: "reviewers stop reading automated reviews that keep raising them."

#### P4. yuzu-tsuki/claude-skills `principle-checklist` → `harvest.md`
- **URL:** https://github.com/yuzu-tsuki/claude-skills/blob/main/principle-checklist/harvest.md
- **Gathering:**
  - `gh api` for PR reviews, comments, and issue comments.
  - Separate the reviewer's comments from the author's replies, and keep the replies only for context.
- **Analysis:**
  - Keyword tallies serve only as a **pointer** ("keyword hits include praise").
  - **Read the 3–4 most recent PRs in full** to see which patterns are still active.
  - A category needs ≥3 PRs.
  - "Classify the author's mistake, not the reviewer's topic."
  - Mark each category active / fixed / unknown. **Absence where the surface was untouched means unknown, not fixed.**
- **Validation and privacy:**
  - Each principle must have caught one of its own past examples ("A check that would not have caught its own examples is advice, not a check").
  - Keep raw comments out of the repo and publish only generalized principles.

---

## Part 3: Synthesis

### 3.1 Recurring review lenses (ranked by how many of the 12 main sources include them)

| Rank | Lens | ~Sources | One-line description |
|---|---|---|---|
| 1 | **Correctness / edge cases / error paths** | 11 | Does it do what it claims; null/empty/boundary, concurrency, swallowed errors, failure paths. |
| 2 | **Tests that would actually catch a regression** | 10 | Not "are there tests" but "would they fail if the code broke"; review tests to learn intent. |
| 3 | **Design / architecture fit** | 10 | Belongs here? Follows existing patterns or justifies a new one; boundaries, coupling, dependency direction. |
| 4 | **Intent and plan alignment** | 9 | Read the description/spec/plan first; does the change match it; are deviations deliberate; is the *plan* wrong? |
| 5 | **Complexity / over-engineering / YAGNI** | 9 | Simplest thing that solves today's problem; hidden complexity (state, migrations); "explicit over clever". |
| 6 | **Scope and size** | 8 | Single-purpose; file list matches stated scope; too big → split; defer non-blocking work; "minimum change that achieves the goal". |
| 7 | **Security / trust boundaries** | 8 | Authn/z, input validation, secrets; the one area seniors will hard-block on. |
| 8 | **Production risk / reversibility / blast radius** | 6 | What happens when this fails in prod; silent vs loud failure; flags, rollback, migrations, backward compat. |
| 9 | **Reuse: "what already exists"** | 5 | Is this rebuilding something the codebase/library already has? Prove shared code with ≥2 real callers. |
| 10 | **Performance at realistic scale** | 6 | N+1, unbounded queries, blocking calls; give scale, don't invent benchmarks. |
| 11 | **Long-term code health / precedent** | 5 | Does it improve overall health? Does it set a pattern others will copy? |
| 12 | **Readability, naming, docs** | 7 | Usually lowest priority; delegate style to linters. |

Seniors weight these very differently from juniors. Every source that ranks the lenses puts
design and intent before line-level checks, and puts style last or delegates it to tooling.

### 3.2 Common output shapes
- **Verdict up front, in a few fixed values.** Examples: approve / approve-with-changes / block (staff-review); Ready / Ready with caveats / Needs revision / **Needs rethink** (review-plan); Ready to merge? Yes / No / With fixes (superpowers). For in-progress work, the plan-review vocabulary fits best, because "needs rethink" is the senior's most valuable early call.
- **Three or four severity tiers** with consistent meanings: blocking (bug, data loss, security, broken) / should-fix (design defect, missing test) / nit (preference, always with a reason). Conventional Comments' `(blocking)` / `(non-blocking)` / `(if-minor)` decorations and Google's `Nit:` prefix are the human versions.
- **Every finding has the same structure:** location (file:line, or plan section), what's wrong, **why it matters**, and the suggested fix or direction. Stronger variants add confidence (gstack) and a quoted motivating line (gstack, shipyard).
- **Questions are their own section.** Low-confidence items become questions rather than bugs (review-policy-author, review-plan, Vessels). Batch them into one round.
- **Praise.** "What's done well" or `praise:` appears in at least 6 sources, justified by trust ("accurate praise helps the implementer trust the rest").
- **An honesty section about coverage:** "Declined to judge" (superpowers), the "NOT in scope" list (gstack), the coverage line (shipyard), and Google's "say which parts you reviewed". This matters a lot for a *first sweep*, which by definition doesn't cover everything.
- **Cap the list.** Examples: "Top Risks (max 5)" and "2–3 code examples per round". Lynch's high-level-first ordering keeps later notes from going moot.

### 3.3 Techniques for emulating a specific reviewer
**Gather**
- Use the person's **review comments with code context** (uvbot: ±10 lines at the reviewed commit), plus thread outcome (resolved/fixed vs dismissed) and author replies (context only).
- Prefer recent history, and include multiple repos to avoid a narrow persona.
- Non-review writing (Slack, design-doc comments, interviews) helps with *mindset*. Torvalds-skill merged interview excerpts in for its "mindset" section.

**Encode as structured "moves," not prose impressions**
- Use one record per comment, such as `{category, severity, trigger, principle, quote}` (Torvalds) or `{look-for, applies-to, triggers, gate, default severity}` (shipyard).
- Extract one item per LLM call; batching silently drops data.
- Compute **severity calibration from the data**: how often this person *blocks* on each category versus leaves a nit. This is the most person-specific signal and the one generic reviewers get most wrong.
- Write **3–7 principles**, each with verbatim quotes and the *why* (uvbot). Add a **precedence chain** (what beats what) and a **"what they praise"** list.
- Keep a **"how they review" process**: what they look at first.
- Add a **gate / skip list**: what this person consistently does *not* comment on. This is as defining as what they do comment on.

**Validate**
- Hold out real past PRs and check whether the persona raises the issues the person actually raised. Also check the reverse: would it have caught real misses?
- Compare against a no-persona baseline. The persona can **suppress** criticals the generic model would catch (Torvalds/glm).
- Mark principles active / fixed / unknown by recency, and retire concerns the team keeps dismissing.

**Pitfalls**
- **Caricature / over-indexing on tone.** Torvalds-skill splits "skill" (triggers, severity) from "soul" (voice). The memorable, colorful quotes are over-represented relative to the person's actual day-to-day behavior. Base severity on calibration stats, not on vivid examples.
- **Inventing seniority or authority.** uvbot explicitly forbids inferring titles or seniority.
- **Overfitting to old code.** Generalize each concern so it applies to the next change.
- **Topic vs mistake.** Classify the author's mistake, not the reviewer's topic.
- **Keyword counts mislead.** They include praise and "verified OK" text. Read the actual comments.
- **Model drift.** Different distilling models yield different personas and severity calibrations. Pin the model, or review the output by hand.
- **Privacy.** Keep raw comments out of the repo and publish generalized principles only.
- **Role labels prime checklists.** "Staff Engineer Reviewer" yields checklist-shaped output. A stance that describes how the person *attends* (e.g. "finds the three things you didn't realize you were assuming") may work better.

### 3.4 What distinguishes senior from junior review (across sources)
1. **Questions the premise before the implementation.** Seniors ask: is this the right thing to build, does it belong here, is now the time, and does it already exist? (Google: Design first. Orosz: "is the change necessary". gstack: Scope Challenge. gazar: "a flawless implementation of the wrong feature adds little value".)
2. **Goes top-down.** Intent, then structure, then lines (copilot-agents-dojo, Lynch). The senior stops early when the direction is wrong instead of leaving 40 line comments.
3. **Rations blocking.** Approve when the change improves code health and won't hurt users. Reserve hard blocks for security, data loss, or irreversible harm. Weigh each suggestion against the cost of another cycle (Google standard, Vessels).
4. **Thinks in consequences over time.** Blast radius, reversibility, migration and rollback, precedent ("sets a pattern others will copy"), and the 3am operator.
5. **Reads design smells as symptoms.** Defensive null checks point to the data model, and scattered unrelated files point to a missing abstraction. Seniors comment on the cause, not each symptom.
6. **Separates preference from principle, and says which is which.** Use the `Nit:` prefix, defer to the author when approaches are equally valid, and tie feedback to principles or data.
7. **Optimizes signal over coverage.** Skip linter territory, cap the list, and fix recurring nits at the root (tooling). Too much commentary trains authors to ignore review.
8. **Asks rather than asserts when uncertain, and trusts the author's context.** Escalates to a conversation when the comment count balloons.
9. **Directs rather than rewrites.** Suggests direction and gives only a few examples, which leaves the author ownership.
10. **Is honest about what wasn't reviewed.** Says which parts were reviewed, what was declined, and what is out of scope.

### 3.5 Implications for a "first sweep" skill (baseline design notes)
- Start by reconstructing intent: the ticket, the plan, and the branch description. If intent is unknown, the first output is a question.
- Put direction-level calls first: is this the right problem, approach, and scope, and does it already exist? Use a verdict like *on track / on track with caveats / worth a conversation / rethink*.
- Cap findings at roughly 5 "things I'd raise", ordered by consequence. Each has location, why it matters, confidence, and whether it would block. Low-confidence items become questions.
- Include an explicit "not looked at / out of scope for a first sweep" line.
- Leave a skip list and a severity-calibration slot that the personalization phase fills from the target engineer's mined comments, using the moves schema plus a gate. Keep voice separate from judgment.

---

## Sources (all fetched)

AI skills / agents:
- https://github.com/garrytan/gstack/blob/main/plan-eng-review/SKILL.md.tmpl
- https://github.com/garrytan/gstack/blob/main/plan-eng-review/sections/review-sections.md
- https://github.com/obra/superpowers/blob/main/skills/requesting-code-review/code-reviewer.md
- https://github.com/anthropics/claude-code/blob/main/plugins/code-review/commands/code-review.md
- https://github.com/c-kick/hnl-agent-skills/blob/main/staff-review/SKILL.md
- https://github.com/addyosmani/agent-skills/blob/main/agents/code-reviewer.md
- https://github.com/andreaswasita/copilot-agents-dojo/blob/main/skills/code-review/SKILL.md
- https://github.com/RKHashmani/claude-personal-tools/blob/main/skills/review-plan/SKILL.md
- https://github.com/lokeshrana9999/shipyard/blob/main/plugins/shipyard-delivery/skills/pr-review/SKILL.md
- https://github.com/lokeshrana9999/shipyard/blob/main/plugins/shipyard-delivery/skills/pr-review/references/mining.md
- https://github.com/lokeshrana9999/shipyard/blob/main/plugins/shipyard-delivery/skills/pr-review/references/catalog.md
- https://github.com/sagotsky/.dotfiles/blob/main/home/.claude/skills/pr-triage/SKILL.md
- https://github.com/larced/agent-playbook/blob/main/.claude/skills/review-policy-author/SKILL.md
- https://github.com/wshobson/agents/blob/main/plugins/comprehensive-review/agents/architect-review.md
- https://github.com/wshobson/agents/blob/main/plugins/agent-teams/skills/multi-reviewer-patterns/SKILL.md
- https://github.com/mgmuscari/tgirl/blob/main/AGENTS.md

Persona emulation:
- https://github.com/Mte90/linus-torvalds-skill (README.md)
- https://github.com/Mte90/linus-torvalds-skill/blob/main/docs/pipeline.md
- https://github.com/Mte90/linus-torvalds-skill/blob/main/docs/validation.md
- https://github.com/Mte90/linus-torvalds-skill/blob/main/linus-torvalds-skill/SKILL.md
- https://github.com/TomerCohen95/uvbot/blob/main/PLAN.md
- https://github.com/TomerCohen95/uvbot/blob/main/templates/build-team-personas/SKILL.md
- https://github.com/yuzu-tsuki/claude-skills/blob/main/principle-checklist/SKILL.md
- https://github.com/yuzu-tsuki/claude-skills/blob/main/principle-checklist/harvest.md

Canonical / human sources:
- https://google.github.io/eng-practices/review/reviewer/looking-for.html
- https://google.github.io/eng-practices/review/reviewer/standard.html
- https://conventionalcomments.org/
- https://github.blog/developer-skills/github/how-to-review-code-effectively-a-github-staff-engineers-philosophy/
- https://blog.pragmaticengineer.com/good-code-reviews-better-code-reviews/
- https://mtlynch.io/human-code-reviews-1/
- https://gazar.dev/clean-code/code-review

Not obtained:
- Medium posts on senior review returned 403.
- No fetchable primary source turned up for Tanya Reilly's *Staff Engineer's Path* review heuristics or the "what would I need to believe to approve this" framing, so neither is cited here.
