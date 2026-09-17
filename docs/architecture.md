# skarwm architecture

skarwm is divided into small Odin packages. `core` owns window-management
policy and can be tested without an X server. `x11`, `input`, `rendering`, and
`ui` provide focused platform and presentation layers. `wm` composes them and
owns application orchestration. The executable in `src/main.odin` only calls
`wm.Run()`.

These are real package boundaries rather than cosmetic folders. Dependencies
point inward toward `core` and low-level services; presentation packages never
import `wm` or access its global runtime state.

## Tree

```text
src/
├── main.odin
├── core/
│   ├── model.odin              clients, columns, workspaces, outputs, manager
│   ├── config.odin             runtime policy settings and defaults
│   ├── layout.odin             authoritative geometry and drop-target math
│   ├── ops.odin                focus, move, lifecycle, layout state changes
│   ├── resize.odin             size constraints and paired split resizing
│   ├── animation.odin          pure interpolation and easing math
│   └── ipc.odin                IPC protocol, commands, and JSON snapshots
├── x11/
│   ├── base.odin               base XCB ABI declarations
│   ├── properties.odin         atom and property helpers
│   └── randr.odin              RandR ABI declarations
├── input/
│   ├── bindings.odin           actions and resolved key bindings
│   ├── keysym.odin             keyboard/modifier lookup
│   └── keysym_data.odin        generated keysym table
├── rendering/
│   ├── animation.odin          animated geometry commit pipeline
│   └── shape.odin              rounded X Shape regions
├── ui/
│   ├── state.odin              UI-owned X resources and state
│   ├── tabs.odin               WM-owned tab decorations
│   ├── drop_overlay.odin       drag/drop direction overlay
│   └── bindings_help.odin      keybinding help overlay
├── process/process.odin        command spawning and terminal discovery
├── log/log.odin                logging
└── wm/
    ├── runtime.odin            startup, teardown, adoption, event loop
    ├── manager.odin            actions and core-to-X reflow bridge
    ├── config.odin             rc parsing, validation, atomic reload
    ├── ipc_server.odin         nonblocking Unix-socket IPC transport
    ├── ewmh.odin               EWMH and ICCCM policy coordination
    └── outputs.odin            monitor discovery and reconciliation
```

Within `src/`, `bar/` is the optional standalone dock/bar process. Outside
`src/`, `cmd/skarwm-msg/` is the standalone IPC client, `assets/` contains
installable session/config files, `scripts/` contains nested-X
integration tooling, and `tests/core_tests/` exercises the pure core package.
The bar owns its X rendering, script scheduler, XEmbed tray, and IPC client;
the WM only publishes launch/configuration state and workspace events.

The local package dependency direction is:

```text
main ──▶ wm ──▶ core
          ├──▶ input ──▶ x11
          ├──▶ rendering ──▶ core, x11, log
          ├──▶ ui ─────────▶ core, input, x11, log
          ├──▶ process ────▶ log
          ├──▶ log
          └──▶ x11
```

No package imports `wm`; this keeps the orchestration layer at the edge and
prevents subsystem-to-runtime dependency cycles.

## Runtime flow

Most behavior follows one path:

```text
X event / keybinding / IPC command
              │
              ▼
       wm action handler
              │ mutates through core operations
              ▼
     core.Manager state tree
              │
              ▼
       core.Arrange_All
              │ writes target Client.Geom values
              ▼
        wm reflow bridge
              │
              ├── rendering: animation, shape, X geometry
              ├── ui: tabs and overlays
              ├── focus and stacking
              └── EWMH + IPC notifications
```

`core/layout.odin` is the only authoritative tiled geometry pass. X-facing
code should request a reflow instead of assigning ad-hoc on-screen geometry.
Conversely, core code must not issue X requests, and extracted packages must
receive the state they need explicitly instead of reaching into `wm` globals.

## Where changes belong

- Data or invariants: `core/model.odin`.
- Focus, move, attach, detach, or mode policy: `core/ops.odin`.
- Tile positions, scrolling, previews, or drop hit-testing: `core/layout.odin`.
- Pure resize/animation calculations: the corresponding small core module.
- Raw X requests, replies, events, atoms, or properties: `x11/`.
- Key lookup or the action/binding vocabulary: `input/`.
- X events and translating user actions into core operations: `wm/manager.odin`.
- EWMH/ICCCM coordination: `wm/ewmh.odin`.
- Monitor discovery/reconciliation: `wm/outputs.odin`; raw RandR ABI: `x11/randr.odin`.
- Window animation and shaping: `rendering/`.
- Tabs and overlays: `ui/`.
- Configuration syntax: `wm/config.odin`; canonical defaults: `core/config.odin`.
- IPC command meaning/serialization: `core/ipc.odin`; socket transport:
  `wm/ipc_server.odin`.
