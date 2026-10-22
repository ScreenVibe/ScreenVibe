import type { Register } from 'claude-code'

// The UandI app and this mod meet in ~/.uandi:
//   sessions/<sessionId>.json   this session, rewritten every few seconds (the app lists live ones)
//   inbox/<sessionId>/<markup>/ the app writes prompt.txt + pictures, then `ready` last
// A markup is submitted once: `taken` is written before the prompt goes out.

const HEARTBEAT_MS = 3000
const POLL_MS = 1000

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const result = await next(e)
    // The terminal, or the Claude desktop app, which runs Claude Code as an SDK host. Not one-off `-p` runs.
    const desktop = (await $.env.get('CLAUDE_CODE_ENTRYPOINT')) === 'claude-desktop'
    if (!e.isInteractive && !desktop) return result

    const home = await $.env.get('HOME')
    if (home === undefined) return result
    const sessionId = await $.session.id()
    const root = `${home}/.uandi`
    const inbox = `${root}/inbox/${sessionId}`
    const card = `${root}/sessions/${sessionId}.json`
    await $.process.run(['mkdir', '-p', `${root}/sessions`, inbox])

    const repo = await $.session.repo().catch(() => null)
    const folder = e.cwd.split('/').filter(Boolean).pop() ?? e.cwd
    const label = repo?.name ?? folder

    let lastBeat = 0
    const beat = async () => {
      const now = await $.clock.now()
      if (now - lastBeat < HEARTBEAT_MS) return
      lastBeat = now
      await $.fs.write(card, JSON.stringify({ sessionId, label, cwd: e.cwd, updatedAt: now }))
    }

    const poll = async () => {
      await beat()
      const entries = await $.fs.list(inbox).catch(() => [])
      for (const entry of entries.filter(x => x.kind === 'dir').sort((a, b) => a.name.localeCompare(b.name))) {
        const dir = `${inbox}/${entry.name}`
        if (!(await $.fs.exists(`${dir}/ready`)) || (await $.fs.exists(`${dir}/taken`))) continue
        await $.fs.write(`${dir}/taken`, '')
        const text = await $.fs.read(`${dir}/prompt.txt`)
        $.ui.toast('UandI markup received')
        void $.prompt.submit({ text })
      }
    }

    await beat()
    $.clock.every(POLL_MS, () => void poll())
    return result
  })

  on('session.end', async ($, e, next) => {
    const home = await $.env.get('HOME')
    const sessionId = await $.session.id()
    if (home !== undefined) await $.process.run(['rm', '-f', `${home}/.uandi/sessions/${sessionId}.json`])
    return next(e)
  })
}
