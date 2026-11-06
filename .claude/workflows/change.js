export const meta = {
  name: 'change',
  description: 'Clotho change: a role agent builds it in a worktree, then the merge gate checks it, with fix rounds until it passes',
  whenToUse: 'One task for one role. args: {role: "clothod"|"mac"|"ios", task: "<what to do and what done looks like>", maxRounds?: 3}',
  phases: [
    { title: 'Build', detail: 'the role agent investigates, plans, implements and validates with its own subagents' },
    { title: 'Gate', detail: 'code review, full tests, UI/UX review' },
    { title: 'Fix', detail: 'the role agent fixes the blocking findings' },
  ],
}

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
    done: { type: 'boolean', description: 'true only if the work is committed and your validator passed' },
  },
  required: ['branch', 'dir', 'commits', 'summary', 'tests', 'ui_changed', 'api_changes', 'needs', 'done'],
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

phase('Build')
let report = await agent(
  `Task from the main session:\n${task}\n\n` +
  `You are in a fresh git worktree. If HEAD is detached, create a branch named ${role}/<short-slug> first. ` +
  `Do the work the way your role file says: investigate, plan, implement and validate with your subagents, ` +
  `commit on your branch, and don't merge or push. Fill in every field of the report.`,
  { agentType: role, isolation: 'worktree', phase: 'Build', label: `build:${role}`, schema: REPORT })
if (!report) throw new Error(`the ${role} agent did not return a report`)
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
  const findings = gate.blocking
  const fixed = await agent(
    `Your branch ${report.branch} at ${report.dir} did not pass the merge gate (round ${round}). cd there and fix ` +
    `these blocking findings, with your subagents where useful, then validate and commit on the same branch:\n` +
    JSON.stringify(findings, null, 2) +
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
  report,
  gate,
}
