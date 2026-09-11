import SwiftUI

/// App-level entry point that owns the terminal feature while it is visible.
struct SSHTerminalFeatureView: View {
    @Environment(AppSettings.self) private var settings
    let host: SSHTerminalHost

    var body: some View {
        TerminalPresentationView(presentation: host.presentation)
            .task {
                await host.start(settings: settings)
            }
            .onDisappear {
                Task {
                    await host.close()
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close terminal", systemImage: "xmark") {
                        Task {
                            await host.close()
                        }
                    }
                    .accessibilityIdentifier("close-ssh-terminal")
                }
            }
    }
}
