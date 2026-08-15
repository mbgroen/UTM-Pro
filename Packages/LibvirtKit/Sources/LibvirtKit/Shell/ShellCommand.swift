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

import Foundation

/// Builds a command line for a remote shell with every argument quoted.
///
/// SSH exec runs its command through the login shell, so anything interpolated
/// into it is shell syntax. Domain, pool and volume names come from the user
/// and from the remote host, and libvirt happily accepts names containing
/// spaces, quotes and semicolons — so nothing may be pasted in raw.
///
/// Build every command through this type. It has no interface for appending
/// unquoted text, which is the point: there is no call site where quoting can
/// be forgotten.
public struct ShellCommand: Sendable {
    private var words: [String]

    /// - Parameter executable: the program to run. Not quoted, so it must be a
    ///   literal in our own source — never a value from outside.
    public init(_ executable: StaticString) {
        self.words = ["\(executable)"]
    }

    /// Appends a literal flag, such as `--all`.
    ///
    /// Takes a `StaticString` so only compile-time constants can land here.
    public mutating func flag(_ flag: StaticString) {
        words.append("\(flag)")
    }

    /// Appends a runtime value, quoted.
    public mutating func argument(_ value: String) {
        words.append(Self.quote(value))
    }

    /// Appends a runtime value, quoted, only if it is non-nil.
    public mutating func argument(_ value: String?) {
        guard let value else { return }
        argument(value)
    }

    /// Appends a numeric value. Numbers need no quoting.
    public mutating func argument(_ value: some BinaryInteger) {
        words.append(String(describing: value))
    }

    /// Appends a literal flag followed by a quoted value.
    public mutating func option(_ flag: StaticString, _ value: String) {
        self.flag(flag)
        argument(value)
    }

    /// Appends a literal flag followed by a numeric value.
    public mutating func option(_ flag: StaticString, _ value: some BinaryInteger) {
        self.flag(flag)
        argument(value)
    }

    /// Appends a literal flag and value only if the value is non-nil.
    public mutating func option(_ flag: StaticString, _ value: String?) {
        guard let value else { return }
        option(flag, value)
    }

    public var commandLine: String {
        words.joined(separator: " ")
    }

    /// Wraps `value` in single quotes, which suppress every form of shell
    /// expansion. A single quote inside the value is closed, escaped and
    /// reopened — the standard POSIX idiom.
    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Pipes this command's output into another, for the rare case where a
    /// round trip per item would be wasteful.
    public func piped(into other: ShellCommand) -> ShellCommand {
        var combined = self
        combined.words = [commandLine, "|", other.commandLine]
        return combined
    }
}

extension ShellCommand: CustomStringConvertible {
    public var description: String { commandLine }
}
