---
name: no-numeronyms
description: "User dislikes numeronyms/abbreviations like \"a11y\" in prose — spell terms out"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: c47932fc-4c19-4982-8b0a-f6961e96498d
---

In chat prose, do not use numeronyms or shorthand abbreviations (e.g. "a11y" for
accessibility, "i18n", "k8s") — spell the term out. Exception: only when it is a *big*
token save.

**Why:** the user had to ask what "a11y" meant; the shorthand cost clarity for no real
benefit in a one-off mention.

**How to apply:** write "accessibility", "internationalisation", "Kubernetes" in
conversation. Established skill/registry content that already uses the shorthand (e.g.
apex-accessibility's own description) is unaffected — this is about how I communicate.
Balance against [[be-token-efficient]] only when the long form is genuinely costly at scale.
