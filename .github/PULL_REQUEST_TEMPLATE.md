<!-- Thanks for contributing! A few notes to make review faster. -->

## Summary

<!-- One or two sentences describing what this PR does and why. -->

## Type

<!-- check all that apply -->
- [ ] feat — new functionality
- [ ] fix — bug fix
- [ ] docs — documentation only
- [ ] test — tests only
- [ ] plugin — new or changed plugin
- [ ] platform — OS-specific hook change
- [ ] chore — repo plumbing / CI

## Affected scope

- Platforms: `[ ] macOS  [ ] Linux  [ ] WSL2`
- Plugins touched: `<list>`
- Layers touched: `[ ] core/compose  [ ] core/k8s  [ ] platform  [ ] plugins  [ ] tests  [ ] docs`

## Verification

- [ ] `bash tests/lint.sh` passes
- [ ] `bats tests/bats/ tests/regression/` passes
- [ ] If touching a plugin: smoke-tested with `bash bootstrap.sh` end-to-end at least once
- [ ] If breaking a [SKILL.md invariant](../SKILL.md#4-critical-invariants--do-not-break): explained below

## Invariant impact

<!-- If you broke or relaxed any of the 10 invariants in SKILL.md, list which and why. -->

## Docs / i18n

- [ ] Updated EN docs
- [ ] Updated zh-CN docs (or filed as a follow-up TODO)

## Anything else

<!-- Screenshots, traces, related issues, etc. -->
