# APEX Token Configuration

## Global Default

default_profile: balanced

## Profiles

### lean
workers: 1
reviewer: false
max_specialists: 0
reviewer_depth: quick
testing_agent: false
docs_product: true
docs_inline: false

### balanced (default)
workers: 3
reviewer: true
max_specialists: 2
reviewer_depth: quick
testing_agent: false  # only activates when spec includes testing tasks
docs_product: true
docs_inline: true

### thorough
workers: unlimited
reviewer: true
max_specialists: unlimited
reviewer_depth: deep
testing_agent: false  # only activates when spec includes testing tasks
docs_product: true
docs_inline: true

## Custom Knobs

When token_profile: custom, configure individually:

workers: 2                    # parallel code-worker count
reviewer: true                # run apex-reviewer post-build
max_specialists: 1            # cap specialist agents per build
reviewer_depth: quick         # quick | deep
testing_agent: false          # only when spec has testing tasks
docs_product: true            # run apex-docs-product-agent
docs_inline: true             # inline JSDoc/TSDoc generation
model_workers: opus           # coding-host worker model (Opus fallback); primary coding = Codex via `codex exec` subprocess (ADR-027)
model_reviewer: opus          # reviewer of Codex-built code = Opus (cross-family); DeepSeek archived (ADR-027)

## Setting the Profile

Three ways (lower overrides higher):

1. Global default — this file
   default_profile: balanced

2. Per session — in docs/status.md or inline signal
   "run this session lean"
   "switch to thorough for this build"

3. Per spec — spec metadata block
   token_profile: thorough

Token config locks when "start build" is called.
No changes during AFK execution.

## Cost Reference (relative DeepSeek cost)

lean:      1x
balanced:  2-3x
thorough:  4-6x

Planning mode (Claude) cost is constant regardless of profile.
Profiles affect coding pipeline only.
