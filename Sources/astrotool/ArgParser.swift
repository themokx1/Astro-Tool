import Foundation

/// Declares one flag a subcommand accepts: its exact `--name` (including the
/// leading `--`) and whether it takes a value (`--flag value` / `--flag=value`)
/// or is a bare boolean switch (`--flag`).
struct FlagSpec {
    let name: String
    let takesValue: Bool

    init(_ name: String, takesValue: Bool) {
        self.name = name
        self.takesValue = takesValue
    }
}

/// Bad CLI input -- an unrecognized flag for the subcommand being parsed, or
/// a value-taking flag given with nothing after it. Always maps to exit code
/// 1 (plus usage) at the top level; never an `AstroError`.
enum ArgParserError: Error, CustomStringConvertible {
    case unknownFlag(String)
    case missingValue(String)

    var description: String {
        switch self {
        case .unknownFlag(let flag):
            return "unknown flag: \(flag)"
        case .missingValue(let flag):
            return "missing value for \(flag)"
        }
    }
}

/// The result of parsing one subcommand's argument list: value-flags keyed
/// by their `--name`, and boolean flags present as a set.
struct ParsedArgs {
    var values: [String: String] = [:]
    var flags: Set<String> = []

    func value(_ name: String) -> String? { values[name] }
    func has(_ name: String) -> Bool { flags.contains(name) }
}

/// A tiny hand-rolled `--flag value` / `--flag=value` parser -- no
/// positional arguments, no short flags, no `--` separator handling, because
/// no `astrotool` subcommand needs any of those. Every flag must be declared
/// in `specs`; anything else is an `ArgParserError.unknownFlag`.
enum ArgParser {
    static func parse(_ args: [String], specs: [FlagSpec]) throws -> ParsedArgs {
        var result = ParsedArgs()
        let specByName = Dictionary(uniqueKeysWithValues: specs.map { ($0.name, $0) })

        var index = 0
        while index < args.count {
            let arg = args[index]
            guard arg.hasPrefix("--") else {
                throw ArgParserError.unknownFlag(arg)
            }

            if let eqIndex = arg.firstIndex(of: "=") {
                let name = String(arg[arg.startIndex..<eqIndex])
                let value = String(arg[arg.index(after: eqIndex)...])
                guard let spec = specByName[name] else { throw ArgParserError.unknownFlag(name) }
                if spec.takesValue {
                    result.values[name] = value
                } else {
                    result.flags.insert(name)
                }
                index += 1
                continue
            }

            guard let spec = specByName[arg] else { throw ArgParserError.unknownFlag(arg) }
            if spec.takesValue {
                guard index + 1 < args.count else { throw ArgParserError.missingValue(arg) }
                result.values[arg] = args[index + 1]
                index += 2
            } else {
                result.flags.insert(arg)
                index += 1
            }
        }

        return result
    }
}
