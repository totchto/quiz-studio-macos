// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "QuizStudio", platforms: [.macOS(.v14)], products: [.executable(name: "QuizStudio", targets: ["QuizStudio"])], targets: [.executableTarget(name: "QuizStudio")], swiftLanguageModes: [.v5])
