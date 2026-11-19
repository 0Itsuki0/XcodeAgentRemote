//
//  Permission.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/16.
//

import Foundation


/// `PermissionRule`
///
///  Whether Xcode would ask the user before one of its agent's tool uses runs, decided from Xcode's permission settings
///  the way Xcode decides.
///
///  For a chat Xcode runs, the `.jsonl` shows a tool use with no result both while Xcode waits for the user and while
///  the tool runs. The same decision on the same settings tells the two apart.
///
///  How Xcode decides (from its logs: IDEIntelligenceChat and agentfileaccesssupervisor; checked with 26 commands run
///  in Xcode):
///  - The mode (`IDEChatAgentPermissionMode`): Manual, Xcode decides as below. Auto: the agent decides (can't be
///    predicted). dontAsk / bypassPermissions: the user is never asked.
///  - Tools, by name: the tools Xcode passes the agent as allowed (`--allowedTools`), and `toolRules`.
///  - Bash: the command is split into simple commands (pipelines, `&&`, `;`, subshells, `$(…)` even inside an
///    assignment or a redirect, `find -exec`). Every simple command must match an `allow` rule in `shellCommandRules`:
///    - the rule's first word is the command's name exactly (`ls` doesn't match `lsof` or `/bin/ls`);
///    - its other words follow in order, with only options (and an option's value) between them
///      (`git log` matches `git -C . log -1`; `git status` doesn't match `git stash status`);
///    - leading `VAR=value` assignments are ignored; what `xargs` or `env` run is not checked;
///    - the most specific matching rules (the longest pattern) decide, and all of them must be `allow`.
///    `dangerouslyAllowAllShellCommands` / `automaticallyManageCommands` allow every command.
///  - Files (only while Control File & Folder Access is on): the supervisor asks when a file is opened without access.
///    `pathRules` give a path and everything under it read / write access (the most specific path wins); the project
///    folder is open. Checked for the tools that name their file (Read, Write, Edit, …). Which files a Bash command
///    opens isn't in its input, so a Bash command's file access is not checked.
///  What can't be decided (Auto mode, a command that can't be parsed, missing settings) counts as asking: a tool use
///  taken for a request when it was running costs a repeated run; one taken as running when it waited never reaches
///  the user.
///
///  Settings are read fresh on every check. Xcode reads them when a chat's agent starts, so the two differ only if a
///  setting changed while that chat was open.
nonisolated extension XcodeAgentConfiguration {

    nonisolated enum PermissionRule {

        // MARK: Settings

        /// Xcode's permission settings (`permissions.json`), the fields the decision uses.
        struct Settings: Decodable {
            /// An Allowed Commands entry.
            struct CommandRule: Decodable {
                var action: String
                var pattern: String
            }

            /// An Allowed Tools entry.
            struct ToolRule: Decodable {
                var action: String
                var toolName: String
            }

            /// The access to a path and everything under it: `read`, `write`, `readDenyWrite` or `deny`.
            struct PathRule: Decodable {
                var access: String
                /// `system` (Xcode's defaults) or `user`.
                var owner: String?
                /// A path, or a glob (`/Users/me/.*`).
                var path: String
            }

            var automaticallyManageCommands: Bool?
            var dangerouslyAllowAllShellCommands: Bool?
            /// Whether Xcode's default path rules (`owner: system`) apply.
            var grantCommonLocations: Bool?
            var shellCommandRules: [CommandRule]?
            var toolRules: [ToolRule]?
            var pathRules: [PathRule]?
        }

        /// Where Xcode keeps its permission settings.
        private static let settingsFolder = FileManager.default
            .homeDirectoryForCurrentUser.appending(
                path:
                    "Library/Group Containers/group.com.apple.dt.Xcode.SecureSettingsContainer/CodingAssistant/AgentToolPermissionSettings"
            )

        /// The current settings; nil if Xcode has none or they can't be read.
        static func settings() -> Settings? {
            guard
                let data = try? Data(
                    contentsOf: settingsFolder.appending(
                        path: "permissions.json"
                    )
                )
            else { return nil }
            return try? JSONDecoder().decode(Settings.self, from: data)
        }

        /// Whether Control File & Folder Access is on (`supervisor-settings.json`).
        static var controlsFileAccess: Bool {
            struct Supervisor: Decodable { var enabled: Bool }
            let data = try? Data(
                contentsOf: settingsFolder.appending(
                    path: "supervisor-settings.json"
                )
            )
            return data.flatMap {
                try? JSONDecoder().decode(Supervisor.self, from: $0)
            }?.enabled ?? false
        }


        /// Whether the tool may run without asking (Xcode's pre-tool-use hook decision).
        static func toolIsAllowed(
            _ toolUse: ChatEvent.ToolUse,
            settings: Settings,
            agentAllowedTools: [String]
        ) -> Bool {
            if agentAllowedTools.contains(where: {
                toolUse.name == $0 || toolUse.name.hasPrefix($0 + "__")
            }) {
                return true
            }
            if toolUse.name == "Bash" {
                if settings.dangerouslyAllowAllShellCommands == true
                    || settings.automaticallyManageCommands == true
                {
                    return true
                }
                guard let command = toolUse.stringInput("command"),
                    let commands = ShellCommandParser.simpleCommands(
                        in: command
                    ),
                    !commands.isEmpty
                else { return false }
                return commands.allSatisfy {
                    isApproved($0, rules: settings.shellCommandRules ?? [])
                }
            }
            let rules = (settings.toolRules ?? []).filter {
                $0.toolName == toolUse.name
            }
            return !rules.isEmpty && rules.allSatisfy { $0.action == "allow" }
        }

        // MARK: Commands

        /// Whether a simple command (its words) is approved: the most specific matching rules (the longest pattern) are
        /// all `allow`. No matching rule: not approved.
        static func isApproved(_ words: [String], rules: [Settings.CommandRule])
            -> Bool
        {
            let matching = rules.filter { matches(words, pattern: $0.pattern) }
            guard let longest = matching.map(\.pattern.count).max() else {
                return false
            }
            return matching.filter { $0.pattern.count == longest }.allSatisfy {
                $0.action == "allow"
            }
        }

        /// Whether a simple command matches a pattern: the first word is the command's name, the pattern's other words
        /// follow in order with only options (and an option's value) between them.
        static func matches(_ words: [String], pattern: String) -> Bool {
            let parts = pattern.split(separator: " ").map(String.init)
            guard let name = parts.first, words.first == name else {
                return false
            }
            return restMatches(parts.dropFirst(), words.dropFirst())
        }

        private static func restMatches(
            _ parts: ArraySlice<String>,
            _ words: ArraySlice<String>
        ) -> Bool {
            guard let part = parts.first else { return true }
            guard let word = words.first else { return false }
            if word == part, restMatches(parts.dropFirst(), words.dropFirst()) {
                return true
            }
            guard word.hasPrefix("-") else { return false }
            // An option between the pattern's words, alone or with its value.
            return restMatches(parts, words.dropFirst())
                || restMatches(parts, words.dropFirst(2))
        }

        // MARK: Files

        /// The tools that name the file they open, and whether they write it.
        private static let fileTools: [String: Bool] = [
            "Read": false, "NotebookRead": false, "Write": true, "Edit": true,
            "MultiEdit": true, "NotebookEdit": true,
        ]

        /// Whether opening the tool's file would make the file supervisor ask.
        static func fileAccessWouldAsk(
            _ toolUse: ChatEvent.ToolUse,
            settings: Settings,
            workingDirectory: URL?
        ) -> Bool {
            guard let writes = fileTools[toolUse.name],
                let path = toolUse.stringInput("file_path")
                    ?? toolUse.stringInput("notebook_path")
            else { return false }
            let file = resolved(path)
            if let workingDirectory,
                isInside(file, resolved(workingDirectory.path))
            {
                return false
            }
            let rules = (settings.pathRules ?? []).filter {
                settings.grantCommonLocations != false || $0.owner != "system"
            }
            guard
                let rule = rules.filter({ covers($0.path, file) }).max(by: {
                    $0.path.count < $1.path.count
                })
            else {
                return true  // no access: the supervisor asks
            }
            switch rule.access {
            case "write": return false
            case "read": return writes  // writing where only reading is granted asks
            default: return false  // readDenyWrite / deny: refused without asking
            }
        }

        /// Whether a path rule covers a path: the rule's path (or glob) is the path or one of its folders.
        private static func covers(_ rulePath: String, _ path: String) -> Bool {
            var candidate = path
            while true {
                if rulePath.contains("*")
                    ? fnmatch(rulePath, candidate, 0) == 0
                    : candidate == rulePath
                {
                    return true
                }
                let parent = (candidate as NSString).deletingLastPathComponent
                if parent == candidate || parent.isEmpty { return false }
                candidate = parent
            }
        }

        private static func isInside(_ path: String, _ folder: String) -> Bool {
            path == folder
                || path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
        }

        /// A path as the supervisor sees it: absolute, with the symlinks of its existing part resolved (`/tmp` →
        /// `/private/tmp`).
        private static func resolved(_ path: String) -> String {
            var existing = URL(
                filePath: (path as NSString).expandingTildeInPath
            ).standardizedFileURL
            var rest: [String] = []
            while !FileManager.default.fileExists(atPath: existing.path),
                existing.pathComponents.count > 1
            {
                rest.insert(existing.lastPathComponent, at: 0)
                existing.deleteLastPathComponent()
            }
            // `realpath`, not `resolvingSymlinksInPath()`: that one turns `/private/tmp` back into `/tmp`.
            let real =
                realpath(existing.path, nil).map { pointer in
                    defer { free(pointer) }
                    return String(cString: pointer)
                } ?? existing.path
            return rest.reduce(URL(filePath: real)) { $0.appending(path: $1) }
                .path
        }
    }
}

// MARK: - Shell commands

/// A shell command split into simple commands the way Xcode checks them: each one's words, with quotes removed and
/// leading `VAR=value` assignments and redirects dropped. Command substitutions (`$(…)`, backticks), subshells and
/// `find -exec` give simple commands of their own.
private nonisolated enum ShellCommandParser {

    /// The simple commands of a shell command; nil if it can't be parsed (an unclosed quote, substitution, subshell or
    /// heredoc).
    static func simpleCommands(in command: String) -> [[String]]? {
        var parser = Parser(characters: Array(command))
        return parser.parse() ? parser.commands : nil
    }

    private struct Parser {
        let characters: [Character]
        var index = 0
        var commands: [[String]] = []

        private var words: [String] = []
        private var word = ""
        private var inWord = false
        /// The next word is a redirect's target: dropped.
        private var skipNextWord = false
        /// The next word is a heredoc's delimiter (value: whether its body's leading tabs are stripped, `<<-`).
        private var pendingHeredoc: Bool?
        /// Heredocs whose bodies start after the current line.
        private var heredocs: [(delimiter: String, stripTabs: Bool)] = []
        private var depth = 0

        init(characters: [Character]) { self.characters = characters }

        mutating func parse() -> Bool {
            while index < characters.count {
                let c = characters[index]
                switch c {
                case " ", "\t":
                    endWord()
                    index += 1
                case "\n":
                    endCommand()
                    index += 1
                    guard skipHeredocBodies() else { return false }
                case ";", "&", "|":
                    endCommand()
                    index += 1
                case "(":
                    endCommand()
                    depth += 1
                    index += 1
                case ")":
                    guard depth > 0 else { return false }
                    endCommand()
                    depth -= 1
                    index += 1
                case "'":
                    guard
                        let end = characters[(index + 1)...].firstIndex(of: "'")
                    else { return false }
                    word += String(characters[(index + 1)..<end])
                    inWord = true
                    index = end + 1
                case "\"":
                    guard readDoubleQuoted() else { return false }
                case "\\":
                    if index + 1 < characters.count,
                        characters[index + 1] != "\n"
                    {
                        word.append(characters[index + 1])
                    }
                    inWord = true
                    index += 2
                case "$"
                where index + 1 < characters.count
                    && characters[index + 1] == "(":
                    guard readSubstitution(from: index + 2, closing: ")") else {
                        return false
                    }
                case "`":
                    guard readSubstitution(from: index + 1, closing: "`") else {
                        return false
                    }
                case "<", ">":
                    readRedirect()
                default:
                    word.append(c)
                    inWord = true
                    index += 1
                }
            }
            endCommand()
            return depth == 0 && pendingHeredoc == nil && heredocs.isEmpty
        }

        /// `"…"`: its text, with the substitutions inside it given their own commands.
        private mutating func readDoubleQuoted() -> Bool {
            index += 1
            inWord = true
            while index < characters.count {
                let c = characters[index]
                switch c {
                case "\"":
                    index += 1
                    return true
                case "\\":
                    if index + 1 < characters.count {
                        word.append(characters[index + 1])
                    }
                    index += 2
                case "$"
                where index + 1 < characters.count
                    && characters[index + 1] == "(":
                    guard readSubstitution(from: index + 2, closing: ")") else {
                        return false
                    }
                case "`":
                    guard readSubstitution(from: index + 1, closing: "`") else {
                        return false
                    }
                default:
                    word.append(c)
                    index += 1
                }
            }
            return false
        }

        /// A command substitution whose text starts at `start`: its commands are added; the word gets a placeholder.
        private mutating func readSubstitution(
            from start: Int,
            closing: Character
        ) -> Bool {
            var end = start
            var nesting = 0
            var quote: Character?
            while end < characters.count {
                let c = characters[end]
                if let open = quote {
                    if c == open { quote = nil } else if c == "\\" { end += 1 }
                } else if c == "'" || c == "\"" {
                    quote = c
                } else if c == "\\" {
                    end += 1
                } else if closing == ")" && c == "(" {
                    nesting += 1
                } else if c == closing {
                    if nesting == 0 { break }
                    nesting -= 1
                }
                end += 1
            }
            guard end < characters.count,
                let inner = ShellCommandParser.simpleCommands(
                    in: String(characters[start..<end])
                )
            else { return false }
            commands += inner
            word += "$(…)"
            inWord = true
            index = end + 1
            return true
        }

        /// A redirect (`>`, `>>`, `<`, `2>&1`, `<<<`, heredocs `<<` / `<<-`): dropped with its target.
        private mutating func readRedirect() {
            if inWord, word.allSatisfy(\.isNumber) {
                word = ""
                inWord = false
            }  // `2>`: the descriptor
            endWord()
            var op = ""
            while index < characters.count, "<>&".contains(characters[index]) {
                op.append(characters[index])
                index += 1
            }
            if op == "<<" {
                let stripTabs =
                    index < characters.count && characters[index] == "-"
                if stripTabs { index += 1 }
                pendingHeredoc = stripTabs
            } else if op.hasSuffix("&"), index < characters.count,
                characters[index].isNumber || characters[index] == "-"
            {
                // `>&2`, `2>&1`, `>&-`: the target is a descriptor.
                while index < characters.count,
                    characters[index].isNumber || characters[index] == "-"
                { index += 1 }
            } else {
                skipNextWord = true
            }
        }

        /// After a line that opened heredocs: skips their bodies, each up to its delimiter line.
        private mutating func skipHeredocBodies() -> Bool {
            while let heredoc = heredocs.first {
                guard index < characters.count else { return false }
                let lineEnd =
                    characters[index...].firstIndex(of: "\n")
                    ?? characters.count
                var line = String(characters[index..<lineEnd])
                if heredoc.stripTabs {
                    line = String(line.drop(while: { $0 == "\t" }))
                }
                index = min(lineEnd + 1, characters.count)
                if line == heredoc.delimiter { heredocs.removeFirst() }
            }
            return true
        }

        private mutating func endWord() {
            guard inWord else { return }
            if let stripTabs = pendingHeredoc {
                heredocs.append((word, stripTabs))
                pendingHeredoc = nil
            } else if skipNextWord {
                skipNextWord = false
            } else {
                words.append(word)
            }
            word = ""
            inWord = false
        }

        private mutating func endCommand() {
            endWord()
            var simple = Array(words.drop(while: isAssignment))
            words = []
            guard !simple.isEmpty else { return }
            // `find … -exec <command> … ;` (or `+`): the command it runs is checked too.
            if simple[0] == "find",
                let exec = simple.firstIndex(where: {
                    ["-exec", "-execdir", "-ok", "-okdir"].contains($0)
                })
            {
                let end =
                    simple[(exec + 1)...].firstIndex(where: {
                        $0 == ";" || $0 == "+"
                    }) ?? simple.endIndex
                let inner = Array(simple[(exec + 1)..<end])
                if !inner.isEmpty { commands.append(inner) }
                simple = Array(simple[..<exec])
            }
            commands.append(simple)
        }

        /// `NAME=value`.
        private func isAssignment(_ word: String) -> Bool {
            guard let equals = word.firstIndex(of: "="),
                equals != word.startIndex
            else { return false }
            let name = word[..<equals]
            return (name.first!.isLetter || name.first == "_")
                && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
        }
    }
}
