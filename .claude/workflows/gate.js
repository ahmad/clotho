export const meta = {
  name: 'gate',
  description: 'Clotho merge gate: code review, full tests and (Mac/iOS) UI/UX review of one branch',
  whenToUse: 'Before merging a role branch into main. args: {role: "clothod"|"mac"|"ios", dir: "<worktree path>", report?: "<role agent report>", ui?: true|false}',
  phases: [
    { title: 'Review', detail: 'code-reviewer, independent of the author' },
    { title: 'Test', detail: 'validator runs the role full suite on the build Mac' },
    { title: 'UX', detail: 'ux-reviewer checks the changed screens (Mac and iOS only)' },
  ],
}

const VERDICT = {
  type: 'object',
  properties: {
    verdict: { type: 'string', enum: ['PASS', 'BLOCK'] },
    summary: { type: 'string' },
    findings: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          blocking: { type: 'boolean' },
          where: { type: 'string', description: 'path:line, screen, or test name' },
          problem: { type: 'string' },
          fix: { type: 'string' },
        },
        required: ['blocking', 'where', 'problem'],
      },
    },
    screenshots: { type: 'array', items: { type: 'string' } },
    not_checked: { type: 'array', items: { type: 'string' } },
  },
  required: ['verdict', 'summary', 'findings', 'not_checked'],
}

// Accepts an object, a JSON string, or plain text "<role> <rest>" (from the slash command).
function parseArgs(x, restKey) {
  if (x && typeof x === 'object') return x
  const s = String(x || '').trim()
  if (s.startsWith('{')) return JSON.parse(s)
  const m = s.match(/^(clothod|mac|ios)\b[\s:,-]*([\s\S]*)$/)
  return m ? { role: m[1], [restKey]: m[2].trim() } : {}
}
const a = parseArgs(args, 'dir')
const role = a.role
const dir = a.dir
if (!['clothod', 'mac', 'ios'].includes(role) || !dir) {
  throw new Error('gate needs args {role: clothod|mac|ios, dir: <worktree path>}')
}
const report = a.report ? `\n\nThe role agent's report:\n${typeof a.report === 'string' ? a.report : JSON.stringify(a.report, null, 2)}` : ''
const where = `Role: ${role}. The branch is checked out at ${dir}; cd there first and compare against main (git diff main...HEAD).`
const wantUx = role !== 'clothod' && a.ui !== false

// Code review reads; the validator and the UX review both use the role's mirror on the build Mac, so they run in turn.
const [code, macRuns] = await parallel([
  () => agent(`Review this branch before it merges.\n${where}${report}`,
    { agentType: 'code-reviewer', phase: 'Review', label: `review:${role}`, schema: VERDICT }),
  async () => {
    const tests = await agent(`Run the full ${role} suite on this branch.\n${where}`,
      { agentType: 'validator', phase: 'Test', label: `test:${role}`, schema: VERDICT })
    if (!wantUx) return { tests, ux: null }
    const ux = await agent(`Check the UI and UX this branch changes.\n${where}${report}`,
      { agentType: 'ux-reviewer', phase: 'UX', label: `ux:${role}`, schema: VERDICT })
    return { tests, ux }
  },
])

const tests = macRuns ? macRuns.tests : null
const ux = macRuns ? macRuns.ux : null
const ran = { code, tests, ...(wantUx ? { ux } : {}) }
// A review that didn't come back counts as a block: the gate never passes on a missing check.
const missing = Object.entries(ran).filter(([, v]) => !v).map(([k]) => k)
const blocked = Object.entries(ran).filter(([, v]) => v && v.verdict === 'BLOCK').map(([k]) => k)
if (!wantUx) log(role === 'clothod' ? 'No UI/UX review: clothod has no UI.' : 'UI/UX review skipped: ui=false.')
const mergeable = missing.length === 0 && blocked.length === 0
log(mergeable ? `${role}: gate PASSED` : `${role}: gate BLOCKED (${[...blocked, ...missing.map(m => m + ' missing')].join(', ')})`)

return {
  mergeable,
  role,
  dir,
  blocked,
  missing,
  blocking: Object.entries(ran).flatMap(([k, v]) => (v ? v.findings : []).filter(f => f.blocking).map(f => ({ check: k, ...f }))),
  reviews: ran,
}
