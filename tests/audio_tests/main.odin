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
    owner, only_xid, matched := audio.Match_Owner(exact, windows)
    ok(matched && owner.PID == 100 && only_xid == 10, "verified XID and process match")
    wrong_process := exact
    wrong_process.Process.Start_Time = 56
    _, _, matched = audio.Match_Owner(wrong_process, windows)
    ok(!matched, "PID reuse is rejected")
    helper := exact
    helper.Process.PID = 101
    _, _, matched = audio.Match_Owner(helper, windows)
    ok(!matched, "browser helper PID is not guessed")
    missing_pid := exact
    missing_pid.Valid = false
    _, _, matched = audio.Match_Owner(missing_pid, windows)
    ok(!matched, "missing window process metadata is rejected")
    unnamed := exact
    unnamed.Window_XID = 0
    duplicate_windows := []audio.Window_Candidate{
        {XID = 10, Process = proc_a, Eligible = true},
        {XID = 11, Process = proc_a, Eligible = true},
    }
    owner, only_xid, matched = audio.Match_Owner(unnamed, duplicate_windows)
    ok(matched && owner.PID == 100 && only_xid == 0, "multi-window process is matched at application level")
    owner, only_xid, matched = audio.Match_Owner(unnamed, windows)
    ok(matched && owner.PID == 100 && only_xid == 0, "unique verified process match")
    grouped_models := audio.Build_Window_Models([]audio.Stream{{Index = 5, Channels = 1, Volume_Writable = true}},
        []audio.Stream_Candidate{{Index = 5, Process = proc_a, Valid = true}}, duplicate_windows)
    ok(len(grouped_models) == 2 && len(grouped_models[0].Stream_Indices) == 1 && len(grouped_models[1].Stream_Indices) == 1,
       "same-process windows share application audio")
    audio.Free_Window_Models(&grouped_models)
    child := audio.Stream_Candidate{Index = 2, Process = audio.Verified_Process{PID=101, Start_Time=56, Executable="cliamp"}, Valid=true}
    child.Ancestors[0] = {PID=proc_a.PID, Start_Time=proc_a.Start_Time}
    child.Ancestor_Count = 1
    owner, _, matched = audio.Match_Owner(child, windows)
    ok(matched && owner.PID == 100, "verified terminal child maps to its terminal window")
    owner, _, matched = audio.Match_Owner(child, duplicate_windows)
    ok(matched && owner.PID == 100, "terminal child groups onto the owning terminal windows")
    child.Ancestors[0].Start_Time += 1
    _, _, matched = audio.Match_Owner(child, windows)
    ok(!matched, "stale terminal ancestor is rejected")
    launcher := audio.Verified_Process{PID = 300, Start_Time = 99, Executable = "dolphin"}
    player := audio.Verified_Process{PID = 301, Start_Time = 98, Executable = "mpv"}
    launched := audio.Stream_Candidate{Index = 6, Process = player, Valid = true}
    launched.Ancestors[0] = {PID = launcher.PID, Start_Time = launcher.Start_Time}
    launched.Ancestor_Count = 1
    launched_windows := []audio.Window_Candidate{
        {XID = 30, Process = launcher, Eligible = true},
        {XID = 31, Process = player, Eligible = true},
    }
    owner, only_xid, matched = audio.Match_Owner(launched, launched_windows)
    ok(matched && owner.PID == player.PID && only_xid == 0, "player process wins over the launcher ancestor")
    launched_models := audio.Build_Window_Models([]audio.Stream{{Index = 6, Channels = 1, Volume_Writable = true}},
        []audio.Stream_Candidate{launched}, launched_windows)
    ok(len(launched_models) == 1 && launched_models[0].Window_XID == 31,
       "only the player window receives the launcher-child stream")
    audio.Free_Window_Models(&launched_models)
    far := audio.Verified_Process{PID = 400, Start_Time = 90, Executable = "launcher"}
    near_ancestor := audio.Verified_Process{PID = 401, Start_Time = 91, Executable = "terminal"}
    nested := audio.Stream_Candidate{Index = 7, Process = audio.Verified_Process{PID = 402, Start_Time = 92, Executable = "cliamp"}, Valid = true}
    nested.Ancestors[0] = {PID = near_ancestor.PID, Start_Time = near_ancestor.Start_Time}
    nested.Ancestors[1] = {PID = far.PID, Start_Time = far.Start_Time}
    nested.Ancestor_Count = 2
    nested_windows := []audio.Window_Candidate{
        {XID = 40, Process = far, Eligible = true},
        {XID = 41, Process = near_ancestor, Eligible = true},
    }
    owner, _, matched = audio.Match_Owner(nested, nested_windows)
    ok(matched && owner.PID == near_ancestor.PID, "nearest ancestor wins over a farther launcher window")
    client_meta := audio.Client_Meta{Index = 3, Process_ID = 402, Application_ID = "org.kde.elisa",
        Process_Binary = "elisa", Process_Host = "host", Machine_ID = "machine"}
    filled := audio.Stream{Index = 8}
    ok(audio.Apply_Client_Meta(&filled, client_meta), "client metadata fills missing stream fields")
    ok(filled.Process_ID == 402 && filled.Process_Binary == "elisa" && filled.Application_ID == "org.kde.elisa" &&
       filled.Process_Host == "host" && filled.Machine_ID == "machine", "client metadata merges into the stream")
    delete(filled.Process_Binary); delete(filled.Application_ID); delete(filled.Process_Host); delete(filled.Machine_ID)
    kept := audio.Stream{Index = 9, Process_ID = 500, Process_Binary = "stream-binary", Application_ID = "stream-id",
        Process_Host = "stream-host", Machine_ID = "stream-machine"}
    ok(!audio.Apply_Client_Meta(&kept, client_meta), "stream metadata wins over client metadata")
    ok(kept.Process_ID == 500 && kept.Process_Binary == "stream-binary" && kept.Application_ID == "stream-id" &&
       kept.Process_Host == "stream-host" && kept.Machine_ID == "stream-machine", "existing stream identity is preserved")
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
