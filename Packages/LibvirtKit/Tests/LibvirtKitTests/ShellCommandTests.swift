//
// Copyright © 2026 UTM Pro contributors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

import XCTest
@testable import LibvirtKit

final class ShellCommandTests: XCTestCase {
    func testPlainArgumentIsQuoted() {
        var command = ShellCommand("virsh")
        command.flag("dominfo")
        command.argument("Pi-hole")
        XCTAssertEqual(command.commandLine, "virsh dominfo 'Pi-hole'")
    }

    /// A domain name is attacker-influenced input: libvirt allows spaces and
    /// punctuation, and the name may have been set from the OMV web UI or by
    /// another admin. None of it may reach the shell as syntax.
    func testCommandSubstitutionIsNeutralised() {
        var command = ShellCommand("virsh")
        command.flag("dominfo")
        command.argument("$(rm -rf /)")
        XCTAssertEqual(command.commandLine, "virsh dominfo '$(rm -rf /)'")
    }

    func testSemicolonDoesNotTerminateCommand() {
        var command = ShellCommand("virsh")
        command.flag("destroy")
        command.argument("vm; reboot")
        XCTAssertEqual(command.commandLine, "virsh destroy 'vm; reboot'")
    }

    func testBacktickIsQuoted() {
        var command = ShellCommand("virsh")
        command.argument("`id`")
        XCTAssertEqual(command.commandLine, "virsh '`id`'")
    }

    /// The single-quote escape is the one case where naive quoting breaks: the
    /// value must close the quote, escape the literal quote, and reopen.
    func testEmbeddedSingleQuoteIsEscaped() {
        XCTAssertEqual(ShellCommand.quote("it's"), "'it'\\''s'")
    }

    func testEmbeddedSingleQuoteCannotEscapeQuoting() {
        var command = ShellCommand("virsh")
        command.argument("'; rm -rf / ;'")
        XCTAssertEqual(command.commandLine, "virsh ''\\''; rm -rf / ;'\\'''")
    }

    func testNewlineStaysInsideQuotes() {
        var command = ShellCommand("virsh")
        command.argument("a\nreboot")
        XCTAssertEqual(command.commandLine, "virsh 'a\nreboot'")
    }

    func testOptionQuotesOnlyTheValue() {
        var command = ShellCommand("virsh")
        command.option("--pool", "My Pool")
        XCTAssertEqual(command.commandLine, "virsh --pool 'My Pool'")
    }

    func testNumericArgumentIsUnquoted() {
        var command = ShellCommand("virsh")
        command.option("--size", 4096)
        XCTAssertEqual(command.commandLine, "virsh --size 4096")
    }

    func testNilOptionIsOmitted() {
        var command = ShellCommand("virsh")
        command.option("--pool", String?.none)
        XCTAssertEqual(command.commandLine, "virsh")
    }

    func testEmptyArgumentSurvivesAsEmptyString() {
        var command = ShellCommand("virsh")
        command.argument("")
        XCTAssertEqual(command.commandLine, "virsh ''")
    }
}
