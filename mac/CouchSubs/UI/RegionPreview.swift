// SPDX-License-Identifier: AGPL-3.0-only
// Mac ve iPhone uygulamalarının ortak parçası (iPhone projesi de bu dosyayı derler).

import CouchSubsCore
import SwiftUI

/// Alanın canlı önizlemesi: son PS5 karesi (yoksa yer tutucu), üstünde alanın çerçevesi; alanın dışı karartılır, okunacak
/// yer belirgin olur. Çerçeve içinden sürüklenerek taşınır, sekiz tutamacından (köşeler ve kenar ortaları) sürüklenerek
/// boyutlandırılır. `centered` (altyazı alanında "Ortada tut" açıkken): yatay boyut ortadan değişir, alan ortalı kalır.
/// Kurallar `RegionEdit`'tedir (Windows ve Android ile aynı); her değişiklik `onChange` ile bildirilir.
struct RegionPreview: View {
    let region: CropRegion
    let frame: CGImage?
    /// Yatay boyut ortadan değişir (altyazı alanında `UserSettings.keepAreaCentered`); ek alanlarda kapalı.
    var centered = false
    /// Kare yokken gösterilen yazı.
    var placeholder: LocalizedStringKey = "The game picture appears here once translating starts."
    /// Telefon/panel iç ekran kırpması açıksa OCR'ın okuyacağı iç alanı kesikli çizgiyle gösterir.
    var innerRegion: CropRegion? = nil
    /// Canlı algılama açıkken çerçeve rengi (algılandığında yeşil).
    var frameColor: Color = .csAccent
    /// Yan buzlu cam balonun TV'de çıkacağı yeri önizlemede gösterir.
    var showSideBubblePreview = false
    /// Önizleme balonunun görsel teması.
    var bubbleTheme: BubbleTheme = .appleGlass
    /// Önizlemenin sol üst köşesinde canlı algılama rozeti (nil ise gizli).
    var liveBadge: (text: LocalizedStringKey, active: Bool)? = nil
    let onChange: (CropRegion) -> Void

    /// Sürükleme başladığında bölge (sürükleme hep bu bölgeye göre hesaplanır).
    @State private var dragStart: CropRegion? = nil

    /// Görünen tutamaç ve parmakla tutma alanı (dokunmatikte küçük kare tutulmaz).
    private static let handle: CGFloat = 10
    private static let grip: CGFloat = 28

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let box = CGRect(x: size.width * region.left, y: size.height * region.top,
                             width: size.width * (region.right - region.left), height: size.height * (region.bottom - region.top))
            ZStack(alignment: .topLeading) {
                if let frame {
                    Image(decorative: frame, scale: 1).resizable()
                } else {
                    RoundedRectangle(cornerRadius: Theme.radius("inner")).fill(Color.csBackground)
                    Text(placeholder)
                        .font(.csCaption).foregroundStyle(Color.csSecondary)
                        .multilineTextAlignment(.center)
                        .padding(Theme.space("m"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: size))
                    path.addRect(box)
                }
                .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)
                if let inner = innerRegion {
                    let innerBox = CGRect(x: size.width * inner.left, y: size.height * inner.top,
                                          width: size.width * (inner.right - inner.left),
                                          height: size.height * (inner.bottom - inner.top))
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.white.opacity(0.65), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .frame(width: innerBox.width, height: innerBox.height)
                        .offset(x: innerBox.minX, y: innerBox.minY)
                        .allowsHitTesting(false)
                }
                if showSideBubblePreview {
                    let onRight = (region.left + region.right) / 2 > 0.5
                    let bubbleW = min(size.width * 0.28, max(72, (onRight ? box.minX - 14 : size.width - box.maxX - 14)))
                    let bubbleX = onRight ? max(6, box.minX - bubbleW - 8) : min(size.width - bubbleW - 6, box.maxX + 8)
                    let bubbleY = box.minY + box.height * 0.16
                    let senderAccent: Color = switch bubbleTheme {
                    case .appleGlass: Color.cyan.opacity(0.9)
                    case .viceNeon: Color.pink.opacity(0.95)
                    case .stealthDark: Color.orange.opacity(0.85)
                    }
                    let borderAccent: Color = switch bubbleTheme {
                    case .appleGlass: Color.white.opacity(0.28)
                    case .viceNeon: Color.pink.opacity(0.65)
                    case .stealthDark: Color.white.opacity(0.16)
                    }
                    let bgColor: Color = switch bubbleTheme {
                    case .appleGlass: Color(red: 0.09, green: 0.12, blue: 0.18).opacity(0.75)
                    case .viceNeon: Color(red: 0.14, green: 0.07, blue: 0.24).opacity(0.82)
                    case .stealthDark: Color(red: 0.04, green: 0.05, blue: 0.07).opacity(0.88)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 4) {
                            Circle().fill(senderAccent).frame(width: 6, height: 6)
                            Capsule().fill(senderAccent).frame(width: bubbleW * 0.34, height: 3.5)
                        }
                        Capsule().fill(Color.white.opacity(0.90)).frame(width: bubbleW * 0.80, height: 3.5)
                        Capsule().fill(Color.white.opacity(0.55)).frame(width: bubbleW * 0.56, height: 3.5)
                    }
                    .padding(7)
                    .frame(width: bubbleW, alignment: .leading)
                    .background(bgColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(borderAccent, lineWidth: 1)
                    )
                    .shadow(color: bubbleTheme == .viceNeon ? Color.pink.opacity(0.28) : .black.opacity(0.35), radius: 6, x: 0, y: 3)
                    .offset(x: bubbleX, y: bubbleY)
                    .allowsHitTesting(false)
                }
                if let badge = liveBadge {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(badge.active ? Color.green : Color.white.opacity(0.45))
                            .frame(width: 6, height: 6)
                        Text(badge.text)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.62), in: Capsule())
                    .overlay(Capsule().strokeBorder(badge.active ? Color.green.opacity(0.6) : Color.white.opacity(0.18), lineWidth: 1))
                    .padding(8)
                    .allowsHitTesting(false)
                }
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .overlay(Rectangle().strokeBorder(frameColor, lineWidth: 2))
                    .animation(.easeInOut(duration: 0.18), value: frameColor)
                    .frame(width: box.width, height: box.height)
                    .offset(x: box.minX, y: box.minY)
                    .gesture(drag(.move, in: size))
                    .accessibilityLabel(Text("Subtitle area"))
                ForEach(Array(RegionEdit.handles(region).enumerated()), id: \.offset) { _, spot in
                    Rectangle()
                        .fill(frameColor)
                        .frame(width: Self.handle, height: Self.handle)
                        .frame(width: Self.grip, height: Self.grip)
                        .contentShape(Rectangle())
                        .offset(x: size.width * spot.x - Self.grip / 2, y: size.height * spot.y - Self.grip / 2)
                        .gesture(drag(spot.handle, in: size))
                        .accessibilityHidden(true)
                }
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius("inner")))
    }

    private func drag(_ handle: RegionEdit.Handle, in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = dragStart ?? region
                dragStart = start
                onChange(RegionEdit.dragged(start, handle: handle, dx: value.translation.width / max(1, size.width),
                                            dy: value.translation.height / max(1, size.height), centered: centered))
            }
            .onEnded { _ in dragStart = nil }
    }
}

extension AreaPreset {
    /// Seçimin ekrandaki adı.
    var title: LocalizedStringKey {
        switch self {
        case .bottom: "Bottom area"
        case .top: "Top area"
        case .full: "Full screen"
        case .custom: "Custom"
        }
    }
}

/// Yüzde değeri ("40%"; Türkçede "%40").
func percentText(_ value: Double) -> String {
    String(format: String(localized: "%lld%%"), Int(value.rounded()))
}
