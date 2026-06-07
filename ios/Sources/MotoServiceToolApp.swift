import SwiftUI

@main
struct MotoServiceToolApp: App {
    @StateObject private var vm = BikeViewModel()
    var body: some Scene {
        WindowGroup {
            ContentView(vm: vm)
        }
    }
}
