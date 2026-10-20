import SwiftUI
import AppKit

struct ImageEditorTarget: Identifiable {
    let id = UUID()
    let name: String
    let answer: Bool
}

struct ImageMaskEditor: View {
    let url: URL
    @Binding var masks: [ImageMask]
    @Environment(\.dismiss) private var dismiss
    @State private var draft: [ImageMask]
    @State private var dragStart: CGPoint?
    @State private var dragEnd: CGPoint?

    init(url: URL,masks: Binding<[ImageMask]>) {
        self.url = url
        self._masks = masks
        self._draft = State(initialValue:masks.wrappedValue)
    }

    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            HStack {
                VStack(alignment:.leading) {
                    Text("Редактор фотографии").font(.title2.bold())
                    Text("Проведите мышью по фотографии, чтобы закрыть область чёрным прямоугольником.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Отмена") { dismiss() }
                Button("Применить") { masks = draft; dismiss() }.buttonStyle(.borderedProminent)
            }
            if url.pathExtension.lowercased() == "gif" {
                ContentUnavailableView("GIF не редактируется",systemImage:"photo.badge.exclamationmark",description:Text("Редактор масок доступен только для статичных изображений."))
            } else if let image = NSImage(contentsOf:url) {
                GeometryReader { geometry in
                    let fitted = fittedRect(imageSize:image.size,in:geometry.size)
                    ZStack(alignment:.topLeading) {
                        Color.black.opacity(0.06)
                        Image(nsImage:image).resizable().scaledToFit().frame(width:geometry.size.width,height:geometry.size.height)
                        ForEach(Array(draft.enumerated()),id:\.element.id) { index,mask in
                            Rectangle().fill(.black)
                                .overlay(Text("\(index+1)").foregroundStyle(.white).font(.caption.bold()))
                                .frame(width:fitted.width*mask.width,height:fitted.height*mask.height)
                                .offset(x:fitted.minX+fitted.width*mask.x,y:fitted.minY+fitted.height*mask.y)
                        }
                        if let start = dragStart, let end = dragEnd {
                            Rectangle().fill(.black.opacity(0.75)).overlay(Rectangle().stroke(.white,lineWidth:1))
                                .frame(width:abs(end.x-start.x),height:abs(end.y-start.y))
                                .offset(x:min(start.x,end.x),y:min(start.y,end.y))
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance:2,coordinateSpace:.local)
                        .onChanged { value in
                            let point = clamp(value.location,to:fitted)
                            if dragStart == nil { dragStart = clamp(value.startLocation,to:fitted) }
                            dragEnd = point
                        }
                        .onEnded { value in
                            let start = dragStart ?? clamp(value.startLocation,to:fitted)
                            let end = clamp(value.location,to:fitted)
                            defer { dragStart = nil; dragEnd = nil }
                            let rect = CGRect(x:min(start.x,end.x),y:min(start.y,end.y),width:abs(end.x-start.x),height:abs(end.y-start.y))
                            guard rect.width >= 5, rect.height >= 5, fitted.width > 0, fitted.height > 0 else { return }
                            draft.append(ImageMask(x:(rect.minX-fitted.minX)/fitted.width,y:(rect.minY-fitted.minY)/fitted.height,width:rect.width/fitted.width,height:rect.height/fitted.height))
                        })
                }
                .frame(minHeight:420)
                .clipShape(RoundedRectangle(cornerRadius:10))
                .overlay(RoundedRectangle(cornerRadius:10).stroke(.quaternary))
                HStack {
                    Text("Закрытых областей: \(draft.count)").foregroundStyle(.secondary)
                    Spacer()
                    Button("Удалить последнюю") { _ = draft.popLast() }.disabled(draft.isEmpty)
                    Button("Очистить все",role:.destructive) { draft.removeAll() }.disabled(draft.isEmpty)
                }
            } else {
                ContentUnavailableView("Не удалось открыть изображение",systemImage:"photo.badge.exclamationmark")
            }
        }.padding(22).frame(width:900,height:680)
    }

    private func fittedRect(imageSize: CGSize,in available: CGSize) -> CGRect {
        let scale = min(available.width/max(1,imageSize.width),available.height/max(1,imageSize.height))
        let size = CGSize(width:imageSize.width*scale,height:imageSize.height*scale)
        return CGRect(x:(available.width-size.width)/2,y:(available.height-size.height)/2,width:size.width,height:size.height)
    }
    private func clamp(_ point: CGPoint,to rect: CGRect) -> CGPoint {
        CGPoint(x:min(rect.maxX,max(rect.minX,point.x)),y:min(rect.maxY,max(rect.minY,point.y)))
    }
}
