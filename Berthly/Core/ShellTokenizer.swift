// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import Foundation

/// Splits a typed command line into argv words the way a POSIX shell lexes them, so a command
/// like `sh -c "echo hello world"` becomes `["sh", "-c", "echo hello world"]` instead of five
/// broken words. Used by the Run Container sheet's Command field, which feeds an exec-style API.
///
/// Rules (lexing only — no variable/glob expansion, this never runs a shell):
/// - unquoted whitespace separates words
/// - single quotes preserve everything literally
/// - double quotes preserve everything except `\"` and `\\`, which escape to `"` and `\`
/// - an unquoted backslash escapes the next character
/// - an unterminated quote is treated as running to the end of the input rather than an error —
///   for a GUI field, "do the obvious thing" beats rejecting input mid-typing
nonisolated enum ShellTokenizer {
    static func tokenize(_ input: String) -> [String] {
        enum Quote { case none, single, double }

        var tokens: [String] = []
        var current = ""
        // Tracks "a word exists" separately from `current` being non-empty, so explicit empty
        // quotes ('' or "") still produce an empty argv word like a real shell.
        var inWord = false
        var quote = Quote.none
        var i = input.startIndex

        while i < input.endIndex {
            let c = input[i]
            switch quote {
            case .none:
                if c == "'" {
                    quote = .single
                    inWord = true
                } else if c == "\"" {
                    quote = .double
                    inWord = true
                } else if c == "\\" {
                    let next = input.index(after: i)
                    if next < input.endIndex {
                        current.append(input[next])
                        inWord = true
                        i = next
                    }
                    // A trailing lone backslash is dropped, like a shell awaiting continuation.
                } else if c.isWhitespace {
                    if inWord {
                        tokens.append(current)
                        current = ""
                        inWord = false
                    }
                } else {
                    current.append(c)
                    inWord = true
                }
            case .single:
                if c == "'" {
                    quote = .none
                } else {
                    current.append(c)
                }
            case .double:
                if c == "\"" {
                    quote = .none
                } else if c == "\\" {
                    let next = input.index(after: i)
                    if next < input.endIndex, input[next] == "\"" || input[next] == "\\" {
                        current.append(input[next])
                        i = next
                    } else {
                        current.append(c)
                    }
                } else {
                    current.append(c)
                }
            }
            i = input.index(after: i)
        }
        if inWord {
            tokens.append(current)
        }
        return tokens
    }
}
