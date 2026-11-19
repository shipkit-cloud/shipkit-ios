import SwiftUI
import UIKit

/// Lets the user black out sensitive parts of a screenshot by dragging rectangles over it.
struct RedactEditor: View {
    let image: UIImage
    let onDone: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss
    /// Boxes in normalized image coordinates (0...1), so they survive layout changes.
    @State private var boxes: [CGRect] = []
    @State private var draft: CGRect?

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let frame = fittedFrame(in: proxy.size)
                ZStack(alignment: .topLeading) {
                    Image(uiImage: image)
                        .resizable()
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                    ForEach(Array((boxes + (draft.map { [$0] } ?? [])).enumerated()), id: \.offset) { _, box in
                        Rectangle()
                            .fill(Color.black)
                            .frame(width: box.width * frame.width, height: box.height * frame.height)
                            .offset(x: frame.minX + box.minX * frame.width, y: frame.minY + box.minY * frame.height)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            draft = normalizedRect(from: value.startLocation, to: value.location, in: frame)
                        }
                        .onEnded { value in
                            let rect = normalizedRect(from: value.startLocation, to: value.location, in: frame)
                            if rect.width > 0.005, rect.height > 0.005 { boxes.append(rect) }
                            draft = nil
                        }
                )
            }
            .padding()
            .background(Color(uiColor: .systemGroupedBackground))
            .safeAreaInset(edge: .bottom) {
                Text(L("redact.hint"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)
            }
            .navigationTitle(L("redact.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("common.done")) {
                        onDone(render())
                        dismiss()
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        _ = boxes.popLast()
                    } label: {
                        Label(L("redact.undo"), systemImage: "arrow.uturn.backward")
                    }
                    .disabled(boxes.isEmpty)
                }
            }
        }
    }

    private func fittedFrame(in size: CGSize) -> CGRect {
        guard image.size.width > 0, image.size.height > 0, size.width > 0, size.height > 0 else { return .zero }
        let scale = min(size.width / image.size.width, size.height / image.size.height)
        let width = image.size.width * scale
        let height = image.size.height * scale
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }

    private func normalizedRect(from start: CGPoint, to end: CGPoint, in frame: CGRect) -> CGRect {
        guard frame.width > 0, frame.height > 0 else { return .zero }
        func clamp(_ point: CGPoint) -> CGPoint {
            CGPoint(
                x: min(max((point.x - frame.minX) / frame.width, 0), 1),
                y: min(max((point.y - frame.minY) / frame.height, 0), 1)
            )
        }
        let a = clamp(start)
        let b = clamp(end)
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    private func render() -> UIImage {
        guard !boxes.isEmpty else { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        let size = image.size
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            image.draw(in: CGRect(origin: .zero, size: size))
            UIColor.black.setFill()
            for box in boxes {
                context.fill(CGRect(x: box.minX * size.width, y: box.minY * size.height, width: box.width * size.width, height: box.height * size.height))
            }
        }
    }
}
