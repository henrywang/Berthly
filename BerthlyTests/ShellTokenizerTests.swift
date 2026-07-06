import Foundation
import Testing
@testable import Berthly

// MARK: - ShellTokenizer

struct ShellTokenizerTests {

    @Test func plainWordsSplitOnWhitespace() {
        #expect(ShellTokenizer.tokenize("nginx -g daemon") == ["nginx", "-g", "daemon"])
    }

    @Test func emptyAndBlankInputYieldNoWords() {
        #expect(ShellTokenizer.tokenize("") == [])
        #expect(ShellTokenizer.tokenize("   \t  ") == [])
    }

    @Test func collapsesRunsOfWhitespaceAndTrims() {
        #expect(ShellTokenizer.tokenize("  npm   start  ") == ["npm", "start"])
    }

    @Test func doubleQuotesKeepSpacesInOneWord() {
        // The motivating case: a `-c` script must arrive as a single argv word.
        #expect(ShellTokenizer.tokenize(#"sh -c "echo hello world""#) == ["sh", "-c", "echo hello world"])
    }

    @Test func doubleQuotesCanBeEmbeddedInAWord() {
        // nginx -g "daemon off;" — quotes glue onto the surrounding word like a shell.
        #expect(ShellTokenizer.tokenize(#"nginx -g "daemon off;""#) == ["nginx", "-g", "daemon off;"])
    }

    @Test func singleQuotesAreLiteral() {
        #expect(ShellTokenizer.tokenize(#"echo 'a "b" \n c'"#) == ["echo", #"a "b" \n c"#])
    }

    @Test func escapedQuoteAndBackslashInsideDoubleQuotes() {
        #expect(ShellTokenizer.tokenize(#"echo "say \"hi\" \\ done""#) == ["echo", #"say "hi" \ done"#])
    }

    @Test func otherBackslashesInsideDoubleQuotesStayLiteral() {
        // In POSIX double quotes, backslash only escapes ", \, $, ` — for plain characters it
        // stays. (We only special-case " and \ since there's no expansion.)
        #expect(ShellTokenizer.tokenize(#"grep "a\tb""#) == ["grep", #"a\tb"#])
    }

    @Test func unquotedBackslashEscapesSpace() {
        #expect(ShellTokenizer.tokenize(#"cat /tmp/my\ file"#) == ["cat", "/tmp/my file"])
    }

    @Test func explicitEmptyQuotesProduceAnEmptyWord() {
        #expect(ShellTokenizer.tokenize(#"env -i """#) == ["env", "-i", ""])
        #expect(ShellTokenizer.tokenize("printf ''") == ["printf", ""])
    }

    @Test func unterminatedQuoteRunsToEndInsteadOfFailing() {
        // GUI-friendly recovery: mid-typing input still tokenizes sensibly.
        #expect(ShellTokenizer.tokenize(#"sh -c "echo hi"#) == ["sh", "-c", "echo hi"])
    }

    @Test func trailingLoneBackslashIsDropped() {
        #expect(ShellTokenizer.tokenize(#"echo hi\"#) == ["echo", "hi"])
    }

    @Test func adjacentQuotedSegmentsJoinIntoOneWord() {
        #expect(ShellTokenizer.tokenize(#"echo "foo"'bar'baz"#) == ["echo", "foobarbaz"])
    }
}
