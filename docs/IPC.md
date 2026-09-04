# skarwm IPC

skarwm listens on a Unix socket at `$XDG_RUNTIME_DIR/skarwm.sock`, falling back
to `/tmp/skarwm-<uid>.sock`. Set `SKARWM_SOCKET` for an explicit path in both
the WM and `skarwm-msg`.

The transport uses i3's 14-byte `i3-ipc` frame header. This lets consumers use
the standard workspace/output request and subscription shapes while keeping
the skarwm-specific surface deliberately small. The protocol identifier
returned by `get-version` is `i3-ipc+skarwm-v1`.

## Commands

```text
skarwm-msg focus left|right|up|down
skarwm-msg move left|right|up|down
skarwm-msg workspace N|next|prev
skarwm-msg move workspace N
skarwm-msg move workspace next|prev
skarwm-msg toggle-floating
skarwm-msg toggle-fullscreen
skarwm-msg layout tabbed|stacked|toggle
skarwm-msg toggle-tabbed
skarwm-msg show-bindings
skarwm-msg focus output next|prev
skarwm-msg move output next|prev
skarwm-msg close
skarwm-msg reload
skarwm-msg quit
```

Commands return the i3-style JSON array `[{"success":true}]`. Invalid commands
return a nonzero exit status and an error object.

## Queries

```text
skarwm-msg get-workspaces
skarwm-msg get-windows
skarwm-msg get-outputs
skarwm-msg get-version
```

`get-workspaces` and `get-outputs` use i3-compatible message types and object
fields. Workspace objects add a `windows` count so a shell can distinguish an
empty workspace without fetching the window list. `get-windows` is skarwm
extension type 100 and returns metadata, workspace membership, state, and the
last arranged geometry for every managed client. Tiled clients also include
`column`, `column_layout`, `tab_index`, `tab_count`, and `tab_active`;
non-tiled clients use null/zero values. Type 101 reports protocol version
information.

## Events

```text
skarwm-msg subscribe workspace window output
```

The subscription first prints its success reply, then one JSON event per line.
Workspace changes are `init`, `focus`, and `empty`. Window changes are `new`,
`close`, `focus`, `title`, `urgent`, and `layout`. Output events contain an
`output` name and a `change` of `connected`, `disconnected`, `geometry`, or
`focus`; consumers should refresh `get-outputs` when one arrives.

The socket server is nonblocking and shares skarwm's poll loop. A malformed or
slow IPC peer therefore cannot block X event handling; individual clients are
dropped on framing errors or failed writes.
