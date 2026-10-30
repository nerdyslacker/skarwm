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
    ok(len(state.Streams) == 1 && state.Streams[0].Generation == 1, "state-only update preserves stream generation")
    ok(state.Streams[0].Muted, "stream update copies live state")
    audio.Replace_Stream(&state, audio.Stream{Index = 17, Generation = 3, Process_ID = 44})
    ok(state.Streams[0].Generation == 3, "process identity change invalidates cached verification")

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

    proc_a := audio.Verified_Process{PID = 100, Start_Time = 55, Executable = "player"}
    windows := []audio.Window_Candidate{
        {XID = 10, Process = proc_a, Eligible = true},
    }
    exact := audio.Stream_Candidate{Index = 1, Window_XID = 10, Process = proc_a, Valid = true}
    ok(audio.Match_Window(exact, windows) == 10, "verified XID and process match")
    wrong_process := exact
    wrong_process.Process.Start_Time = 56
    ok(audio.Match_Window(wrong_process, windows) == 0, "PID reuse is rejected")
    helper := exact
    helper.Process.PID = 101
    ok(audio.Match_Window(helper, windows) == 0, "browser helper PID is not guessed")
    missing_pid := exact
    missing_pid.Valid = false
    ok(audio.Match_Window(missing_pid, windows) == 0, "missing window process metadata is rejected")
    unnamed := exact
    unnamed.Window_XID = 0
    duplicate_windows := []audio.Window_Candidate{
        {XID = 10, Process = proc_a, Eligible = true},
        {XID = 11, Process = proc_a, Eligible = true},
    }
    ok(audio.Match_Window(unnamed, duplicate_windows) == 0, "multi-window process is ambiguous")
    ok(audio.Match_Window(unnamed, windows) == 10, "unique verified process match")
    child := audio.Stream_Candidate{Index = 2, Process = audio.Verified_Process{PID=101, Start_Time=56, Executable="cliamp"}, Valid=true}
    child.Ancestors[0] = {PID=proc_a.PID, Start_Time=proc_a.Start_Time}
    child.Ancestor_Count = 1
    ok(audio.Match_Window(child, windows) == 10, "verified terminal child maps to its terminal window")
    ok(audio.Match_Window(child, duplicate_windows) == 0, "terminal child remains hidden when one ancestor owns multiple windows")
    child.Ancestors[0].Start_Time += 1
    ok(audio.Match_Window(child, windows) == 0, "stale terminal ancestor is rejected")
    ok(audio.Application_Matches_Process("mpv", "", "mpv"), "PipeWire application ID identifies mpv")
    ok(audio.Application_Matches_Process("elisa", "", "org.kde.elisa"), "reverse-domain application ID identifies Elisa")
    ok(audio.Application_Matches_Process("vlc", "/usr/bin/vlc", "org.VideoLAN.VLC"), "binary metadata identifies VLC")
    ok(!audio.Application_Matches_Process("mpv", "", "org.kde.elisa"), "unrelated application metadata is rejected")

    stream_a := audio.Stream{Index = 1, Channels = 2, Volume_Writable = true}
    stream_a.Volume[0], stream_a.Volume[1] = 32_768, 32_768
    balanced := audio.Stream{Index = 9, Channels = 2, Volume_Writable = true}
    balanced.Volume[0], balanced.Volume[1] = 16_384, 32_768
    scaled, channels := audio.Scale_Stream_Volume(&balanced, 32_768, 65_536)
    ok(channels == 2 && scaled[0] == 8_192 && scaled[1] == 16_384, "volume scaling preserves channel balance")
    scaled, _ = audio.Scale_Stream_Volume(&balanced, 131_072, 32_768)
    ok(scaled[0] == 32_768 && scaled[1] == 65_536, "volume scaling caps at 100 percent without flattening balance")
    silent := audio.Stream{Index = 10, Channels = 2, Volume_Writable = true}
    scaled, _ = audio.Scale_Stream_Volume(&silent, 32_768, 0)
    ok(scaled[0] == 32_768 && scaled[1] == 32_768, "silent streams can be raised without division by zero")
    queued: audio.State
    queued.Enabled, queued.Available, queued.Connected = true, true, true
    queued.Streams = make([dynamic]audio.Stream)
    queued.Controls = make([dynamic]audio.Control)
    append(&queued.Streams, audio.Stream{Index=9, Generation=4, Channels=2, Volume=balanced.Volume, Volume_Writable=true})
    ok(audio.Queue_Stream_Volume(&queued, 9, 4, 32_768, 65_536, false), "drag update queues for the live stream generation")
    ok(audio.Queue_Stream_Volume(&queued, 9, 4, 16_384, 32_768, true), "final drag update replaces the pending update")
    ok(len(queued.Controls) == 1 && queued.Controls[0].Volume[0] == 4_096 && queued.Controls[0].Volume[1] == 8_192,
       "coalesced drag updates retain relative channel levels")
    ok(audio.Queue_Stream_Mute(&queued, 9, 4, true) && queued.Controls[0].Set_Mute, "mute shares the per-stream command queue")
    ok(!audio.Queue_Stream_Volume(&queued, 9, 3, 0, 65_536, true), "stale stream generations cannot be controlled")
    ok(audio.Poll_Timeout_Ms(&queued) >= 0, "pending controls wake the host poll loop")
    delete(queued.Streams)
    delete(queued.Controls)
    stream_b := audio.Stream{Index = 2, Channels = 2, Volume_Writable = true, Muted = true}
    stream_b.Volume[0], stream_b.Volume[1] = 65_536, 65_536
    streams := []audio.Stream{stream_a, stream_b}
    verified := []audio.Stream_Candidate{
        {Index = 1, Process = proc_a, Valid = true},
        {Index = 2, Process = proc_a, Valid = true},
    }
    models := audio.Build_Window_Models(streams, verified, windows)
    ok(len(models) == 1 && len(models[0].Stream_Indices) == 2, "multiple verified streams aggregate per window")
    ok(models[0].Volume == 65_536 && models[0].Mixed_Mute && !models[0].Muted, "aggregate state is deterministic")
    audio.Free_Window_Models(&models)

    proc_b := audio.Verified_Process{PID = 200, Start_Time = 77, Executable = "other-player"}
    named_stream_a := audio.Stream{Index = 3, Application_Name = "Player", Channels = 1, Volume_Writable = true}
    named_stream_b := audio.Stream{Index = 4, Application_Name = "Player", Channels = 1, Volume_Writable = true}
    same_name_streams := []audio.Stream{named_stream_a, named_stream_b}
    same_name_verified := []audio.Stream_Candidate{
        {Index = 3, Process = proc_a, Valid = true},
        {Index = 4, Process = proc_b, Valid = true},
    }
    separate_windows := []audio.Window_Candidate{
        {XID = 10, Process = proc_a, Eligible = true},
        {XID = 20, Process = proc_b, Eligible = true},
    }
    separate_models := audio.Build_Window_Models(same_name_streams, same_name_verified, separate_windows)
    ok(len(separate_models) == 2, "duplicate application names are never grouped")
    audio.Free_Window_Models(&separate_models)
    fmt.printf("%d passed, %d failed\n", passed, failed)
    if failed != 0 { os.exit(1) }
}
