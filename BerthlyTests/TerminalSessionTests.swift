// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import Foundation
import Testing
@testable import Berthly

/// Covers `TerminalSession.ExecPipePolicy`, the fd-ownership split that stops an exec session from
/// double-closing the descriptors it hands the daemon. The regression it guards: `createProcess`
/// closes the fd it receives, so a second close from this side lands on the reused number — in the
/// field, a freshly-fetched container-log fd, which then failed `readToEnd()` with `EBADF`
/// ("Stream ended" after visiting the Terminal tab).
///
/// The policy is tested as a pure value rather than by opening real pipes: `FileHandle` deinit is
/// non-deterministic (ObjC autorelease), so raw-fd juggling under Swift Testing's parallel runner
/// races and crashes the host.
struct TerminalSessionTests {

    typealias Policy = TerminalSession.ExecPipePolicy

    // MARK: - Direction: the daemon gets the correct end for each stream

    @Test func stdinHandsOffTheReadEnd() {
        // stdin: the daemon reads the container's input, so it receives the pipe's read end and we
        // keep the write end to push keystrokes into.
        #expect(Policy.policy(handOff: .read).handOffIsReadEnd == true)
    }

    @Test func stdoutHandsOffTheWriteEnd() {
        // stdout: the daemon writes the container's output, so it receives the write end and we
        // keep the read end to render from.
        #expect(Policy.policy(handOff: .write).handOffIsReadEnd == false)
    }

    // MARK: - Ownership: the fix's core invariant, in both directions

    @Test func handedOffEndNeverClosesOnDeallocAndKeptEndAlwaysDoes() {
        // createProcess closes the handed-off fd itself; closing it again from this side is the
        // double-close that clobbered the container-log fd. So the handed-off end must never own
        // its close, and the kept end always must (no leak).
        for handOff in [TerminalSession.HandOffEnd.read, .write] {
            let policy = Policy.policy(handOff: handOff)
            #expect(policy.handOffOwnsClose == false)
            #expect(policy.keepOwnsClose == true)
        }
    }
}
