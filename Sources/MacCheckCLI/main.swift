import Foundation
import MacCheckCore
#if os(macOS)
import MacCheckMac
#endif

// maccheck-cli — headless runner for development and quick checks.
//
//   maccheck-cli --sample                 sample scan (works on Windows/Linux/macOS)
//   maccheck-cli                          live scan (macOS only)
//   maccheck-cli --areas battery,storage  only some areas
//   maccheck-cli --format json|markdown|text
//   maccheck-cli --no-network             skip DNS/HTTPS probes
//   maccheck-cli --doctor /Applications/X.app --symptom crashes   (App Doctor; macOS or --sample)
//
// Output is redacted. Nothing is uploaded or saved unless you redirect stdout yourself.

func value(after flag: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

let args = Array(CommandLine.arguments.dropFirst())
if args.contains("--help") || args.contains("-h") {
    print("""
    usage: maccheck-cli [--sample] [--areas a,b] [--format markdown|json|text] [--no-network]
                        [--doctor <App.app path> --symptom crashes|freezes|wontOpen|slow|permissions|somethingElse]
    areas: \(DiagnosticArea.allCases.map(\.rawValue).joined(separator: ", "))
    """)
    exit(0)
}

let useSample = args.contains("--sample")
var options = CollectionOptions(networkProbesEnabled: !args.contains("--no-network"))
var reportOptions = ReportOptions()
if let f = value(after: "--format", in: args).flatMap(ReportFormat.init(rawValue:)) { reportOptions.format = f }

let collectors: CollectorSet
let redactor: Redactor
let doctorSources: AppDoctorSources
if useSample {
    collectors = SampleData.collectors(delaySeconds: 0)
    redactor = Redactor()
    doctorSources = SampleData.appDoctorSources()
} else {
    #if os(macOS)
    collectors = MacPlatform.collectors()
    redactor = MacPlatform.redactor()
    doctorSources = MacPlatform.appDoctorSources()
    #else
    FileHandle.standardError.write(Data("Live diagnostics need macOS. On this platform use --sample.\n".utf8))
    exit(2)
    #endif
}

let areas: Set<DiagnosticArea>? = value(after: "--areas", in: args).map {
    Set($0.split(separator: ",").compactMap { DiagnosticArea(rawValue: String($0)) })
}

let semaphore = DispatchSemaphore(value: 0)
Task {
    let report: ScanReport
    if let path = value(after: "--doctor", in: args) {
        let symptom = value(after: "--symptom", in: args).flatMap(Symptom.init(rawValue:)) ?? .somethingElse
        do {
            report = try await AppDoctorRunner(sources: doctorSources, collectors: collectors)
                .investigate(appPath: path, symptom: symptom, options: options) { step in
                    FileHandle.standardError.write(Data("… \(step.rawValue)\n".utf8))
                }
        } catch {
            FileHandle.standardError.write(Data("App Doctor couldn't run: \(error)\n".utf8))
            exit(1)
        }
    } else {
        report = await ScanOrchestrator(collectors: collectors, areas: areas).run(options: options) { event in
            if case let .started(_, title, i, n) = event {
                FileHandle.standardError.write(Data("[\(i + 1)/\(n)] \(title)…\n".utf8))
            }
        }
    }
    var draft = ReportDraft(report: report, options: reportOptions, redactor: redactor)
    draft.markReviewed() // printing to your own terminal is the review
    print(draft.render())
    semaphore.signal()
}
semaphore.wait()
