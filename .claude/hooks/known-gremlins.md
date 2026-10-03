# Known gremlins (session-start brief)

Small, deliberately short, hand-maintained excerpt that
`.claude/hooks/session-start-brief.py` prints at the start of every
session in this repo, per backlog #150 ("surfaces the current
known-gremlin list ... so it's read rather than rediscovered"). This is
**not** a mirror of the live log — `adamastorx/docs/SESSION_STATE.md` is
the full, current source of truth and covers more ground (Cilium
`toPorts`/enforcement-direction quirks, Bitnami secret regeneration, the
GitOps stale-local-main branching trap, crash-loop backoff, and more).
Update this file by hand when SESSION_STATE.md's own list changes in a
way worth carrying into every session's opening context — an old entry
that stops being "worth knowing before touching this again" should be
trimmed here too, not left to accumulate.

1. **ArgoCD `root`'s own refresh tax** (backlog #125/#126, 2026-08-20).
   Merging a change to `argocd/apps/*` and hard-refreshing the *child*
   Application isn't enough — the app-of-apps `root` Application manages
   every child as one of its own tracked resources, so if `root` hasn't
   itself noticed the git diff, the child keeps serving a stale spec no
   matter how hard it's refreshed directly. Refresh `root` first; check
   its sync status flips to a real `OutOfSync` before assuming a
   "refresh did nothing" symptom means something else.

2. **Boot 4.1 split autoconfiguration** (services#3, #4,
   observability#1). Adding a Spring Boot client library
   (`spring-kafka`, `flyway-core`, an OTel exporter, ...) alone compiles
   clean and then silently never activates at runtime — the
   `FooAutoConfiguration` wiring that actually turns it on lives in a
   *separate* `spring-boot-<name>` artifact that also has to be added.

3. **Cilium's DNS proxy (`toFQDNs`/`rules.dns`) is genuinely broken in
   this cluster's exact config** (tunnel/vxlan routing +
   kubeProxyReplacement/socket-LB, matches open upstream
   `cilium/cilium#46284`). The moment any policy adds an L7 `rules.dns`
   selector it drops *all* locally-originated pod DNS, not just the
   intended FQDN. Use `toCIDR` with real IP ranges for public egress
   instead — confirmed working around this for every flow that needed
   it.

Full detail, plus everything not repeated here, lives in
`adamastorx/docs/SESSION_STATE.md`.
