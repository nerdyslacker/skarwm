package main

import audio "../../src/audio"
import "core:fmt"
import "core:os"
import "core:sys/posix"

passed, failed: int

ok :: proc(condition: bool, label: string) {
    if condition {
        passed += 1
    } else {
        failed += 1
        fmt.eprintln("FAIL ", label)
    }
}

main :: proc() {
    state: audio.State
    ok(audio.Init(&state, false), "disabled registry initializes")
    ok(!state.Enabled && !state.Available, "disabled registry stays dormant")
    ok(audio.IO_Count(&state) == 0, "disabled registry has no descriptors")
    ok(audio.Poll_Timeout_Ms(&state) == -1, "disabled registry has no deadline")

    audio.Replace_Stream(&state, audio.Stream{Index = 17, Generation = 1})
    audio.Replace_Stream(&state, audio.Stream{Index = 17, Generation = 2, Muted = true})
    ok(len(state.Streams) == 1 && state.Streams[0].Generation == 2, "stream update replaces reused index")
    ok(state.Streams[0].Muted, "stream update copies live state")

    first := audio.Note_Stream_Event(&state, 17)
    second := audio.Note_Stream_Event(&state, 17)
    ok(first < second && audio.Stream_Event_Serial(&state, 17) == second, "newer event supersedes stale response")
    audio.Remove_Stream(&state, 17)
    ok(len(state.Streams) == 0, "stream removal clears live entry")
    ok(audio.Stream_Event_Serial(&state, 17) == second, "removed index keeps reuse tombstone")

    audio.Clear_Streams(&state)
    delete(state.Streams)
    delete(state.Versions)
    audio.Shutdown(&state)

    live: audio.State
    started := audio.Init(&live, true)
    if live.Available {
        ok(started, "optional libpulse symbols load")
        joined := false
        for _ in 0 ..< 10 {
            count := audio.IO_Count(&live)
            fds := make([]posix.pollfd, count)
            joined = joined || audio.Append_Poll_FDs(&live, fds, 0) == count
            timeout := audio.Poll_Timeout_Ms(&live)
            if timeout < 0 || timeout > 10 { timeout = 10 }
            _ = posix.poll(raw_data(fds), posix.nfds_t(len(fds)), timeout)
            audio.Dispatch_Poll(&live, fds, 0)
            delete(fds)
            audio.Run_Due(&live)
        }
        ok(joined, "Pulse descriptors join the host poll set")
        ok(live.Enabled, "unavailable server does not disable the WM-side registry")
    } else {
        ok(!started, "missing libpulse stays non-fatal")
    }
    audio.Shutdown(&live)
    fmt.printf("%d passed, %d failed\n", passed, failed)
    if failed != 0 { os.exit(1) }
}
