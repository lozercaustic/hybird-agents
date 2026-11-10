import type { Register } from 'claude-code'

type Ev = { t: 'start'; id: string; command: string } | { t: 'msg'; text: string } | { t: 'file'; id: string; text: string }
type Job = { id: string; task: string; cwd: string; readOnly: boolean; events: Ev[]; outputs: Map<string, string>; ended: boolean; err: string; thread: string; inTok: number; outTok: number; cached: number }
type State = { job: Job; cursor: number; held: string; finalText?: string }

const queue: Job[] = []
const pending: { prompt: string; cwd: string }[] = []
const states = new Map<string, State>()
const toolMap = new Map<string, { job: Job; itemId: string }>()
const codexAgents = new Set<string>()
let seq = 0
let worker = false
let lastAgent: string | undefined

const DIRECT = /\b(hy\s+run\s+codex|hy\s+tx\s+codex|codex\s+exec)\b/
const clip = (s: string, n = 20000) => (s.length > n ? s.slice(0, n) + `\n… (+${s.length - n} chars)` : s)

async function runJob($: any, j: Job) {
  // Default: the sandbox from ~/.codex/config.toml (so `hy` can write its store, see README). "READ ONLY" in the task forces read-only.
  await modelOf($)
  // The provider gateway rate-limits (429); codex's default 4-5 retries run out, so raise them.
  const retries = codexProvider ? ['-c', `model_providers.${codexProvider}.request_max_retries=12`, '-c', `model_providers.${codexProvider}.stream_max_retries=12`] : []
  const base = ['codex', 'exec', '--json', '--skip-git-repo-check', ...retries, ...(j.readOnly ? ['-s', 'read-only'] : [])]
  try {
    for (let attempt = 1; attempt <= 5; attempt++) {
      const argv = [...base]
      if (j.thread) argv.push('resume', j.thread)
      argv.push(j.thread ? 'Continue the previous task from where it stopped (the last request was rate-limited). Do not repeat finished steps.' : j.task)
      let buf = ''
      j.err = ''
      let gotAnswer = j.events.some(x => x.t === 'msg')
      for await (const chunk of $.process.spawn({ argv, ...(j.cwd ? { cwd: j.cwd } : {}), env: { HY_AS: 'codex' } }) as any) {
        if (chunk.stream !== 'stdout') continue
        buf += chunk.text
        let i
        while ((i = buf.indexOf('\n')) >= 0) {
          const line = buf.slice(0, i).trim(); buf = buf.slice(i + 1)
          if (!line.startsWith('{')) continue
          let ev: any
          try { ev = JSON.parse(line) } catch { continue }
          const it = ev.item
          if (ev.type === 'thread.started' && !j.thread) j.thread = ev.thread_id
          else if (ev.type === 'error' || ev.type === 'turn.failed') j.err = ev.message ?? ev.error?.message ?? 'failed'
          else if (ev.type === 'turn.completed') { j.inTok += ev.usage?.input_tokens ?? 0; j.outTok += ev.usage?.output_tokens ?? 0; j.cached += ev.usage?.cached_input_tokens ?? 0 }
          else if (ev.type === 'item.started' && it?.type === 'command_execution') j.events.push({ t: 'start', id: it.id, command: it.command })
          else if (ev.type === 'item.completed' && it?.type === 'command_execution') j.outputs.set(it.id, clip(String(it.aggregated_output ?? '')) + (it.exit_code ? `\n[exit ${it.exit_code}]` : ''))
          else if (ev.type === 'item.completed' && it?.type === 'agent_message') { j.events.push({ t: 'msg', text: it.text }); gotAnswer = true }
          else if (ev.type === 'item.completed' && it?.type === 'file_change') {
            j.outputs.set(it.id, 'ok')
            j.events.push({ t: 'file', id: it.id, text: (it.changes ?? []).map((c: any) => `${c.kind} ${c.path}`).join(', ') })
          }
        }
      }
      if (gotAnswer || !/429/.test(j.err) || attempt === 5) break
      await $.clock.sleep(15000 * attempt)
    }
  } catch (x: any) { j.err = String(x?.message ?? x) }
  j.ended = true
}

let codexModel = ''
let codexProvider = ''
async function modelOf($: any) {
  if (!codexModel) {
    const r = await $.process.run(['sh', '-c', "sed -n 's/^model *= *\"\\(.*\\)\"/\\1/p' \"${CODEX_HOME:-$HOME/.codex}/config.toml\" | head -1"])
    codexModel = r.stdout.trim() || 'codex'
    const pr = await $.process.run(['sh', '-c', "sed -n 's/^model_provider *= *\"\\(.*\\)\"/\\1/p' \"${CODEX_HOME:-$HOME/.codex}/config.toml\" | head -1"])
    codexProvider = pr.stdout.trim()
  }
  return codexModel
}
const usageOf = (j: Job, model: string) => ({ model, input_tokens: j.inTok, output_tokens: j.outTok, cache_read_input_tokens: j.cached, cache_creation_input_tokens: 0 })

async function isCodex($: any, agentId: string) {
  if (codexAgents.has(agentId)) return true
  const list = await $.agent.list()
  if (list.some((a: any) => a.id === agentId && a.type === 'codex-team:codex')) { codexAgents.add(agentId); return true }
  return false
}

// A `$` call in flight does not count against a hook's budget; a sleeping child is a cheap wait.
async function tick($: any) { await $.process.run(['sleep', '0.4']) }

type Act = { kind: 'tool'; id: string; command: string; itemId: string; text: string } | { kind: 'final'; text: string } | undefined

function scan(s: State): Act {
  const j = s.job
  while (s.cursor < j.events.length) {
    const ev = j.events[s.cursor++]
    if (ev.t === 'msg') { s.held += (s.held ? '\n\n' : '') + ev.text; continue }
    const text = s.held; s.held = ''
    const itemId = ev.id
    const command = ev.t === 'start' ? ev.command : `# codex edited: ${ev.text}`
    return { kind: 'tool', id: `toolu_codex_${j.id}_${s.cursor}`, command, itemId, text }
  }
  if (s.finalText !== undefined) return { kind: 'final', text: s.finalText }
  if (j.ended) {
    const text = s.held || (j.err ? `codex failed: ${j.err}` : '(codex returned no answer)')
    s.held = ''
    s.finalText = text + (j.thread ? `\n[codex session ${j.thread}]` : '')
    return { kind: 'final', text: s.finalText }
  }
  return undefined
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({ name: 'codex-view', description: 'Switch the main view to the latest Codex agent (/codex-view main to return).' })
    return next(e)
  })

  on('agent.spawn', async ($, e: any, next) => {
    if (e.subagentType === 'codex-team:codex') {
      pending.push({ prompt: e.prompt, cwd: e.cwd ?? (await $.session.cwd()) })
      // The row's model label comes from the spawn's model; show Codex's own.
      return next({ ...e, model: await modelOf($) })
    }
    return next(e)
  })

  on('turn.step', async function* ($, e: any, next: any) {
    const agentId: string | undefined = e.agentId
    if (!agentId || !(await isCodex($, agentId))) {
      const it = next(e)
      for (;;) {
        const n = await it.next()
        if (n.done) return n.value
        yield n.value
      }
    }
    lastAgent = agentId
    const model = await modelOf($)
    let s = states.get(agentId)
    if (!s) {
      const { prompt: task, cwd } = pending.shift() ?? { prompt: '', cwd: '' }
      const job: Job = { id: 'c' + ++seq, task, cwd, readOnly: /READ ONLY/.test(task), events: [], outputs: new Map(), ended: false, err: '', thread: '', inTok: 0, outTok: 0, cached: 0 }
      s = { job, cursor: 0, held: '' }
      states.set(agentId, s)
      queue.push(job)
      if (!worker) {
        worker = true
        void (async () => {
          for (;;) {
            const j = queue.shift()
            if (!j) { await $.clock.sleep(300); continue }
            await runJob($, j)
          }
        })()
      }
    }
    let act: Act
    while (!(act = scan(s))) {
      if (next.signal?.aborted) return { turnId: e.turnId, index: e.index, answer: '', toolUses: [], stopReason: 'end_turn', usage: null }
      await tick($)
    }
    if (act.kind === 'final') {
      const input = { message: act.text }
      yield { kind: 'text', index: 0, text: act.text }
      yield { kind: 'tool', index: 1, id: `toolu_codex_${s.job.id}_final_${e.index}`, name: 'SubagentHandback' }
      yield { kind: 'input', index: 1, json: JSON.stringify(input) }
      const usage = usageOf(s.job, model)
      yield { kind: 'stop', stopReason: 'tool_use', usage }
      return { turnId: e.turnId, index: e.index, answer: act.text, toolUses: [{ name: 'SubagentHandback', input }], stopReason: 'tool_use', usage }
    }
    let idx = 0
    if (act.text) yield { kind: 'text', index: idx++, text: act.text }
    const input = { command: act.command, description: 'codex' }
    toolMap.set(act.id, { job: s.job, itemId: act.itemId })
    yield { kind: 'tool', index: idx, id: act.id, name: 'Bash' }
    yield { kind: 'input', index: idx, json: JSON.stringify(input) }
    const usage = usageOf(s.job, model)
    yield { kind: 'stop', stopReason: 'tool_use', usage }
    return { turnId: e.turnId, index: e.index, answer: act.text, toolUses: [{ name: 'Bash', input }], stopReason: 'tool_use', usage }
  })

  on('tool.check', { tool: 'Bash' }, async ($, e: any, next) => (toolMap.has(e.tool_use_id) ? { decision: 'allow' } : next(e)))

  on('tool.call', { tool: 'Bash' }, async ($, e: any, next: any) => {
    const m = toolMap.get(e.tool_use_id)
    if (!m) {
      // Force the native route: Claude must delegate to Codex through the subagent, not by shelling out.
      if (!e.agentId && DIRECT.test(e.command ?? '') && !/HY_DIRECT=1/.test(e.command))
        return { deny: 'Delegating to Codex must use the Agent tool with subagent_type "codex-team:codex" (native view, live stream), not Bash. Spawn it with the task as the prompt. Prefix HY_DIRECT=1 only if the user explicitly asked for the CLI route.' }
      return next(e)
    }
    while (!m.job.outputs.has(m.itemId) && !m.job.ended && !next.signal?.aborted) await tick($)
    return { result: { stdout: m.job.outputs.get(m.itemId) ?? '', stderr: '', interrupted: false } }
  })

  on('command.run', { command: 'codex-view' }, async ($, e: any) => {
    if ((e.args ?? '').trim() === 'main') { await $.ui.view({}); return { text: 'Main view.' } }
    const list = await $.agent.list()
    const a = [...list].reverse().find((x: any) => x.type === 'codex-team:codex') ?? list.find((x: any) => x.id === lastAgent)
    if (!a) return { text: 'No codex agent yet.' }
    const r = await $.ui.view({ agentId: a.id })
    return { text: r.deny ? `Cannot switch: ${r.deny}` : `Viewing codex agent ${a.id}. /codex-view main to return.` }
  })
}
