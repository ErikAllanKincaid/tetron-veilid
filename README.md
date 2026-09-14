# tetron-veilid

A bringup tool that installs a `--features footgun-nodeid-target` build of
[veilid-server](https://gitlab.com/veilid/veilid) as a local companion
daemon for [tetron](https://github.com/ErikAllanKincaid/tetron)'s
external-daemon Veilid transport, and builds that binary in the first
place -- upstream's own officially distributed apt package does not have
this feature enabled, and it is required for the safety mode tetron needs.

**Optional and separate from tetron core on purpose**, same relationship
`tetron-relay`/`tetron-webui`/`tetron-systray`/`tetron-testsuite` have to
core: a genuinely separate, opt-in addon. Nothing about tetron's own
behavior changes whether this exists or not.

## Why this exists

tetron previously embedded a full Veilid node (`veilid-core`) directly
inside its own daemon process as one of several transports
(`--features veilid`). That broke the "do one thing well" pattern every
other piece of extra capability in this project already follows (Tor is a
thin client to an external daemon, not an embedded onion-routing stack;
relay/webui/systray are separate repos) -- see
`tetron/DO-NOT-COMMIT/PLAN_VeilidExternalDaemon_ThinClientSpike.md` for
the full history. Moving Veilid the same way Tor already works means
tetron talks to a Veilid node running as its own process, not one living
inside tetron's own daemon.

The catch: `RoutingContext::with_safety()` in `veilid-core` refuses
`SafetySelection::Unsafe` -- the mode tetron's transport actually needs
for reliable delivery -- unless the binary was compiled with the
`footgun-nodeid-target` Cargo feature. Confirmed live (2026-09-14,
`tetron/DO-NOT-COMMIT/SPIKE_VeilidExternalDaemon_Results.md` section 1b):
the apt-packaged `veilid-server` from `packages.veilid.net` is not built
with it. `tetron-veilid` exists to build and distribute one that is.

This is not a source fork or a patch -- `footgun-nodeid-target` is
already a real, named feature in upstream `veilid-server`'s own
`Cargo.toml`. Building it just means a different `--features` flag against
unmodified upstream source, pinned to a specific tag
(see `VEILID_PIN`).

## Design

- **A real build pipeline, not a fetch script.** Unlike `tetron-relay`
  (which downloads iroh's own prebuilt `iroh-relay` binary), upstream
  veilid does not publish a `footgun-nodeid-target` build anywhere --
  `.github/workflows/release.yml` builds it from source on every tagged
  release, matrix'd over `x86_64`/`aarch64-unknown-linux-gnu` using
  GitHub's native-arm64 runners (same pattern as tetron core's own
  `release.yml`).
- **Version-pinned, deliberately.** `VEILID_PIN` names the exact upstream
  `veilid` tag this addon builds -- bumped by hand, never auto-tracking
  `main`, the same discipline `veilid-transport/Cargo.toml` already
  applies to its own `veilid-core = "0.5.7"` pin. Currently pinned to
  `v0.5.7`, matching what tetron's own (embedded, being phased out)
  Veilid transport was built and proven against.
- **Loopback-only by default.** The wire protocol
  (`veilid-server`'s `client_api`) carries no authentication of any kind
  (confirmed live, results doc section 3) -- `tetron-veilid up` binds
  `127.0.0.1:5959` by default. A `tetron-veilid` instance is meant to run
  as a local companion to a tetron daemon on the *same* host, the same
  relationship tetron's `--tor` support already has to a local Tor
  daemon's ControlPort -- not a shared, network-reachable service the way
  `tetron-relay` is. Only widen `--listen` if you specifically intend a
  remote/shared instance and plan to restrict access yourself (firewall
  rule); this tool will not do that for you.
- **Never mutates your firewall.** Same policy as `tetron-relay`.
- **Distinct naming from upstream's own package**, on purpose: binary at
  `/usr/local/bin/tetron-veilid-server`, config at
  `/etc/tetron-veilid/veilid-server.conf`, state under
  `/var/lib/tetron-veilid/`, dedicated `tetron-veilid` system user and
  `tetron-veilid.service` unit. A box that also happens to have the
  unrelated, distro-packaged `veilid-server` installed for something else
  is unaffected either way.
- **Bash-driven, like tetron-relay/tetron-testsuite** for the install
  side -- no Cargo/Rust toolchain needed *on the target*. The build
  itself (CI only) does need one, same as tetron core's own release
  pipeline.

## Prerequisites

A Linux server or workstation (x86_64 or aarch64) reachable over SSH (or
"local"), with passwordless sudo for the SSH user (or run as root
directly). No domain, no open inbound ports required -- `client_api`'s
default `127.0.0.1:5959` binding needs nothing beyond what an ordinary
tetron node's own machine already allows.

```bash
cp hosts.conf.example hosts.conf   # edit for your host(s)
```

## Usage

```bash
./bin/tetron-veilid up --host local
# -> installs tetron-veilid-server, config, and systemd unit; starts it

./bin/tetron-veilid status --host local
./bin/tetron-veilid down --host local              # stop, keep config/binary
./bin/tetron-veilid down --host local --purge       # stop and remove everything

# A remote node, over SSH (hosts.conf: "node2  ssh:user@node2.example.com"):
./bin/tetron-veilid up --host node2

# Only if you specifically intend a remote/shared instance:
./bin/tetron-veilid up --host node2 --listen 0.0.0.0:5959
```

## Layout

```
VEILID_PIN                         -- single source of truth: the upstream
                                       veilid git tag this addon builds
hosts.conf.example                 -- copy to hosts.conf (gitignored) and edit
bin/tetron-veilid                   -- CLI: up | status | down
lib/common.sh                       -- host inventory + run_on/upload_to
lib/veilid.sh                       -- bringup logic (install-side only)
templates/veilid-server.conf.tmpl   -- rendered into /etc/tetron-veilid/
templates/tetron-veilid.service.tmpl -- installed as-is to /etc/systemd/system/
.github/workflows/release.yml       -- the actual build pipeline (CI only)
```

## Status

Scaffolded 2026-09-14, not yet built/released or live-verified end to end.
Definition of done, per
`tetron/DO-NOT-COMMIT/PLAN_TetronVeilidAddon_Scope.md`: a real release
built by CI, installed via `tetron-veilid up` on a fresh
`tetron-testsuite` VM, with the corrected AppMessage RPC re-test
(`tetron/DO-NOT-COMMIT/veilid-spike/external-daemon/run-spike-corrected.sh`)
passing end to end between two such installs. Until that passes, treat
this as unvalidated scaffolding, not a working tool.

## Explicitly out of scope for v1

- Following upstream veilid's `main` branch automatically -- `VEILID_PIN`
  is bumped by hand.
- musl, macOS, Windows, Android/iOS builds.
- Any UI beyond this CLI and a one-line install command a `tetron-webui`
  addon entry can show -- see the parent plan doc's "Reducing install
  friction" section.
- An `allow`-style access-control command (`tetron-relay` has one for its
  EndpointId allowlist) -- the wire protocol has no such concept to manage;
  access control here is "who can reach 127.0.0.1:5959," a firewall/network
  question, not something this tool can enforce at the protocol level.
