export const meta = {
  name: 'apex-build-wave',
  description: 'Run one APEX build wave: dispatch a code-worker per task in parallel, return a bounded per-task status array. Intermediate worker transcripts stay in the workflow runtime, not the main context (ADR-015).',
  phases: [
    { title: 'Wave', detail: 'parallel code-worker fan-out for one wave' },
  ],
}

// args = {
//   spec_path:      string  — full path to the spec (workers read it; the script cannot)
//   token_profile:  string  — lean | balanced | thorough | custom
//   wave_label:     string  — e.g. "Wave 2" (for the returned summary)
//   tasks:          [ { id: string, text: string, files: string[], acceptance: string,
//                        model?: string } ]
//                     model — optional per-task coder override from the spec's ▸<model>-tagged
//                     ## Wave plan (ADR-024). Pass the within-backend model string for THIS
//                     dispatch's backend only (a single workflow run never crosses backends —
//                     apex-code splits the DeepSeek batch from the Claude batch). Omit → the
//                     session default. e.g. 'deepseek-v4-pro' on the DeepSeek backend,
//                     'opus' on the Claude (APEX_MODE=coding) backend.
//   isolate:        boolean — true → run each worker in its own managed git worktree, so
//                             concurrent build/test recipes don't collide on build artifacts,
//                             lockfiles, ports, or dist/.next. Set by apex-code only when the
//                             wave's workers each run an artifact-producing recipe, or for
//                             headless/AFK builds. Default false (most waves are safe same-tree).
// }

const STATUS_SCHEMA = {
  type: 'object',
  properties: {
    task: { type: 'string' },
    status: { type: 'string', enum: ['DONE', 'DONE_WITH_CONCERNS', 'BLOCKED', 'NEEDS_CONTEXT'] },
    files_changed: { type: 'array', items: { type: 'string' } },
    summary: { type: 'string' },
    concern: { type: 'string' },
  },
  required: ['task', 'status', 'files_changed', 'summary'],
  additionalProperties: false,
}

phase('Wave')

const results = await parallel(
  args.tasks.map((t) => () =>
    agent(
      [
        `Execute exactly one coding task from the spec at ${args.spec_path}.`,
        `Token profile: ${args.token_profile}.`,
        ``,
        `Task ${t.id}: ${t.text}`,
        `Files for this task: ${t.files.join(', ')}`,
        `Acceptance criterion: ${t.acceptance}`,
        ``,
        `Follow your code-worker contract: read every listed file before writing; implement`,
        `exactly this task and nothing more; run the spec's applicable commands; verify the`,
        `acceptance criterion before returning. Make the conservative choice on micro-ambiguity.`,
        `Return ONLY the bounded status object — never a transcript.`,
      ].join('\n'),
      {
        label: t.model ? `worker:${t.id} (${t.model})` : `worker:${t.id}`,
        agentType: 'code-worker',
        schema: STATUS_SCHEMA,
        ...(t.model ? { model: t.model } : {}),
        ...(args.isolate ? { isolation: 'worktree' } : {}),
      }
    )
  )
)

return { wave: args.wave_label, tasks: results.filter(Boolean) }
