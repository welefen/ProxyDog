import AppKit
import Foundation

// The app has two entry points:
//   * normal launch: SwiftUI app with the capture window
//   * `--headless`: proxy engine only, used by scripts/test_proxy.sh and CI
if CommandLine.arguments.contains("--headless") {
    HeadlessRunner.run()
} else {
    ProxyDogApp.main()
}
