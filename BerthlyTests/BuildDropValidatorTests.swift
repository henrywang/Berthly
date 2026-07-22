// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import Testing
@testable import Berthly

struct BuildDropValidatorTests {

    @Test func canonicalNamesMatch() {
        #expect(BuildDropValidator.isDockerfileLike("Dockerfile"))
        #expect(BuildDropValidator.isDockerfileLike("Containerfile"))
    }

    @Test func caseInsensitive() {
        #expect(BuildDropValidator.isDockerfileLike("dockerfile"))
        #expect(BuildDropValidator.isDockerfileLike("DOCKERFILE"))
        #expect(BuildDropValidator.isDockerfileLike("cOnTaInErFiLe"))
    }

    @Test func prefixedVariantsMatch() {
        #expect(BuildDropValidator.isDockerfileLike("Dockerfile.prod"))
        #expect(BuildDropValidator.isDockerfileLike("containerfile.dev"))
    }

    @Test func suffixedVariantsMatch() {
        #expect(BuildDropValidator.isDockerfileLike("backend.Dockerfile"))
        #expect(BuildDropValidator.isDockerfileLike("worker.containerfile"))
    }

    @Test func unrelatedNamesAreRejected() {
        #expect(!BuildDropValidator.isDockerfileLike("README.md"))
        #expect(!BuildDropValidator.isDockerfileLike("main.swift"))
        #expect(!BuildDropValidator.isDockerfileLike(""))
    }

    @Test func nearMissesAreRejected() {
        #expect(!BuildDropValidator.isDockerfileLike("Dockerfile2"))
        #expect(!BuildDropValidator.isDockerfileLike(".dockerfileignore"))
    }
}
