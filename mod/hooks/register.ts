import type { EngineInterface, Register, Timer } from 'claude-code'

// The ScreenVibe app and this mod meet in ~/.screenvibe:
//   sessions/<sessionId>.json   this session, rewritten every few seconds (the app lists live ones)
//   inbox/<sessionId>/<markup>/ the app writes prompt.txt + pictures, then `ready` last
// A markup is submitted once: `taken` is written before the prompt goes out.
// A session that lost its connection keeps its id but its timer can die, so the app stops listing it.
// Each prompt restarts a timer that went quiet, and /screenvibe links the session again by hand.

const HEARTBEAT_MS = 3000
const POLL_MS = 1000
const QUIET_MS = 10000

let linked = false
let lastBeat = 0
let timer: Timer | undefined

/** Starts (or restarts) the card and the inbox check. False when ~/.screenvibe can't be made. */
const link = async ($: EngineInterface): Promise<boolean> => {
  const home = await $.env.get('HOME')
  if (home === undefined) return false
  const sessionId = await $.session.id()
  const cwd = await $.session.cwd()
  const root = `${home}/.screenvibe`
  const inbox = `${root}/inbox/${sessionId}`
  const card = `${root}/sessions/${sessionId}.json`
  const made = await $.process.run(['mkdir', '-p', `${root}/sessions`, inbox]).then(() => true, () => false)
  if (!made) return false

  const repo = await $.session.repo().catch(() => null)
  const label = repo?.name ?? cwd.split('/').filter(Boolean).pop() ?? cwd

  const beat = async (force = false) => {
    const now = await $.clock.now()
    if (!force && now - lastBeat < HEARTBEAT_MS) return
    lastBeat = now
    await $.fs.write(card, JSON.stringify({ sessionId, label, cwd, updatedAt: now }))
  }

  const poll = async () => {
    await beat()
    const entries = await $.fs.list(inbox).catch(() => [])
    for (const entry of entries.filter(x => x.kind === 'dir').sort((a, b) => a.name.localeCompare(b.name))) {
      const dir = `${inbox}/${entry.name}`
      if (!(await $.fs.exists(`${dir}/ready`)) || (await $.fs.exists(`${dir}/taken`))) continue
      await $.fs.write(`${dir}/taken`, '')
      const text = await $.fs.read(`${dir}/prompt.txt`)
      $.ui.toast('ScreenVibe markup received')
      void $.prompt.submit({ text })
    }
  }

  timer?.cancel()
  await beat(true)
  timer = $.clock.every(POLL_MS, () => void poll())
  linked = true
  return true
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const result = await next(e)
    await $.command.register({ name: 'screenvibe', description: 'Link this session to the ScreenVibe app again' })
    // The terminal (JetBrains runs it there too), or the Claude desktop app and the VS Code extension, which run
    // Claude Code as an SDK host. Not one-off `-p` runs.
    const host = await $.env.get('CLAUDE_CODE_ENTRYPOINT')
    if (!e.isInteractive && host !== 'claude-desktop' && host !== 'claude-vscode') return result
    if (!(await link($))) $.ui.toast('ScreenVibe could not create its folder in ~/.screenvibe')
    return result
  })

  on('command.run', { command: 'screenvibe' }, async $ => {
    const ok = await link($)
    if (ok) $.ui.toast('Linked to ScreenVibe')
    return { text: ok
      ? 'Linked to ScreenVibe. This session is in its Send menu now.'
      : 'ScreenVibe could not create its folder in ~/.screenvibe.' }
  })

  on('prompt.submit', async ($, e, next) => {
    if (linked && (await $.clock.now()) - lastBeat > QUIET_MS) await link($)
    return next(e)
  })

  on('session.end', async ($, e, next) => {
    timer?.cancel()
    linked = false
    const home = await $.env.get('HOME')
    const sessionId = await $.session.id()
    if (home !== undefined) await $.process.run(['rm', '-f', `${home}/.screenvibe/sessions/${sessionId}.json`])
    return next(e)
  })
}
