import AstroCore
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())

guard let subcommand = arguments.first else {
    eprint(usageText)
    exit(1)
}

if subcommand == "--version" {
    print("astrotool 0.12.0")
    exit(0)
}
if subcommand == "--help" || subcommand == "help" {
    print(usageText)
    exit(0)
}

let rest = Array(arguments.dropFirst())

do {
    let exitCode: Int32
    switch subcommand {
    case "scan": exitCode = try cmdScan(rest)
    case "audit": exitCode = try cmdAudit(rest)
    case "cleanup": exitCode = try cmdCleanup(rest)
    case "rate": exitCode = try cmdRate(rest)
    case "stats": exitCode = try cmdStats(rest)
    case "quality": exitCode = try cmdQuality(rest)
    case "nights": exitCode = try cmdNights(rest)
    case "calib": exitCode = try cmdCalib(rest)
    case "match": exitCode = try cmdMatch(rest)
    case "link-calib": exitCode = try cmdLinkCalib(rest)
    case "new-session": exitCode = try cmdNewSession(rest)
    case "config": exitCode = try cmdConfig(rest)
    case "tag": exitCode = try cmdTag(rest)
    case "ack": exitCode = try cmdAck(rest)
    case "note": exitCode = try cmdNote(rest)
    case "goal": exitCode = try cmdGoal(rest)
    case "plan": exitCode = try cmdPlan(rest)
    case "night-info": exitCode = try cmdNightInfo(rest)
    case "projects": exitCode = try cmdProjects(rest)
    case "export": exitCode = try cmdExport(rest)
    case "health": exitCode = try cmdHealth(rest)
    case "panels": exitCode = try cmdPanels(rest)
    case "search": exitCode = try cmdSearch(rest)
    case "solve": exitCode = try cmdSolve(rest)
    case "sensor": exitCode = try cmdSensor(rest)
    case "ingest-dss": exitCode = try cmdIngestDSS(rest)
    case "expose": exitCode = try cmdExpose(rest)
    case "stacklist": exitCode = try cmdStackList(rest)
    case "stacks": exitCode = try cmdStacks(rest)
    case "report": exitCode = try cmdReport(rest)
    case "target-report": exitCode = try cmdTargetReport(rest)
    default:
        eprint(usageText)
        exit(1)
    }
    exit(exitCode)
} catch let error as AstroError {
    switch error {
    case .accessDenied, .volumeNotMounted:
        eprint(tccGuidance)
        exit(2)
    default:
        eprint("error: \(describeAstroError(error))")
        eprint(usageText)
        exit(1)
    }
} catch let error as ArgParserError {
    eprint("error: \(error)")
    eprint(usageText)
    exit(1)
} catch {
    eprint("error: \(error)")
    eprint(usageText)
    exit(1)
}
