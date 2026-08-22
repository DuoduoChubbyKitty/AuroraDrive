// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

// MARK: - 动画常量

private let panelAnim = Animation.spring(response: 0.5, dampingFraction: 0.62, blendDuration: 0)
private let toggleAnim = panelAnim
private let hoverAnim = Animation.easeOut(duration: 0.18)
private let fnAnim = Animation.spring(response: 0.35, dampingFraction: 0.7)
private let itemAnim = Animation.spring(response: 0.46, dampingFraction: 0.72, blendDuration: 0)
private let fadeAnim = Animation.spring(response: 0.42, dampingFraction: 0.72)

// MARK: - 功能清单（MaaNTE 功能一览）

struct AutomationFunctionItem: Identifiable {
    let id = UUID()
    let emoji: String
    let name: String
    var warn: Bool = false
}

enum AutomationLibrary {
    static let functions: [AutomationFunctionItem] = [
        AutomationFunctionItem(emoji: "🎣", name: "自动钓鱼"),
        AutomationFunctionItem(emoji: "🥤", name: "自动做咖啡"),
        AutomationFunctionItem(emoji: "🐾", name: "粉爪大劫案", warn: true),
        AutomationFunctionItem(emoji: "🪑", name: "自动收家具"),
        AutomationFunctionItem(emoji: "💎", name: "自动领奖励"),
        AutomationFunctionItem(emoji: "🎹", name: "自动弹钢琴"),
        AutomationFunctionItem(emoji: "🎵", name: "自动超强音"),
        AutomationFunctionItem(emoji: "⚔️", name: "自动闪避"),
        AutomationFunctionItem(emoji: "🕛", name: "实时辅助"),
    ]
}

// MARK: - 侧边栏底部触发卡（AUTOMATION）

struct AutomationCard: View {
    @Binding var open: Bool
    @State private var hovering = false

    var body: some View {
        Button {
            withAnimation(panelAnim) {
                open.toggle()
            }
        } label: {
            HStack(spacing: 10) {
                Text("🤖")
                    .font(.system(size: 16))
                    .shadow(color: hovering ? Theme.cyan.opacity(0.9) : .clear, radius: hovering ? 8 : 0)
                Text("自动化")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.cyan)
                Spacer()
                Text("9 功能")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(hovering ? Theme.cyan : Theme.textTertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(hovering ? Theme.cyan.opacity(0.12) : Color.white.opacity(0.05)))
                    .overlay(Capsule().strokeBorder(hovering ? Theme.cyan.opacity(0.5) : Color.white.opacity(0.12), lineWidth: 1))
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.cyan)
                    .rotationEffect(.degrees(open ? 90 : 0))
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(hovering ? Theme.cyan.opacity(0.08) : Theme.bgCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [Theme.cyan.opacity(hovering ? 0.55 : 0.28),
                                                Theme.cyan.opacity(0.04)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1)
            )
            .shadow(color: hovering ? Theme.cyan.opacity(0.5) : Theme.cyan.opacity(0.18),
                    radius: hovering ? 16 : 6)
        }
        .buttonStyle(.plain)
        .onHover { h in
            withAnimation(hoverAnim) { hovering = h }
        }
        .help("MaaNTE 自动化功能面板（9 项）")
    }
}

// MARK: - 右侧滑出抽屉

struct AutomationDrawer: View {
    @Binding var open: Bool
    @State private var running = Set<UUID>()
    @State private var appeared = false

    private let functions = AutomationLibrary.functions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Theme.cyan)
                        .frame(width: 3, height: 12)
                        .shadow(color: Theme.cyan, radius: 4)
                    Text("自动化 · MaaNTE")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .tracking(2)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Button {
                    withAnimation(panelAnim) { open = false }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.white.opacity(0.06)))
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("收起自动化面板")
            }
            .padding(.horizontal, 14)
            .padding(.top, 16)
            .padding(.bottom, 10)
            .opacity(appeared ? 1 : 0)
            .offset(x: appeared ? 0 : 30)
            .animation(fadeAnim.delay(0.02), value: appeared)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 9) {
                    // 避免 for-each 里构造中间 Array，直接迭代 indices（UI 渲染路径）
                    ForEach(Array(functions.indices), id: \.self) { idx in
                        let item = functions[idx]
                        AutomationFnButton(item: item,
                                           index: idx,
                                           appeared: appeared,
                                           active: running.contains(item.id)) {
                            withAnimation(fnAnim) {
                                if running.contains(item.id) {
                                    running.remove(item.id)
                                } else {
                                    running.insert(item.id)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 20)
            }
        }
        .frame(width: 300, alignment: .trailing)
        .clipped()
        .background(
            ZStack {
                Color.black.opacity(0.9)
                LinearGradient(colors: [Theme.cyan.opacity(0.05), .clear],
                               startPoint: .leading, endPoint: .trailing)
            }
        )
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(LinearGradient(colors: [Theme.cyan.opacity(0.5), Theme.cyan.opacity(0.08)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 1)
        }
        .onAppear {
            withAnimation(panelAnim) { appeared = true }
        }
    }
}

// MARK: - 抽屉内单个功能行（悬停沉浸光效 + 阶梯弹入）

private struct AutomationFnButton: View {
    let item: AutomationFunctionItem
    let index: Int
    let appeared: Bool
    let active: Bool
    let toggle: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 11) {
                Text(item.emoji)
                    .font(.system(size: 17))
                    .shadow(color: hovered ? Theme.cyan.opacity(0.95) : .clear, radius: hovered ? 10 : 0)
                Text(item.name)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if item.warn {
                    Text("最凶")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.danger)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Theme.danger.opacity(0.12)))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Theme.danger.opacity(0.5), lineWidth: 1))
                }
                Circle()
                    .fill(active ? Theme.cyan : Color.white.opacity(0.18))
                    .frame(width: 8, height: 8)
                    .shadow(color: active ? Theme.cyan : .clear, radius: active ? 8 : 0)
            }
            .padding(.horizontal, 12)
            .frame(height: 46)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(active ? Theme.cyan.opacity(0.10)
                                     : (hovered ? Theme.cyan.opacity(0.08) : Color.white.opacity(0.04)))
                    if hovered || active {
                        RadialGradient(colors: [Theme.cyan.opacity(0.16), .clear],
                                       center: .center, startRadius: 0, endRadius: 110)
                            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(hovered || active ? Theme.cyan.opacity(0.6) : Color.white.opacity(0.08),
                                  lineWidth: 1)
            )
            .shadow(color: hovered ? Theme.cyan.opacity(0.45)
                                   : (active ? Theme.cyan.opacity(0.22) : .clear),
                    radius: hovered ? 15 : (active ? 10 : 0))
            .shadow(color: hovered ? Theme.cyan.opacity(0.22) : .clear, radius: 32)
        }
        .buttonStyle(.plain)
        .onHover { h in
            withAnimation(hoverAnim) { hovered = h }
        }
        .offset(x: appeared ? 0 : 46)
        .opacity(appeared ? 1 : 0)
        .animation(itemAnim
            .delay(appeared ? Double(index) * 0.055 : 0), value: appeared)
    }
}
