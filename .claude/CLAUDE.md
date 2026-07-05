# Build a knowledge db

## Tech Radar

* Uncle Bobs Clean Code Onion architetcure
* functional programming
* pure functions
* side effects isolated
* NvKind
* HELM to package for k8s artifacts
* https://github.com/kubernetes-sigs/multicluster-runtime
* https://github.com/kubernetes-sigs/kro
* go lang
* https://github.com/kyverno/chainsaw

## What to do

* TDD test FIRST
┌─────────────────────────────────────────────────────────┐
│                                                         │
│    🔴 RED          🟢 GREEN         🔄 REFACTOR        │
│                                                         │
│    Write failing   Write minimal    Improve code       │
│    test            code to pass     keep tests passing │
│                                                         │
│         │              │               │               │
│         ▼              ▼               ▼               │
│    Test must fail  Test must pass   Tests still pass  │
│                                                         │
└─────────────────────────────────────────────────────────┘
* Respect the authority of the User
* Operate testdriven TDD
* Plan, Implement Eval, Implement Logic, Validate loop
* Use simple promts
* Run linting, tests before and after each change
* Add resources to git
* Prompt the user, to commit
* use .claude/plans for keeping track of planning
* use .claude/specs to write minimal specs
* Externalize Config Values

## What not to do

* Create ton of summary slop
* Long winded wordy un precisie specfications
* Copy documentation form tools
* commit to .git
* Do not encode magic numbers or values, they need to be config values
* scrpits/ folder should not be needed this ALWAYS ask the user, where to put a script when you think its needed.
  
---
© 2026 sojoner
