import type { Register } from 'claude-code'

// The ScreenVibe app and this mod meet in ~/.screenvibe:
//   sessions/<sessionId>.json   this session, rewritten every few seconds (the app lists live ones)
//   inbox/<sessionId>/<markup>/ the app writes prompt.txt + pictures, then `ready` last
// A markup is submitted once: `taken` is written before the prompt goes out.

const HEARTBEAT_MS = 3000
const POLL_MS = 1000

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const result = await next(e)
    // The terminal (JetBrains runs it there too), or the Claude desktop app and the VS Code extension, which run
    // Claude Code as an SDK host. Not one-off `-p` runs.
    const host = await $.env.get('CLAUDE_CODE_ENTRYPOINT')
    if (!e.isInteractive && host !== 'claude-desktop' && host !== 'claude-vscode') return result

    const home = await $.env.get('HOME')
    if (home === undefined) return result
    const sessionId = await $.session.id()
    const root = `${home}/.screenvibe`
    const inbox = `${root}/inbox/${sessionId}`
    const card = `${root}/sessions/${sessionId}.json`
    const made = await $.process.run(['mkdir', '-p', `${root}/sessions`, inbox]).then(() => true, () => false)
    if (!made) {
      $.ui.toast('ScreenVibe could not create its folder in ~/.screenvibe')
      return result
    }

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
        $.ui.toast('ScreenVibe markup received')
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
    if (home !== undefined) await $.process.run(['rm', '-f', `${home}/.screenvibe/sessions/${sessionId}.json`])
    return next(e)
  })
}
