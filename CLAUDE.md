# WebKit-on-Mavericks backport

## The project

Backport modern WebKit (currently 625.1.11) to run on macOS 10.9.5 Mavericks under the **stock, unmodified Safari 7.0.6** (WebKit 9537.78.2). Branch `mavericks-backport`, origin `github.com/wowfunhappy/webkit`, forked from upstream `83b24ce` (Ryosuke Niwa, 2026-03-16). The exact fork points may change in the future as we continue to track upstream; if they do, update this document.

- Checkout: `/Users/jonathan/Desktop/webkit`.
- `MavericksSupport/` holds all the 10.9 glue: `polyfill/` (the layer), `deps/` (vendored third-party, built by `build_deps.sh` into the gitignored `deps/build/`), `toolchain/`, `rebuild.sh`, `install-safari7.sh` (name-shifts the 4 built frameworks into place), `scripts/check-backport-markers.sh`.
- Build: in-tree CMake/Ninja against the macOS 26.1 SDK + clang-22, deployment target 10.9.
- **This machine IS the 10.9.5 VM** (Darwin 13.4.0). Testing is in-VM: install, launch Safari, drive it with `osascript` and the `mcp__computer-use-mavericks__*` tools. Osascript is preferred where possible.
- The VM is yours. Break it, leave it in odd states, install stock WebKit for an A/B — all fine without asking. Never pause work because the user appears to be using it; they will yield when they see activity. If they don't, even repeatedly, it is the user's mistake, and you should tell the user rather than stop work.

## Autonomy

**Never stop to ask a question, and never sit idle.** The user is frequently away for many hours. Pick the most-correct option and execute; the user will correct course if needed. A genuine architectural fork, a real effort/risk tradeoff, and a "maintainer's judgment call" are all still not licenses to ask.

**Never stop mid-task to report progress.** On a multi-part or multi-batch goal, drive the whole thing to completion — commit each unit as you finish it, immediately start the next, pipeline the next batch's edits while a build runs. The only acceptable stop is: every listed item fixed and verified. A hard bug is not a stop.

**Waiting for the user is NEVER correct. There is no exception, in any circumstance.** It is not a status, a state, or a fallback — it does not exist. You do not stop for permission, a decision, a preference, a confirmation, an adjudication, or because a change is someone else's. "Blocked on the user", "needs your call", "yours to resolve", "I'll leave that to you" are all the same failure. If two courses are defensible, take the more correct one and execute; being wrong and corrected is always better than waiting and being right. Anything you could have fixed and instead handed back is the failure — the report does not redeem it. Report what you DID, never what you are waiting on.

**"Impossible / platform limitation / systemic / architectural fork / needs a huge subsystem" is never a reason to stop.** That conclusion is almost always a wrong dead-end from incomplete investigation. Sanity-check it against known facts — if a feature demonstrably shipped and worked, your "it fundamentally requires X" premise is false. Keep digging until you actually understand it.

**If a bug does not reproduce on modern macOS, upstream's code is correct and the defect is in one of our own divergences — therefore fixable.** Never write anything off as "systemic", "intermittent", or "Heisenbug". Those describe difficulty, not impossibility. Option-tuning that only shifts or widens a crash is diagnosis, not a fix.

**Fix what you find, in the same session.** When a sweep, review, or investigation surfaces an adjacent problem, fix it now. Recording it, filing it, or "tracking it as a residual" is deferral with paperwork. These are the disguises, all forbidden:

- "It's pre-existing / not my change / out of scope / its own change / a different bug." You are responsible for the whole codebase. Never sort findings by origin; when a review returns N findings, fix N findings.
- "A build is running, so I'll fold it in later." Edit now, restart the build after.
- "It's only a comment / cosmetic." A marker's premise is its justification; a false premise misleads the next reader.
- "It would force a rebuild / cost 40 minutes / need a re-review." The moment you start computing whether a fix is worth its process cost, that computation is the tell.
- "Say the word if you want that closed too" / "want me to…?" Naming a known-broken behavior and offering to fix it is the same deferral. The only sentence allowed after naming a gap is that you are already fixing it.
- **"It's someone else's uncommitted work / the user is mid-investigation / a note says it's intentional."** Authorship exempts nothing. A note that a working-tree change is *intentional* describes someone's intent, not its correctness — it never exempts that change from the build, the gates, the reviewer, or the no-hacks rule. Debug scaffolding that alters upstream control flow, fails to compile from scratch, or fails `check-backport-markers.sh` is broken code in your tree, and you fix it like any other. If that means reverting hunks you did not write, revert them and say so plainly in your report.

A red gate, a broken build, or work you are calling uncommittable is never something you report and leave — it is something you fix, now, whoever wrote the cause. Attributing it to someone else's files looks like diligence and is the same deferral. Where a fix would destroy work, preserve it first (save the hunks to a patch and name the path) and then make the tree correct anyway.

**Spend as many cycles as it takes.** A multi-layer bug fully root-caused is the goal, not a cost overrun. Never apologize for depth. Do not add band-aids.

## No hacks

**The upstream-diff test, applied before writing any code:** does this exact mechanism exist in upstream WebKit? If the change *adds* something upstream doesn't have — a timer, a retry, a poll, a fallback, a guard, an `@try/@catch` swallow, a forced state, a magic threshold, a special-case branch, a disabled feature flag, a stub returning a fake value — it is masking a bug. Stop.

This is a *backport*: upstream's logic is correct by assumption. Every real bug here is one of three things — (a) upstream code lost, stubbed, or left as return-0/null during resurrection, (b) a system API that behaves differently on 10.9, or (c) our own contamination. The fix is always to restore correct upstream behavior, never to invent new behavior.

**Not a hack:** restoring lost upstream source; using an available 10.9 API that produces behavior identical to upstream. When it's genuinely unclear, the adversarial reviewer adjudicates.

**Name the root cause before writing a fix.** State the specific function/line that diverges from upstream and why. "Requests get lost under burst" is a symptom; "the response reaches the NetworkProcess but path Y drops it because Z was stubbed" is a root cause. If you can't name it, you're not allowed to write a fix yet.

**A hack is NEVER kept — not even temporarily. **If removing a hack breaks a feature, do NOT add it back to "get back to a working build". Instead, go back and fix the problem properly.

Forbidden rationalizations — each is a red flag that you are about to violate this: "risk-managed", "acceptable for a backport", "kept with A/B evidence", "load-bearing", "not removable", "dormant so it's fine", "keep until the real fix lands", "removing it breaks X", "documented as a known limitation". Evidence never buys a keep; a measured keep is still a keep.

**A memory calling something "the fix" does not exempt it.** Apply the upstream-diff test to memory-blessed mechanisms too. When one is retired, update its memory in the same change or a future session will faithfully reintroduce it.

**Never pick a worse design to get a faster one-time recompile.** Build time is throwaway; the code lives forever. (That said, when adding temporary code for debugging purposes, try to write it in a way which will minimize build time.)

## The adversarial reviewer

Run the `adversarial-hack-reviewer` agent on **every** bug fix, hack removal, guard change, and polyfill move — before committing, and before reporting done. **Never ask permission.** It is part of the definition of done, like the build.

- Verdicts are **binding**. REJECTED means do not commit and do not report done. Disagreement goes back to the reviewer with evidence (SendMessage), never around it and never by stopping to wait for the user.
- Give it real adversarial material: name the hunks you are least sure of and say what you did *not* prove.
- **Every finding is fixed in the same change**, related or not. Its mandate is codebase-wide. NOTHING is out of scope. If the reviewer finds a problem, it is automatically in scope for you to fix.
- Its approval does not mean the user's problem is solved. It judges hacks and divergences; only a measurement judges "fast", and only the user's scenario judges "fixed".

## Divergence and the polyfill layer

**Divergence-minimization order:** link the real symbol → build-config flag → external polyfill → source edit. Prefer converting an existing source edit into a polyfill over keeping it.

**A no-op / "fake" stub in the polyfill layer is an acceptable price for keeping WebKit source byte-upstream.** That said, real implementations are greatly preferred over stubs.

### Markers

Every kept divergence carries a `// MAVERICKS_BACKPORT:` comment explaining the present mechanism.

**Comment upstream code out, never delete it** — `//` for a line or two, `/* */` for a block — so upstream merges still see the original text. `check-backport-markers.sh` treats every pure-deletion hunk as a violation.

- **Keep the gate passing.** Run `MavericksSupport/scripts/check-backport-markers.sh` after your last edit under `Source/`, and report that run. Only a `Source/` edit can change its verdict — the gate does not scan `MavericksSupport/`, and builds, installs and tests read source without changing it. A build finishing is not a reason to re-run it.
- **Never edit the gate to make your own work pass.** Fix the tree. If a rule genuinely cannot be satisfied, bring the evidence to the user rather than changing the rule.
- Common false positive: `git diff -U0` splits a divergence so the closing `#endif`/`}` lands in its own hunk. Put the marker **on the closer line** (`#endif // MAVERICKS_BACKPORT: closes the ENABLE(GPU_PROCESS) guard above.`).
- **Never bulk-script deletion or relocation of marker comments.** A `//` after a `\` continuation splices into the `#if` expression; `#endif`/`#define`/`#include` lines are not comments. The checker is blind to all of it — only the build catches it.

## Comments and prose

**Describe what IS there. Never what used to be, what will be, or why you chose it.**

Banned: "used to", "previously", "formerly", "no longer", "was X", "intentionally omits", "reconstructed/replaces a long-lost…", "being migrated", "until that lands", "work in progress". If something was removed, its comment goes too — don't narrate an absence.

Also banned:

- **Saying what you are NOT doing.** "nothing here is committed", "rather than declared impossible", "instead of editing upstream's". State the mechanism; an absence needs no comment.
- **Narrating what a past change, install, or agent did.** No repair-pass explanations — better still, don't write the repair pass.
- **Decision history.** No `# AUDITED <date>:` trails, no rejected alternatives ("wolfSSL also works here, but…"). The commit message carries the reasoning; the file does not. The pull toward this is strongest right after a review, when the reasoning feels load-bearing. It isn't.
- **Failure-mode comments**, even in present tense: "without it the failure surfaces as an unresolved reference at link time", "getting this wrong is silent". A gate's own FATAL message already says what breaks.

**Keep them sparse.** Prefer one tight comment over three, and be thoughtful before adding one at all — comment volume is something the user pushes back on.

**Litmus:** would this sentence still make sense to someone who has never seen the previous version of the file? If it only makes sense as a contrast with what was there before, delete it.

When editing a file, also fix any pre-existing stale comment in the region you touch.

## Hard boundaries

- **Never modify Safari.app or WebInspectorUI.framework** — not their CSS, not their resources. The whole premise is a drop-in WebKit under an untouched Safari 7. If a bug can only be "fixed" by editing a file inside an Apple app or framework, it is not fixed.
- **Never reboot, restart, or shut down the VM.** We run inside it. If a change seems to need a reboot, relaunch the process instead.
- Safari/WebKit should work well even in highly resource constrained and CPU-starved environments.
- **Never blame AquaProxy, the VM, the platform, TLS, DNS, or "a CoreGraphics quirk".** AquaProxy is a stable, multi-year, extensively validated part of this stack — treat it as ground truth, like the kernel. You are not permitted even to question it, because every past "proof" against it was wrong. Any stall, swallowed response, or keepalive theory that ends at the proxy is an unfound WebKit-side defect. Never hardcode or fall back to `https_proxy` in a committed script. Note also that Claude's shells lack `HTTPS_PROXY` (a launch-order race), so a bare-curl or raw-socket test from your shell says **nothing** about Safari, which is proxied and works.
- **Never commit build artifacts.** Anything regenerable lives in a gitignored `build/`. The one sanctioned committed binary is the vendored clang. If a new third-party library is needed, add it to `build_deps.sh` and its required-artifacts gate.
- **Never weaken a gate** to make your own work pass.

## The build loop

**The invariant: a build capable of verifying your pending edits is running whenever you have pending build-requiring work.**

- **Edit source while ninja compiles.** It is safe — ninja read each TU at its own compile start — and the running build keeps warming ccache.
- **The moment your edit batch is ready, relaunch `rebuild.sh` immediately.** The last tool call of any edit batch that changes built source is that relaunch. No judgment required, no size threshold. **Never hand-kill first:** rebuild.sh safely stops the in-flight build itself, waiting out a cmake configure before it signals anything.
- **Forbidden, all the same violation:** idle-waiting for the in-flight build; queuing a restart behind it (`until ! pgrep ninja` loops — automation does not convert a wait into compliance); "once it lands I'll rebuild"; stopping a build early and then editing with nothing building; starting a *different* build instead of restarting the invalidated one. Efficiency arguments ("those objects are still valid", "they won't collide") are the forbidden cost computation in scheduler clothes. This is settled; don't re-derive it.
- **Never kill, suspend, or renice a build to answer a question or free the CPU.** Measure anyway and disclose the contention. Remember that WebKit must work well even in resource constrained environments.
- **Every command that compiles or links anything logs to `/tmp/wk_build.log`** — `rebuild.sh`, bare `ninja`, `cmake --build`, `build-polyfill.sh`, `build_deps.sh`, one-target relinks. No ad-hoc names, and no second log for the wrapper's own stdout (append with `>>`). The user tails this one file.
- **Verify a launch actually started** (`pgrep -f 'MavericksSupport/rebuild.sh'` non-empty, log growing) and **notice when it finishes.** Prefer one `until grep -q "REBUILD DONE"` waiter over stacked ones; act on a completion notification immediately rather than re-arming another waiter. Because every build reuses the one log, a monitor can fire instantly on the *previous* run's content — check the log's mtime before believing a FAILED line, or use the per-run background-task output file.
- Long blocking `until` loops outlive the tool call and accumulate into orphaned pollers. Use short single checks.

## Verification and "done"

- **Wait for `REBUILD DONE (rc=0)` + `FAILED=0` + four `LINKED` lines before installing.** Staging runs after compile/link; installing early reads a half-populated staged tree.
- **After installing, relaunch Safari** — a running WebContent keeps the old code mapped and will silently serve your measurements from the previous build. Verify the quit actually took (`kill -0`, escalate to SIGTERM);
- **Test on complex real sites**. _Never_ use Wikipedia, example.com, or Hacker News; passing on a trivial page proves nothing.
- **A slow page load is always a bug**, never "normal" or "expected for a heavy SPA".
- **Compile success proves nothing at runtime.** Removing a `respondsToSelector:` guard means polyfilling every selector the unguarded statement sends (including setters on the receiving object), on the concrete cluster class as well as the public one, with each C function's arity read off the disassembly. Gate on a real page load that parses, a byte-exact download, and a crash count.

## Committing

- **Commit every change once it is complete and verified** — don't leave it in the working tree.
- Preconditions: build green, `check-backport-markers.sh` PASS from a run no earlier than your last `Source/` edit, reviewer approval.
- **Write the commit message from `git diff`, not from your plan.** Verify any "X now matches upstream" claim mechanically (`git diff <base> -- <file> | wc -l` — 0 or it isn't byte-identical). This is sharpest after a bisect, where re-applying hunks by hand silently drops the ones you forget.
- Messages explain the root cause.
- If the user explicitly asks you to ammend a previous commit, it is implied that he either has not pushed or intends to do a force push. Please do as asked.

## Environment notes

- **Prefer `osascript` over the computer-use click/type tools** — it talks to Safari directly and is far more reliable. Reserve coordinate clicks for chrome AppleScript can't reach. Still screenshot to verify actual rendering; osascript can drive and query but can't see.
- **Rate measurements via `osascript` are unreliable.** Running the command foregrounds Terminal, which occludes Safari, and macOS throttles occluded windows (rAF drops to ~1Hz vs a healthy ~54fps foreground). Judge rendering, animation, scroll, and lazy-load by screenshot. `do JavaScript` is fine for static state.
- `/Applications/Momiji.app` is a **Firefox** fork, not our WebKit. It is a fair reference browser for "what should this look like".

## Memory

The memory directory records **what has been tried and learned** — root causes, keystones, per-issue history, environment traps. Standing rules live in this file, not there. Don't write a memory that restates a rule here, and don't write one framing a WebKit bug as environmental or unfixable.
