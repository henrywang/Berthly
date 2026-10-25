// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import ContainerAPIClient
import Foundation
import MachineAPIClient
import Testing
@testable import Berthly

// #208: Create Machine account fields — validation, mapping to `Flags.MachineUser`, and the
// setup-failure message.
struct MachineAccountTests {
    @Test func machineUserFlagsDefaultToAllNilForTheHostUser() {
        let flags = LiveContainerService.machineUserFlags(for: MachineCreateOptions(reference: "alpine:3.22"))
        #expect(flags.user == nil)
        #expect(flags.uid == nil)
        #expect(flags.gid == nil)
        #expect(flags.home == nil)
    }

    @Test func machineUserFlagsMapAccountAndOmitEmptyStrings() {
        let custom = LiveContainerService.machineUserFlags(for: MachineCreateOptions(
            reference: "alpine:3.22", user: "dev", uid: 4242, gid: 4343, home: "/home/devhome"
        ))
        #expect(custom.user == "dev")
        #expect(custom.uid == 4242)
        #expect(custom.gid == 4343)
        #expect(custom.home == "/home/devhome")

        let blank = LiveContainerService.machineUserFlags(for: MachineCreateOptions(
            reference: "alpine:3.22", user: "", home: ""
        ))
        #expect(blank.user == nil)
        #expect(blank.home == nil)
    }

    @Test func machineUserSetupFailureMessageNamesTheAccount() {
        let message = LiveContainerService.machineUserSetupFailureMessage(username: "dev", uid: 1000, home: "/home/dev")
        #expect(message.contains("'dev' (UID 1000)"))
        #expect(message.contains("/home/dev"))
    }

    @Test func blankInputIsValidAndAppliesNothing() {
        let input = MachineAccountInput()
        #expect(input.validationError == nil)
        var options = MachineCreateOptions(reference: "alpine:3.22")
        input.apply(to: &options)
        #expect(options.user == nil)
        #expect(options.uid == nil)
        #expect(options.gid == nil)
        #expect(options.home == nil)
    }

    @Test func appliesTrimmedValues() {
        let input = MachineAccountInput(user: " dev ", uid: " 4242", gid: "4343 ", home: " /home/devhome ")
        #expect(input.validationError == nil)
        var options = MachineCreateOptions(reference: "alpine:3.22")
        input.apply(to: &options)
        #expect(options.user == "dev")
        #expect(options.uid == 4242)
        #expect(options.gid == 4343)
        #expect(options.home == "/home/devhome")
    }

    @Test(arguments: ["dev", "4242", "dev:4343", "4242:4343"])
    func acceptsUpstreamUserFormats(user: String) {
        #expect(MachineAccountInput(user: user).validationError == nil)
    }

    @Test(arguments: [
        MachineAccountInput(user: "dev:staff"),
        MachineAccountInput(uid: "abc"),
        MachineAccountInput(uid: "-1"),
        MachineAccountInput(uid: "4294967296"),
        MachineAccountInput(gid: "x"),
        MachineAccountInput(home: "home/dev")
    ])
    func rejectsInputUpstreamWouldRejectOrMisread(input: MachineAccountInput) {
        // Invalid text must block Create, never collapse to nil and fall back to the host user.
        #expect(input.validationError != nil)
    }

    @Test func defaultHomeFollowsTheTypedUsername() {
        #expect(MachineAccountInput(user: "dev").defaultHome == "/home/dev")
        #expect(MachineAccountInput(user: "dev:4343").defaultHome == "/home/dev")
        #expect(MachineAccountInput().defaultHome == "/home/\(NSUserName())")
        // A numeric user changes only the UID; the name stays the host user's.
        #expect(MachineAccountInput(user: "4242").defaultHome == "/home/\(NSUserName())")
    }
}
