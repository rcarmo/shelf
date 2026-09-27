import Foundation
import DecisionCore
import DecisionFoundationModels

@main
struct DecisionReplay {
    static func main() async {
        let model = AppleDecisionModel()
        if CommandLine.arguments.contains("--availability") {
            emit(await model.availability())
            return
        }
        let engine = DecisionEngine(model: model)
        while let line = readLine() {
            do {
                let request = try DecisionJSON.decodeRequest(Data(line.utf8))
                if CommandLine.arguments.contains("--validate") {
                    emit(request)
                } else {
                    emit(try await engine.decide(request, timeout: .seconds(15)))
                }
            } catch let failure as DecisionFailure { emit(failure) }
            catch { emit(DecisionFailure(.invalidRequest, "replay_input")) }
        }
    }

    private static func emit<T: Encodable>(_ value: T) {
        if let data = try? DecisionJSON.encode(value) {
            print(String(decoding: data, as: UTF8.self))
        }
    }
}
