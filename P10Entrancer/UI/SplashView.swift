import SwiftUI

struct SplashView: View {
    let onEnter: () -> Void
    @State private var showDocs = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 32) {
                Spacer()
                Image("Logo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 520)
                    .overlay(
                        Rectangle().strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                    )
                Spacer()
                HStack(spacing: 18) {
                    Button(action: { showDocs = true }) {
                        Text("DOCS")
                            .font(.system(size: 16, weight: .heavy, design: .monospaced))
                            .tracking(3)
                            .foregroundStyle(.white)
                            .frame(width: 200, height: 56)
                            .background(Color.white.opacity(0.06))
                            .overlay(Rectangle().strokeBorder(Color.white.opacity(0.4), lineWidth: 1))
                    }
                    .buttonStyle(.plain)

                    Button(action: onEnter) {
                        Text("ENTRANCE ME")
                            .font(.system(size: 16, weight: .heavy, design: .monospaced))
                            .tracking(3)
                            .foregroundStyle(.black)
                            .frame(width: 280, height: 56)
                            .background(
                                LinearGradient(
                                    colors: [Color(red: 0.95, green: 0.20, blue: 0.55), Color(red: 0.20, green: 0.85, blue: 0.85)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .overlay(Rectangle().strokeBorder(Color.white, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                Spacer().frame(height: 60)
            }
            .padding(40)
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showDocs) {
            DocsView()
        }
    }
}
