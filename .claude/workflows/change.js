export const meta = {
  name: 'change',
  description: 'Clotho change: investigate, plan, implement in a worktree (parallel pieces), then the merge gate, with fix rounds until it passes',
  whenToUse: 'One task for one role. args: {role: "clothod"|"mac"|"ios", task: "<what to do and what done looks like>", maxRounds?: 3}',
  phases: [
    { title: 'Investigate', detail: 'investigator reads, reproduces and measures (read-only, main clone)' },
    { title: 'Plan', detail: 'planner splits the work into pieces with their files and tests' },
    { title: 'Implement', detail: 'role agent opens the worktree; implementers build the pieces; role agent integrates and commits' },
    { title: 'Gate', detail: 'code review, full tests, UI/UX review' },
    { title: 'Fix', detail: 'the role agent fixes the blocking findings' },
  ],
}

// Workflow agents can't start subagents of their own, so this script runs the role's
// investigate / plan / implement steps as separate agents and the role agent leads and integrates.

const REPORT = {
  type: 'object',
  properties: {
    branch: { type: 'string' },
    dir: { type: 'string', description: 'absolute path of the worktree' },
    commits: { type: 'array', items: { type: 'string' } },
    summary: { type: 'string' },
    tests: { type: 'string', description: 'what ran, with counts, and what did not' },
    ui_changed: { type: 'boolean' },
    ui_screens: { type: 'array', items: { type: 'string' } },
    api_changes: { type: 'string', description: 'protocol or ClothoKit API changes, or "none"' },
    needs: { type: 'array', items: { type: 'string' }, description: 'what other roles must do' },
    done: { type: 'boolean', description: 'true only if the work is committed and the role suite passed' },
  },
  required: ['branch', 'dir', 'commits', 'summary', 'tests', 'ui_changed', 'api_changes', 'needs', 'done'],
}

const PLAN = {
  type: 'object',
  properties: {
    approach: { type: 'string' },
    pieces: {
      type: 'array',
      description: 'Implementation pieces. Pieces whose files do not overlap can run in parallel.',
      items: {
        type: 'object',
        properties: {
          title: { type: 'string' },
          files: { type: 'array', items: { type: 'string' }, description: 'repo-relative paths this piece may change' },
          steps: { type: 'string' },
          tests: { type: 'string', description: 'tests that cover this piece' },
        },
        required: ['title', 'files', 'steps', 'tests'],
      },
    },
    ui_screens: { type: 'array', items: { type: 'string' } },
    risks: { type: 'array', items: { type: 'string' } },
    needs: { type: 'array', items: { type: 'string' } },
  },
  required: ['approach', 'pieces', 'risks', 'needs'],
}

const SETUP = {
  type: 'object',
  properties: { branch: { type: 'string' }, dir: { type: 'string', description: 'absolute path of the worktree' } },
  required: ['branch', 'dir'],
}

// Accepts an object, a JSON string, or plain text "<role> <rest>" (from the slash command).
function parseArgs(x, restKey) {
  if (x && typeof x === 'object') return x
  const s = String(x || '').trim()
  if (s.startsWith('{')) return JSON.parse(s)
  const m = s.match(/^(clothod|mac|ios)\b[\s:,-]*([\s\S]*)$/)
  return m ? { role: m[1], [restKey]: m[2].trim() } : {}
}
const a = parseArgs(args, 'task')
const role = a.role
const task = a.task
const maxRounds = a.maxRounds || 3
if (!['clothod', 'mac', 'ios'].includes(role) || !task) {
  throw new Error('change needs args {role: clothod|mac|ios, task: "..."}')
}

phase('Investigate')
const findings = await agent(
  `Role: ${role}. Work read-only in the main clone (your current directory). Investigate what this task touches ` +
  `before anyone changes code: the code and docs involved, current behaviour, and anything to reproduce or measure.\n\nTask:\n${task}`,
  { agentType: 'investigator', phase: 'Investigate', label: `investigate:${role}` })

phase('Plan')
const plan = await agent(
  `Role: ${role}. Work read-only in the main clone (your current directory). Plan this task. Split it into pieces ` +
  `whose files don't overlap where you can, so they can be built in parallel; one piece is fine for a small task. ` +
  `Only the role's own paths.\n\nTask:\n${task}\n\nInvestigation:\n${findings || '(none returned)'}`,
  { agentType: 'planner', phase: 'Plan', label: `plan:${role}`, schema: PLAN })
if (!plan || !plan.pieces || !plan.pieces.length) throw new Error(`the ${role} planner returned no pieces`)
log(`${role}: ${plan.pieces.length} piece(s): ${plan.pieces.map(p => p.title).join('; ')}`)

phase('Implement')
// An isolated worktree that ends unchanged is removed when its agent returns, so the setup agent creates a
// plain git worktree instead: it persists for the implementers and the integrate step.
const setup = await agent(
  `Create the worktree for this task, and change no files. From the main clone (cd "$(git rev-parse ` +
  `--show-toplevel)" first, and if that is itself a worktree under .claude/worktrees, use the clone that contains ` +
  `it), pick a short slug and run: git worktree add -b ${role}/<slug> .claude/worktrees/${role}-<slug> main. ` +
  `If the branch or directory exists, pick another slug. Return the branch name and the worktree's absolute ` +
  `path.\n\nTask:\n${task}`,
  { agentType: role, phase: 'Implement', label: `worktree:${role}`, schema: SETUP })
if (!setup) throw new Error(`the ${role} agent did not set up a worktree`)
const dir = setup.dir

// Pieces run in parallel only if no two of them share a file; otherwise one after another.
const pieces = plan.pieces
const fileSets = pieces.map(p => new Set(p.files))
const disjoint = fileSets.every((s, i) => fileSets.slice(i + 1).every(t => [...s].every(f => !t.has(f))))
const implement = (p, i) => agent(
  `Role: ${role}. Work in ${dir} (cd there first; it's the role's worktree). Implement piece ${i + 1} of ${pieces.length}: ` +
  `"${p.title}".\nFiles you may change: ${p.files.join(', ')}\nSteps:\n${p.steps}\nTests: ${p.tests}\n\n` +
  `Overall approach: ${plan.approach}\n` +
  (disjoint && pieces.length > 1
    ? 'Other implementers are editing other files in the same directory right now. Do not run scripts/clotho-build; run only local tests, and say what still needs the build Mac.'
    : 'You are the only one using the build Mac mirror right now; you may run scripts/clotho-build for your tests.'),
  { agentType: 'implementer', phase: 'Implement', label: `implement:${role}:${i + 1}` })
let built
if (pieces.length === 1) built = [await implement(pieces[0], 0)]
else if (disjoint) built = await parallel(pieces.map((p, i) => () => implement(p, i)))
else { built = []; for (let i = 0; i < pieces.length; i++) built.push(await implement(pieces[i], i)) }
if (pieces.length > 1 && !disjoint) log(`${role}: pieces share files, so they ran one after another`)

let report = await agent(
  `Work in ${dir} (cd there first), on branch ${setup.branch}. Implementers built this task in pieces; integrate it.\n\n` +
  `Task:\n${task}\n\nPlan:\n${JSON.stringify(plan, null, 2)}\n\nImplementer reports:\n` +
  built.map((r, i) => `--- piece ${i + 1}: ${pieces[i].title}\n${r || '(no report: check this piece yourself)'}`).join('\n') +
  `\n\nRead the whole diff, fix what's wrong or missing, and run the tests that cover the change (one ` +
  `scripts/clotho-build at a time). The merge gate's validator runs the full suite next, so don't run it here. ` +
  `Commit on ${setup.branch}. Don't merge or push. Fill in every field of the report.`,
  { agentType: role, phase: 'Implement', label: `integrate:${role}`, schema: REPORT })
if (!report) throw new Error(`the ${role} agent did not return a report`)
report = { ...report, dir, branch: setup.branch }
log(`${role}: ${report.branch} at ${report.dir}, ${report.commits.length} commit(s)`)

let gate = null
for (let round = 1; round <= maxRounds; round++) {
  phase('Gate')
  // Mac and iOS always get the UI/UX review, even when the report says no screen changed.
  gate = await workflow('gate', { role, dir: report.dir, report, ui: role !== 'clothod' })
  if (gate.mergeable) break
  if (round === maxRounds) { log(`${role}: still blocked after ${maxRounds} gate round(s)`); break }
  if (!gate.blocking.length) { log(`${role}: ${gate.missing.join(', ')} didn't return; rerunning the gate`); continue }
  phase('Fix')
  const fixed = await agent(
    `Your branch ${report.branch} at ${report.dir} did not pass the merge gate (round ${round}). cd there and fix ` +
    `these blocking findings, then run the role's full suite and commit on the same branch:\n` +
    JSON.stringify(gate.blocking, null, 2) +
    `\n\nIf you disagree with a finding, don't change the code for it: explain why in the summary.`,
    { agentType: role, phase: 'Fix', label: `fix:${role}:${round}`, schema: REPORT })
  if (!fixed) { log(`${role}: the fix round returned nothing`); break }
  report = { ...fixed, dir: report.dir, branch: report.branch }
}

return {
  mergeable: !!(gate && gate.mergeable),
  role,
  branch: report.branch,
  dir: report.dir,
  plan,
  report,
  gate,
}
